package pricing

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	awspricing "github.com/aws/aws-sdk-go-v2/service/pricing"
	"github.com/aws/aws-sdk-go-v2/service/pricing/types"
)

// Products asks the Price List for the products matching every filter, each as
// the raw JSON AWS returns. The Price List only answers in us-east-1.
type Products interface {
	Products(ctx context.Context, service string, filters [][2]string) ([]string, error)
}

// SDKProducts is Products over the AWS SDK.
type SDKProducts struct{ Client *awspricing.Client }

func (s SDKProducts) Products(ctx context.Context, service string, filters [][2]string) ([]string, error) {
	in := &awspricing.GetProductsInput{ServiceCode: aws.String(service)}
	for _, f := range filters {
		in.Filters = append(in.Filters, types.Filter{
			Type: types.FilterTypeTermMatch, Field: aws.String(f[0]), Value: aws.String(f[1])})
	}
	var out []string
	p := awspricing.NewGetProductsPaginator(s.Client, in)
	for p.HasMorePages() {
		page, err := p.NextPage(ctx)
		if err != nil {
			return nil, err
		}
		out = append(out, page.PriceList...)
	}
	return out, nil
}

type item struct {
	Product struct {
		Attributes struct {
			UsageType string `json:"usagetype"`
		} `json:"attributes"`
	} `json:"product"`
	Terms struct {
		OnDemand map[string]struct {
			PriceDimensions map[string]struct {
				BeginRange   string `json:"beginRange"`
				PricePerUnit struct {
					USD string `json:"USD"`
				} `json:"pricePerUnit"`
			} `json:"priceDimensions"`
		} `json:"OnDemand"`
	} `json:"terms"`
}

// firstTier is the usage type and price of the lowest paid tier: the price the
// first GB pays. Free tiers are not in the price list; a tier that starts at 0
// is the first.
func firstTier(raw []string) (usageType string, usd *float64) {
	best := -1.0
	for _, r := range raw {
		var it item
		if json.Unmarshal([]byte(r), &it) != nil {
			continue
		}
		for _, term := range it.Terms.OnDemand {
			for _, dim := range term.PriceDimensions {
				p, err := strconv.ParseFloat(dim.PricePerUnit.USD, 64)
				if err != nil || p <= 0 {
					continue
				}
				begin, _ := strconv.ParseFloat(dim.BeginRange, 64)
				if best < 0 || begin < best {
					best, usageType, usd = begin, it.Product.Attributes.UsageType, &p
				}
			}
		}
	}
	return
}

// AWSSource asks the Price List for the region's prices and an exchange-rate
// endpoint for the rupee.
type AWSSource struct {
	API    Products
	FXURL  string // CG_FX_URL, or the default
	Client *http.Client
}

