// Package pricing is where every rate cg prints comes from: AWS's Price List
// (free), kept for a day, with a stale answer standing in when AWS cannot be
// asked and "unknown" when there has never been one. No price is written down
// here. It replaces the old Bash rates and prices scripts.
//
// Precedence, per price: the environment; then a file of KEY=value lines named
// by CG_PRICES_FILE (how tests run offline); then the cache; then AWS.
package pricing

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Keys are the environment names of the prices read from AWS.
var Keys = []string{
	"CG_S3_USD_GB_MONTH", "CG_EBS_USD_GB_MONTH", "CG_SNAPSHOT_USD_GB_MONTH",
	"CG_EGRESS_USD_GB", "CG_CE_CALL_USD", "CG_XREGION_USD_GB", "CG_IPV4_USD_HOUR",
}

// Rates is every price the reports use. A nil is unknown: it prints as unknown
// and the figure built on it does too, never as zero.
type Rates struct {
	S3GBMonth       *float64
	EBSGBMonth      *float64
	SnapshotGBMonth *float64
	EgressGB        *float64
	CECallUSD       *float64
	XRegionGB       *float64
	IPv4Hour        *float64

	// Not AWS prices: no API reports them, so they are the only two figures
	// with a default. 100 GB a month of data out is free across every region
	// (the Free Tier); GST is 18% on an account billed by AWS India (set
	// CG_TAX_PCT=0 for one billed elsewhere).
	EgressFreeGB float64
	TaxPct       float64

	// FXINRPerUSD is the exchange rate. INRPerUSD is what a dollar of AWS
	// charges costs in rupees: the exchange rate with GST on top, and the one
	// every rupee figure is made with.
	FXINRPerUSD *float64
	INRPerUSD   *float64
}

func (r *Rates) field(key string) **float64 {
	switch key {
	case "CG_S3_USD_GB_MONTH":
		return &r.S3GBMonth
	case "CG_EBS_USD_GB_MONTH":
		return &r.EBSGBMonth
	case "CG_SNAPSHOT_USD_GB_MONTH":
		return &r.SnapshotGBMonth
	case "CG_EGRESS_USD_GB":
		return &r.EgressGB
	case "CG_CE_CALL_USD":
		return &r.CECallUSD
	case "CG_XREGION_USD_GB":
		return &r.XRegionGB
	case "CG_IPV4_USD_HOUR":
		return &r.IPv4Hour
	}
	return nil
}

// Source is where the prices and the exchange rate come from when they are not
// already set. The real one asks AWS and an exchange-rate endpoint.
type Source interface {
	// Prices asks AWS for every price for the region, or fails: a half-read
	// table is an error, never returned.
	Prices(ctx context.Context, region string) (map[string]float64, error)
	// FX is the rupees to a dollar.
	FX(ctx context.Context) (float64, error)
}

// Options are what Load needs besides the environment.
type Options struct {
	Getenv   func(string) string // os.Getenv by default
	CacheDir string              // XDG_CACHE_HOME/cg by default
	Now      func() time.Time
	Source   Source
}

func (o *Options) defaults() {
	if o.Getenv == nil {
		o.Getenv = os.Getenv
	}
	if o.Now == nil {
		o.Now = time.Now
	}
	if o.CacheDir == "" {
		base := o.Getenv("XDG_CACHE_HOME")
		if base == "" {
			home, _ := os.UserHomeDir()
			base = filepath.Join(home, ".cache")
		}
		o.CacheDir = filepath.Join(base, "cg")
	}
}

const day = 24 * time.Hour

func parse(s string) *float64 {
	v, err := strconv.ParseFloat(strings.TrimSpace(s), 64)
	if err != nil {
		return nil
	}
	return &v
}

func readLines(r *os.File) map[string]string {
	out := map[string]string{}
	sc := bufio.NewScanner(r)
	for sc.Scan() {
		k, v, ok := strings.Cut(sc.Text(), "=")
		if ok && strings.HasPrefix(k, "CG_") && v != "" {
			out[k] = v
		}
	}
	return out
}

func readFile(path string) (map[string]string, bool) {
	f, err := os.Open(path)
	if err != nil {
		return nil, false
	}
	defer f.Close()
	return readLines(f), true
}

// cached is the region's price cache: fresh when under a day old; stale is
// still returned, flagged, because a stale price beats none.
func (o *Options) cached(region string) (m map[string]string, fresh bool) {
	path := filepath.Join(o.CacheDir, "prices-"+region)
	m, ok := readFile(path)
	if !ok || len(m) == 0 {
		return nil, false
	}
	st, err := os.Stat(path)
	if err != nil {
		return m, false
	}
	return m, o.Now().Sub(st.ModTime()) < day
}

