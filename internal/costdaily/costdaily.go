// Package costdaily reads Cost Explorer's answer (daily, grouped by usage
// type) and turns it into the day-by-day table, the JSON the app draws from,
// and the monthly shape the usage-type report is built from. It is the Go
// form of lib/cost-daily.py and keeps its rules, including the ones learned
// the hard way:
//
//   - only a real region prefix (APS5-, USE1-, EU-) is stripped from a usage
//     type; cutting at the first dash put egress and S3 storage under "other";
//   - a day with nothing billed is left out and counted;
//   - an unknown exchange rate is nil, never 0.
package costdaily

import (
	"encoding/json"
	"fmt"
	"math"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Rates are the figures the report needs. A nil is unknown and shows as such.
type Rates struct {
	INRPerUSD *float64 // a dollar of AWS charges in rupees, GST included
	TaxPct    float64
	FreeGB    *float64 // the free data-transfer-out allowance each month
}

// Money is a number Cost Explorer sends as a string and tests send as either.
type Money float64

func (m *Money) UnmarshalJSON(b []byte) error {
	s := strings.Trim(string(b), `"`)
	f, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return fmt.Errorf("not a number: %q", s)
	}
	*m = Money(f)
	return nil
}

// Group is one usage type's charge and quantity on one day.
type Group struct {
	U string `json:"u"`
	C Money  `json:"c"`
	Q Money  `json:"q"`
}

// Day is one day of the answer.
type Day struct {
	D string  `json:"d"`
	G []Group `json:"g"`
}

// Parse reads the answer. A broken answer is an error, never an empty month.
func Parse(b []byte) ([]Day, error) {
	var days []Day
	if err := json.Unmarshal(b, &days); err != nil {
		return nil, err
	}
	if days == nil {
		return nil, fmt.Errorf("not a list")
	}
	return days, nil
}

var regionPrefix = regexp.MustCompile(`^[A-Z]{2,4}[0-9]{0,2}-`)

// StripRegion removes a region prefix and nothing else.
func StripRegion(usageType string) string {
	return regionPrefix.ReplaceAllString(usageType, "")
}

// Columns are the kinds of charge, in the order the table shows them.
var Columns = []string{"compute", "s3", "disk", "egress", "api", "other"}

// Bucket says which column a usage type belongs in.
func Bucket(usageType string) string {
	u := StripRegion(usageType)
	switch {
	case strings.HasPrefix(u, "BoxUsage"), strings.HasPrefix(u, "SpotUsage"):
		return "compute"
	case strings.HasPrefix(u, "DataTransfer-Out-Bytes"):
		return "egress"
	case strings.HasPrefix(u, "TimedStorage"), strings.HasPrefix(u, "Requests-Tier"):
		return "s3"
	case strings.Contains(u, "VolumeUsage"), strings.Contains(u, "SnapshotUsage"):
		return "disk"
	case strings.HasPrefix(u, "APIRequest"):
		return "api"
	}
	return "other"
}

// round is Python's round(x, n): correctly rounded, ties to even on the exact
// binary value.
func round(x float64, n int) float64 {
	v, _ := strconv.ParseFloat(strconv.FormatFloat(x, 'f', n, 64), 64)
	return v
}

// Usage is one usage type summed over the month, in the shape the report reads.
type Usage struct {
	U string
	C float64
	Q float64
}

// Aggregate sums the month per usage type, in the order each first appears.
func Aggregate(days []Day) []Usage {
	var out []Usage
	at := map[string]int{}
	for _, d := range days {
		for _, g := range d.G {
			i, ok := at[g.U]
			if !ok {
				i = len(out)
				at[g.U] = i
				out = append(out, Usage{U: g.U})
			}
			out[i].C += float64(g.C)
			out[i].Q += float64(g.Q)
		}
	}
	return out
}

// Projection is where the month is heading if the rest looks like the part
// that has already happened. Nil fields are unknown.
type Projection struct {
	DaysElapsed  int      `json:"days_elapsed"`
	DaysInMonth  *int     `json:"days_in_month"`
	ProjectedUSD *float64 `json:"projected_usd"`
	ProjectedINR *int64   `json:"projected_inr"`
}

// Project works out the pace from the whole days before today. Today is
// partial and the bill runs about a day behind, so it is not in the pace.
func Project(days []Day, monthTotal float64, r Rates) Projection {
	p := Projection{DaysElapsed: len(days)}
	if len(days) == 0 || monthTotal <= 0 || len(days) < 2 {
		return p
	}
	whole := days[:len(days)-1]
	t, err := time.Parse("2006-01-02", days[0].D)
	if err != nil {
		return p
	}
	inMonth := time.Date(t.Year(), t.Month()+1, 0, 0, 0, 0, 0, time.UTC).Day()
	var done float64
	for _, d := range whole {
		for _, g := range d.G {
			done += float64(g.C)
		}
	}
	usd := done / float64(len(whole)) * float64(inMonth)
	p.DaysInMonth = &inMonth
	u := round(usd, 4)
	p.ProjectedUSD = &u
	if r.INRPerUSD != nil && *r.INRPerUSD != 0 {
		n := int64(math.RoundToEven(usd * *r.INRPerUSD))
		p.ProjectedINR = &n
	}
	return p
}