// Prices reads every price for the region at once. It fails unless every
// price was found: a half-read table is not cached, and an unknown price stays
// unknown rather than becoming a guess.
func (a AWSSource) Prices(ctx context.Context, region string) (map[string]float64, error) {
	if region == "" || a.API == nil {
		return nil, errors.New("no region or no price list to ask")
	}
	// The gp3 disk first: its usage type carries the region's billing prefix
	// ("APS5-" for Hyderabad), which names every other price exactly.
	disk, err := a.API.Products(ctx, "AmazonEC2", [][2]string{
		{"regionCode", region}, {"productFamily", "Storage"}, {"volumeApiName", "gp3"}})
	if err != nil {
		return nil, err
	}
	ut, ebs := firstTier(disk)
	if ut == "" || !strings.Contains(ut, "EBS:") || ebs == nil {
		return nil, errors.New("the region's disk price was not found")
	}
	prefix := strings.SplitN(ut, "EBS:", 2)[0]
	asks := map[string][2]string{
		"CG_SNAPSHOT_USD_GB_MONTH": {"AmazonEC2", prefix + "EBS:SnapshotUsage"},
		"CG_S3_USD_GB_MONTH":       {"AmazonS3", prefix + "TimedStorage-ByteHrs"},
		"CG_IPV4_USD_HOUR":         {"AmazonVPC", prefix + "PublicIPv4:InUseAddress"},
		"CG_EGRESS_USD_GB":         {"AWSDataTransfer", prefix + "DataTransfer-Out-Bytes"},
		"CG_XREGION_USD_GB":        {"AWSDataTransfer", prefix + "AWS-Out-Bytes"},
		// Cost Explorer is billed in us-east-1 whatever the region.
		"CG_CE_CALL_USD": {"AWSCostExplorer", "USE1-APIRequest"},
	}
	got := map[string]float64{"CG_EBS_USD_GB_MONTH": *ebs}
	var mu sync.Mutex
	var wg sync.WaitGroup
	var firstErr error
	for key, ask := range asks {
		wg.Add(1)
		go func() {
			defer wg.Done()
			service, usage := ask[0], ask[1]
			raw, err := a.API.Products(ctx, service, [][2]string{{"usagetype", usage}})
			_, usd := firstTier(raw)
			// us-east-1 bills its disks with no prefix but its addresses and
			// transfers as "USE1-": the one region that is not consistent.
			if err == nil && usd == nil && prefix == "" && !strings.HasPrefix(usage, "USE1-") {
				raw, err = a.API.Products(ctx, service, [][2]string{{"usagetype", "USE1-" + usage}})
				_, usd = firstTier(raw)
			}
			mu.Lock()
			defer mu.Unlock()
			switch {
			case err != nil && firstErr == nil:
				firstErr = err
			case usd == nil && firstErr == nil:
				firstErr = fmt.Errorf("no price found for %s", key)
			case usd != nil:
				got[key] = *usd
			}
		}()
	}
	wg.Wait()
	if firstErr != nil {
		return nil, firstErr
	}
	return got, nil
}

// DefaultFXURL is the exchange-rate endpoint. The request carries nothing about
// this computer: "USD to INR, 1".
const DefaultFXURL = "https://jeapis.netlify.app/.netlify/functions/currency?from=USD&to=INR&amount=1"

// FX is today's rupees to a dollar.
func (a AWSSource) FX(ctx context.Context) (float64, error) {
	url := a.FXURL
	if url == "" {
		url = os.Getenv("CG_FX_URL")
	}
	if url == "" {
		url = DefaultFXURL
	}
	ctx, cancel := context.WithTimeout(ctx, 4*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return 0, err
	}
	c := a.Client
	if c == nil {
		c = http.DefaultClient
	}
	resp, err := c.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return 0, fmt.Errorf("exchange rate: HTTP %d", resp.StatusCode)
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
	if err != nil {
		return 0, err
	}
	var d struct {
		Value float64 `json:"value"`
	}
	if err := json.Unmarshal(b, &d); err != nil {
		return 0, err
	}
	return d.Value, nil
}

// OnDemandHourly is the Linux, shared-tenancy on-demand price an hour for an
// instance type in a region; nil when AWS would not say. Never a number written
// here: an unknown price is unknown, not a guess.
func OnDemandHourly(ctx context.Context, api Products, instanceType, region string) *float64 {
	if api == nil || instanceType == "" || region == "" {
		return nil
	}
	raw, err := api.Products(ctx, "AmazonEC2", [][2]string{
		{"instanceType", instanceType}, {"regionCode", region}, {"operatingSystem", "Linux"},
		{"tenancy", "Shared"}, {"preInstalledSw", "NA"}, {"capacitystatus", "Used"}})
	if err != nil || len(raw) == 0 {
		return nil
	}
	var it item
	if json.Unmarshal([]byte(raw[0]), &it) != nil {
		return nil
	}
	var keys []string
	for k := range it.Terms.OnDemand {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		var dks []string
		for d := range it.Terms.OnDemand[k].PriceDimensions {
			dks = append(dks, d)
		}
		sort.Strings(dks)
		for _, d := range dks {
			if v, err := strconv.ParseFloat(it.Terms.OnDemand[k].PriceDimensions[d].PricePerUnit.USD, 64); err == nil {
				return &v
			}
		}
	}
	return nil
}