func writeAtomic(path, body string) {
	if os.MkdirAll(filepath.Dir(path), 0o755) != nil {
		return
	}
	if os.WriteFile(path+".new", []byte(body), 0o644) != nil {
		return
	}
	_ = os.Rename(path+".new", path)
}

// Prices returns the region's price table as KEY=value pairs: the cache when
// fresh, else asked again, else the stale cache, else an error.
func (o *Options) prices(ctx context.Context, region string) (map[string]string, error) {
	if region == "" {
		return nil, errors.New("no region")
	}
	m, fresh := o.cached(region)
	if fresh {
		return m, nil
	}
	if o.Source != nil {
		if got, err := o.Source.Prices(ctx, region); err == nil && len(got) > 0 {
			out := map[string]string{}
			keys := make([]string, 0, len(got))
			for k := range got {
				keys = append(keys, k)
			}
			sort.Strings(keys)
			var body strings.Builder
			for _, k := range keys {
				v := strconv.FormatFloat(got[k], 'g', 6, 64)
				out[k] = v
				fmt.Fprintf(&body, "%s=%s\n", k, v)
			}
			writeAtomic(filepath.Join(o.CacheDir, "prices-"+region), body.String())
			return out, nil
		}
	}
	if m != nil {
		return m, nil
	}
	return nil, errors.New("AWS could not be asked for prices and none are cached")
}

// For is the price table for another region, one key: moving games out of a
// region is billed at THAT region's rate. A named prices file answers for every
// region.
func For(ctx context.Context, o Options, region, key string) *float64 {
	o.defaults()
	if f := o.Getenv("CG_PRICES_FILE"); f != "" {
		if m, ok := readFile(f); ok {
			return parse(m[key])
		}
	}
	m, err := o.prices(ctx, region)
	if err != nil {
		return nil
	}
	return parse(m[key])
}

// Load fills every rate that is not already set. region is the one in use.
func Load(ctx context.Context, o Options, region string) Rates {
	o.defaults()
	var r Rates
	var fill map[string]string
	need := false
	for _, k := range append(append([]string{}, Keys...), "CG_TAX_PCT", "CG_EGRESS_FREE_GB") {
		if o.Getenv(k) == "" {
			need = true
		}
	}
	if need {
		if f := o.Getenv("CG_PRICES_FILE"); f != "" {
			if m, ok := readFile(f); ok {
				fill = m
			}
		}
		if fill == nil {
			fill, _ = o.prices(ctx, region)
		}
	}
	pick := func(k string) string {
		if v := o.Getenv(k); v != "" {
			return v
		}
		return fill[k]
	}
	for _, k := range Keys {
		*r.field(k) = parse(pick(k))
	}
	r.EgressFreeGB = 100
	if v := parse(pick("CG_EGRESS_FREE_GB")); v != nil {
		r.EgressFreeGB = *v
	}
	r.TaxPct = 18
	if v := parse(pick("CG_TAX_PCT")); v != nil {
		r.TaxPct = *v
	}
	// A CG_INR_PER_USD given from outside with no exchange rate beside it is
	// taken as the exchange rate: that is what it meant before tax was counted.
	r.FXINRPerUSD = parse(o.Getenv("CG_FX_INR_PER_USD"))
	if r.FXINRPerUSD == nil {
		r.FXINRPerUSD = parse(o.Getenv("CG_INR_PER_USD"))
	}
	if r.FXINRPerUSD == nil {
		r.FXINRPerUSD = o.fx(ctx)
	}
	r.INRPerUSD = r.FXINRPerUSD
	if r.FXINRPerUSD != nil && r.TaxPct != 0 {
		v := *r.FXINRPerUSD * (1 + r.TaxPct/100)
		r.INRPerUSD = &v
	}
	return r
}

var fxMu sync.Mutex

// fx is today's rate: the cache when under a day old, else fetched, else the
// stale one, else unknown. A rate outside 50-200 is a broken answer, not a
// currency crisis.
func (o *Options) fx(ctx context.Context) *float64 {
	fxMu.Lock()
	defer fxMu.Unlock()
	path := filepath.Join(o.CacheDir, "inr-per-usd")
	var stale *float64
	if b, err := os.ReadFile(path); err == nil {
		stale = parse(string(b))
		if st, err := os.Stat(path); err == nil && stale != nil && o.Now().Sub(st.ModTime()) < day {
			return stale
		}
	}
	if o.Source != nil {
		if v, err := o.Source.FX(ctx); err == nil && v > 50 && v < 200 {
			writeAtomic(path, fmt.Sprintf("%.2f", v))
			r, _ := strconv.ParseFloat(fmt.Sprintf("%.2f", v), 64)
			return &r
		}
	}
	return stale
}
