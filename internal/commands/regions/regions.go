// Package regions is `cg regions`: which regions this account may use, and
// turning one on. What each one can actually rent you is `cg sweep`.
package regions

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/account"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	"github.com/aws/smithy-go"
)

// EC2API lists the regions already on.
type EC2API interface {
	DescribeRegions(context.Context, *ec2.DescribeRegionsInput, ...func(*ec2.Options)) (*ec2.DescribeRegionsOutput, error)
}

// AccountAPI is the Account API, which knows the ones that are not: unlike
// describe-regions, which only lists what is already on - exactly the set this
// is not about.
type AccountAPI interface {
	ListRegions(context.Context, *account.ListRegionsInput, ...func(*account.Options)) (*account.ListRegionsOutput, error)
	GetRegionOptStatus(context.Context, *account.GetRegionOptStatusInput, ...func(*account.Options)) (*account.GetRegionOptStatusOutput, error)
	EnableRegion(context.Context, *account.EnableRegionInput, ...func(*account.Options)) (*account.EnableRegionOutput, error)
}

// Region is a region and its opt-in word.
type Region struct {
	Region string  `json:"region"`
	OptIn  *string `json:"optin"`
}

// List is `cg regions --json`: the enabled regions and nothing else. Separate
// from the sweep on purpose: the app needs a region picker the moment it opens,
// and the sweep takes minutes. Only enabled regions, because those are the ones
// a dropdown can switch to without an opt-in this app has no business performing.
type List struct {
	Configured string   `json:"configured"`
	Regions    []Region `json:"regions"`
}

// Enabled lists them. The configured region is in the list even if
// describe-regions could not be read: a picker that silently drops the current
// value looks like the setting was lost, and the first thing anyone does then is
// set it again by hand. Sorted here rather than trusting the query: a dropdown
// whose order depends on what the API happened to return reorders itself under
// the cursor.
func Enabled(ctx context.Context, c EC2API, configured string) List {
	l := List{Configured: configured, Regions: []Region{}}
	if o, err := c.DescribeRegions(ctx, &ec2.DescribeRegionsInput{}); err == nil {
		for _, r := range o.Regions {
			l.Regions = append(l.Regions, Region{aws.ToString(r.RegionName), opt(aws.ToString(r.OptInStatus))})
		}
	}
	if configured != "" {
		have := false
		for _, r := range l.Regions {
			have = have || r.Region == configured
		}
		if !have {
			l.Regions = append(l.Regions, Region{configured, nil})
		}
	}
	sort.Slice(l.Regions, func(i, j int) bool { return l.Regions[i].Region < l.Regions[j].Region })
	return l
}