type dayRow struct {
	date  string
	hours float64
	cols  map[string]float64
	total float64
}

func rows(days []Day) (out []dayRow, empty int) {
	for _, day := range days {
		cols := map[string]float64{}
		var hours float64
		for _, g := range day.G {
			b := Bucket(g.U)
			cols[b] += float64(g.C)
			if b == "compute" {
				hours += float64(g.Q)
			}
		}
		var total float64
		for _, k := range Columns {
			total += cols[k]
		}
		if total <= 0.0005 && hours <= 0 {
			empty++
			continue
		}
		out = append(out, dayRow{day.D, hours, cols, total})
	}
	return
}

func inr(usd float64, r Rates) string {
	if r.INRPerUSD == nil {
		return fmt.Sprintf("%8s", "?")
	}
	return fmt.Sprintf("%8.0f", usd**r.INRPerUSD)
}

func cell(v float64) string {
	if v <= 0.0005 {
		return fmt.Sprintf("%9s", "-")
	}
	return fmt.Sprintf("%9.2f", v)
}

// Table is the day-by-day table, as the plain report prints it.
func Table(days []Day, r Rates) string {
	rs, empty := rows(days)
	var b strings.Builder
	if len(rs) == 0 {
		return "  nothing billed yet this month\n"
	}
	head := fmt.Sprintf("  %-11s %5s", "DATE", "HRS")
	for _, c := range Columns {
		head += fmt.Sprintf("%9s", strings.ToUpper(c))
	}
	head += fmt.Sprintf("%9s%8s", "TOTAL", "INR")
	b.WriteString(head + "\n")
	month := map[string]float64{}
	var monthHours float64
	for _, d := range rs {
		hrs := "-"
		if d.hours > 0 {
			hrs = fmt.Sprintf("%.1f", d.hours)
		}
		fmt.Fprintf(&b, "  %-11s %5s", d.date, hrs)
		for _, c := range Columns {
			b.WriteString(cell(d.cols[c]))
			month[c] += d.cols[c]
		}
		fmt.Fprintf(&b, "%9.2f%s\n", d.total, inr(d.total, r))
		monthHours += d.hours
	}
	b.WriteString("  " + strings.Repeat("-", len(head)-2) + "\n")
	var monthTotal float64
	for _, c := range Columns {
		monthTotal += month[c]
	}
	fmt.Fprintf(&b, "  %-11s %5.1f", "TOTAL", monthHours)
	for _, c := range Columns {
		b.WriteString(cell(month[c]))
	}
	fmt.Fprintf(&b, "%9.2f%s\n", monthTotal, inr(monthTotal, r))
	rate := "INR unknown - no exchange rate could be read"
	if r.INRPerUSD != nil {
		rate = fmt.Sprintf("INR at %.2f a dollar", *r.INRPerUSD)
		if r.TaxPct != 0 {
			rate += fmt.Sprintf(" (%g%% GST included)", r.TaxPct)
		}
	}
	if empty > 0 {
		fmt.Fprintf(&b, "  %d day(s) with nothing billed are not shown. USD before tax, and %s.\n", empty, rate)
	} else {
		fmt.Fprintf(&b, "  USD before tax, and %s.\n", rate)
	}
	if pr := Project(days, monthTotal, r); pr.ProjectedINR != nil && pr.DaysElapsed < *pr.DaysInMonth {
		fmt.Fprintf(&b, "  On this pace: %.2f USD / %d INR by the end of the month (%d of its %d days so far).\n",
			*pr.ProjectedUSD, *pr.ProjectedINR, pr.DaysElapsed, *pr.DaysInMonth)
	}
	return b.String()
}

// Header is the line above the table. The figures are the whole account's.
const Header = "billed day by day (the whole AWS account, every region - lags a day):"

// DayJSON is one day that billed, in the JSON.
type DayJSON struct {
	Date    string  `json:"date"`
	Hours   float64 `json:"hours"`
	Compute float64 `json:"compute"`
	S3      float64 `json:"s3"`
	Disk    float64 `json:"disk"`
	Egress  float64 `json:"egress"`
	API     float64 `json:"api"`
	Other   float64 `json:"other"`
	Total   float64 `json:"total"`
}

// UsageJSON is one usage type over the month, biggest first.
type UsageJSON struct {
	Type string  `json:"type"`
	Qty  float64 `json:"qty"`
	USD  float64 `json:"usd"`
}

// Hours are the machine hours by purchase model.
type Hours struct {
	OnDemand float64 `json:"on_demand"`
	Spot     float64 `json:"spot"`
}

// PerHour is what an hour cost, per purchase model; nil with no hours.
type PerHour struct {
	OnDemand *float64 `json:"on_demand"`
	Spot     *float64 `json:"spot"`
}