func opt(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

// Show is the picker for a person.
func Show(l List) string {
	if len(l.Regions) == 0 {
		return "  could not list regions - check your AWS credentials\n"
	}
	var b strings.Builder
	for _, r := range l.Regions {
		mark := " "
		if r.Region == l.Configured {
			mark = "*"
		}
		fmt.Fprintf(&b, "  %s%s\n", mark, r.Region)
	}
	b.WriteString("\n  * is the region in use. Only enabled regions are listed.\n")
	b.WriteString("  What each one can actually rent you: cg sweep\n")
	return b.String()
}

// OptIn is `cg regions optin --json`.
type OptIn struct {
	Regions  []OptRegion `json:"regions"`
	Disabled []string    `json:"disabled"` // which ones could be turned on
	Enabling []string    `json:"enabling"` // and which are mid-flight
	Error    string      `json:"error,omitempty"`
}

// OptRegion is a region and its Account API status.
type OptRegion struct {
	Region string  `json:"region"`
	Status *string `json:"status"`
}

// ReadOptIn lists every region and whether this account may use it.
func ReadOptIn(ctx context.Context, c AccountAPI) OptIn {
	o := OptIn{Regions: []OptRegion{}, Disabled: []string{}, Enabling: []string{}}
	var token *string
	for {
		r, err := c.ListRegions(ctx, &account.ListRegionsInput{MaxResults: aws.Int32(50), NextToken: token})
		if err != nil {
			return OptIn{Regions: []OptRegion{}, Disabled: []string{}, Enabling: []string{}, Error: "could not read the region list"}
		}
		for _, x := range r.Regions {
			st := string(x.RegionOptStatus)
			o.Regions = append(o.Regions, OptRegion{aws.ToString(x.RegionName), opt(st)})
		}
		if r.NextToken == nil || *r.NextToken == "" {
			break
		}
		token = r.NextToken
	}
	sort.Slice(o.Regions, func(i, j int) bool { return o.Regions[i].Region < o.Regions[j].Region })
	for _, r := range o.Regions {
		switch {
		case r.Status != nil && *r.Status == "DISABLED":
			o.Disabled = append(o.Disabled, r.Region)
		case r.Status != nil && *r.Status == "ENABLING":
			o.Enabling = append(o.Enabling, r.Region)
		}
	}
	return o
}

func on(s string) bool { return s == "ENABLED" || s == "ENABLED_BY_DEFAULT" }

// ShowOptIn is the human view: how many are on, and the rest by status.
func ShowOptIn(o OptIn) string {
	var b strings.Builder
	n := 0
	for _, r := range o.Regions {
		if r.Status != nil && on(*r.Status) {
			n++
		}
	}
	fmt.Fprintf(&b, "  enabled: %d\n", n)
	for _, r := range o.Regions {
		if r.Status == nil || !on(*r.Status) {
			st := ""
			if r.Status != nil {
				st = strings.ToLower(*r.Status)
			}
			fmt.Fprintf(&b, "  %-16s %s\n", r.Region, st)
		}
	}
	return b.String()
}

// Enabler turns a region on: one call, and AWS works through DISABLED ->
// ENABLING -> ENABLED over a few minutes. It is an ACCOUNT-level change though -
// everything on the account can use the region afterwards - and undoing it is
// slower than doing it, so it is said before it is done.
type Enabler struct {
	Account AccountAPI
	Say     func(string)
	LogAs   func(kind, text string)
	Log     func(string)
	Sleep   func(time.Duration) // the poll interval; tests make it instant
}

func (e Enabler) status(ctx context.Context, region string) (string, error) {
	// get-region-opt-status, not list-regions: list-regions has no region-name
	// filter at all, so the filtered call failed and every region looked like
	// one AWS had never heard of.
	o, err := e.Account.GetRegionOptStatus(ctx, &account.GetRegionOptStatusInput{RegionName: aws.String(region)})
	if err != nil {
		return "", err
	}
	return string(o.RegionOptStatus), nil
}

// Enable is `cg regions enable <region>`.
func (e Enabler) Enable(ctx context.Context, region string) int {
	st, _ := e.status(ctx, region)
	switch st {
	case "ENABLED", "ENABLED_BY_DEFAULT":
		e.LogAs("ok", region+" is already enabled")
		return 0
	case "ENABLING":
		e.LogAs("warn", region+" is already being enabled - that takes a few minutes")
	case "":
		e.LogAs("fail", "AWS does not list a region called "+region)
		return 1
	default:
		e.Say("enabling " + region)
		e.Log("  an account-level change: everything on this account can use the region")
		e.Log("  afterwards, and turning it back off is slower than turning it on.")
		_, err := e.Account.EnableRegion(ctx, &account.EnableRegionInput{RegionName: aws.String(region)})
		if err != nil {
			msg := strings.Join(strings.Fields(err.Error()), " ")
			if len(msg) > 300 {
				msg = msg[:300]
			}
			e.LogAs("fail", "AWS refused: "+msg)
			// The two that are worth naming, because neither is a retry.
			var ae smithy.APIError
			low := strings.ToLower(err.Error())
			switch {
			case strings.Contains(low, "accessdenied") || strings.Contains(low, "not authorized") || (asAPI(err, &ae) && ae.ErrorCode() == "AccessDeniedException"):
				e.Log("  this key needs account:EnableRegion")
			case strings.Contains(low, "organization"):
				e.Log("  in an AWS Organization only the management account can enable regions")
			}
			return 1
		}
		e.LogAs("ok", "asked AWS to enable "+region)
	}
	// Watched rather than assumed: it is minutes, not seconds, and "asked" is
	// not the same as "usable".
	for i := 1; i <= 6; i++ {
		e.Sleep(10 * time.Second)
		st, _ := e.status(ctx, region)
		switch st {
		case "ENABLED", "ENABLED_BY_DEFAULT":
			e.LogAs("ok", region+" is enabled")
			return 0
		case "ENABLING":
			e.Log(fmt.Sprintf("  still enabling (%ds)", i*10))
		default:
			if st == "" {
				st = "unknown"
			}
			e.Log("  status: " + st)
		}
	}
	e.LogAs("warn", region+" is still enabling - this is normal, it can take several minutes")
	e.Log("  check again with:  cg regions optin")
	return 0
}

func asAPI(err error, target *smithy.APIError) bool {
	for err != nil {
		if a, ok := err.(smithy.APIError); ok {
			*target = a
			return true
		}
		u, ok := err.(interface{ Unwrap() error })
		if !ok {
			return false
		}
		err = u.Unwrap()
	}
	return false
}