// Egress is the free data-out allowance against what has been used.
type Egress struct {
	GBUsed float64  `json:"gb_used"`
	GBFree *float64 `json:"gb_free"`
	GBLeft *float64 `json:"gb_left"`
}

// Summary is `cg cost --json`'s "month" object: everything the answer holds.
type Summary struct {
	Days     []DayJSON   `json:"days"`
	Usage    []UsageJSON `json:"usage"`
	TotalUSD float64     `json:"total_usd"`
	TotalINR *int64      `json:"total_inr"`
	Projection
	Hours      Hours    `json:"hours"`
	USDPerHour PerHour  `json:"usd_per_hour"`
	Egress     Egress   `json:"egress"`
	INRPerUSD  *float64 `json:"inr_per_usd"`
}

// Summarize is the answer as data.
func Summarize(days []Day, r Rates) Summary {
	var s Summary
	s.Days = []DayJSON{}
	var usage []UsageJSON
	at := map[string]int{}
	var hrs, cost Hours
	var outGB float64
	for _, day := range days {
		cols := map[string]float64{}
		var dayHours float64
		for _, g := range day.G {
			c, q := float64(g.C), float64(g.Q)
			u := StripRegion(g.U)
			cols[Bucket(g.U)] += c
			i, ok := at[u]
			if !ok {
				i = len(usage)
				at[u] = i
				usage = append(usage, UsageJSON{Type: u})
			}
			usage[i].Qty += q
			usage[i].USD += c
			switch {
			case strings.HasPrefix(u, "SpotUsage"):
				hrs.Spot += q
				cost.Spot += c
				dayHours += q
			case strings.HasPrefix(u, "BoxUsage"):
				hrs.OnDemand += q
				cost.OnDemand += c
				dayHours += q
			case strings.HasPrefix(u, "DataTransfer-Out-Bytes"):
				outGB += q
			}
		}
		var total float64
		for _, k := range Columns {
			total += cols[k]
		}
		if total <= 0.0005 && dayHours <= 0 {
			continue
		}
		s.Days = append(s.Days, DayJSON{day.D, round(dayHours, 2),
			round(cols["compute"], 4), round(cols["s3"], 4), round(cols["disk"], 4),
			round(cols["egress"], 4), round(cols["api"], 4), round(cols["other"], 4),
			round(total, 4)})
	}
	var month float64
	for _, d := range s.Days {
		month += d.Total
	}
	month = round(month, 4)
	s.Usage = []UsageJSON{}
	for _, u := range usage {
		s.Usage = append(s.Usage, UsageJSON{u.Type, round(u.Qty, 4), round(u.USD, 4)})
	}
	sort.SliceStable(s.Usage, func(i, j int) bool { return s.Usage[i].USD > s.Usage[j].USD })
	s.TotalUSD = month
	if r.INRPerUSD != nil {
		n := int64(math.RoundToEven(month * *r.INRPerUSD))
		s.TotalINR = &n
	}
	s.Projection = Project(days, month, r)
	s.Hours = Hours{round(hrs.OnDemand, 2), round(hrs.Spot, 2)}
	per := func(c, h float64) *float64 {
		if h == 0 {
			return nil
		}
		v := round(c/h, 4)
		return &v
	}
	s.USDPerHour = PerHour{per(cost.OnDemand, hrs.OnDemand), per(cost.Spot, hrs.Spot)}
	s.Egress = Egress{GBUsed: round(outGB, 2), GBFree: r.FreeGB}
	if r.FreeGB != nil {
		left := round(math.Max(0, *r.FreeGB-outGB), 2)
		s.Egress.GBLeft = &left
	}
	s.INRPerUSD = r.INRPerUSD
	return s
}

// AggregateJSON is the monthly shape, a usage type per entry with its cost and
// quantity as decimal strings, as lib/cost-report.py read them.
func AggregateJSON(days []Day) []byte {
	type entry struct {
		U string `json:"u"`
		C string `json:"c"`
		Q string `json:"q"`
	}
	out := []entry{}
	for _, u := range Aggregate(days) {
		out = append(out, entry{u.U, fmt.Sprintf("%.10f", u.C), fmt.Sprintf("%.6f", u.Q)})
	}
	b, _ := json.Marshal(out)
	return b
}

// Mode is what to print.
type Mode int

const (
	ModeTable Mode = iota
	ModeJSON
	ModeAggregate
)

// Render is what lib/cost-daily.py printed for the answer in `in`: the table
// with its heading, the JSON, or the aggregate. An answer that cannot be read
// is said so and never rendered as an empty month.
func Render(mode Mode, in []byte, r Rates) string {
	days, err := Parse(in)
	if err != nil {
		switch mode {
		case ModeJSON:
			return "{}\n"
		case ModeAggregate:
			return "[]\n"
		}
		return "  (Cost Explorer unavailable)\n"
	}
	switch mode {
	case ModeJSON:
		b, _ := json.MarshalIndent(Summarize(days, r), "", "  ")
		return string(b) + "\n"
	case ModeAggregate:
		return string(AggregateJSON(days)) + "\n"
	}
	return Header + "\n" + Table(days, r)
}
