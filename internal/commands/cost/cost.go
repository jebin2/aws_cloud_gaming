package cost

import (
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/jebin2/aws_cloud_gaming/internal/costdaily"
	"github.com/jebin2/aws_cloud_gaming/internal/costfacts"
	"github.com/jebin2/aws_cloud_gaming/internal/costreport"
	"github.com/jebin2/aws_cloud_gaming/internal/format"
	"github.com/jebin2/aws_cloud_gaming/internal/pricing"
)

// Inputs is everything `cg cost` prints, already read. Rendering is pure: the
// same inputs print the same report, which is what the tests rely on.
type Inputs struct {
	Facts          costfacts.Facts
	Rates          pricing.Rates
	Host, Region   string
	ConfiguredType string   // GAME_INSTANCE_TYPE, used when there is no box to ask
	OnDemandRate   *float64 // the on-demand price of the machine's type; nil if unknown
	BitrateKBPS    float64
	Now            time.Time
	CacheEgress    costreport.Cache
}

func (in Inputs) instance() *costfacts.Instance {
	if in.Facts.Instance.OK {
		return in.Facts.Instance.V
	}
	return nil
}

// Estimate builds the "not yet billed" inputs from the facts.
func (in Inputs) Estimate() Estimate {
	f := in.Facts
	inst := in.instance()
	e := Estimate{
		Hours: f.Hours, Kind: "on demand", HourlyRate: in.OnDemandRate,
		DiskGB: f.DiskGB(), SnapGB: f.SnapshotGB(),
		NoInstance: f.Instance.OK && inst == nil,
		Day:        in.Now.UTC().Day(),
		MonthDays:  time.Date(in.Now.Year(), in.Now.Month()+1, 0, 0, 0, 0, 0, time.UTC).Day(),
	}
	if f.Volumes.OK {
		e.DiskGBMon = costfacts.Known[float64]{V: GBMonths(dedupe(f.Volumes.V), in.Now.UTC()), OK: true}
	}
	// The machine as it is - its type, and spot or on demand - not the settings,
	// which were priced as on demand whatever the box was: a spot rig's estimate
	// read four or five times what it cost.
	if inst != nil && inst.Lifecycle == "spot" {
		e.Kind, e.HourlyRate = "spot, price now", f.SpotPrice
	}
	return e
}

// MachineType is the type to price: the box's own, else the setting.
func (in Inputs) MachineType() string {
	if inst := in.instance(); inst != nil && inst.Type != "" {
		return inst.Type
	}
	return in.ConfiguredType
}

func dedupe(v []costfacts.Volume) []costfacts.Volume {
	seen := map[string]bool{}
	var out []costfacts.Volume
	for _, x := range v {
		if !seen[x.ID] {
			seen[x.ID] = true
			out = append(out, x)
		}
	}
	return out
}

func count(k costfacts.Known[float64], unit string) string {
	if !k.OK {
		return "?"
	}
	return strconv.FormatFloat(k.V, 'f', -1, 64)
}

func lastLine(s string) string {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	return strings.TrimSpace(lines[len(lines)-1])
}

func (in Inputs) archiveLine() string {
	b := in.Facts.Bucket
	switch b.State {
	case costfacts.BucketUnset:
		return "  game library    not set up yet - cg init creates it\n"
	case costfacts.BucketMissing:
		return fmt.Sprintf("  game library    none - s3://%s does not exist\n", b.Name)
	case costfacts.BucketUnreadable:
		return fmt.Sprintf("  game library    s3://%s  COULD NOT BE READ - %s\n", b.Name, lastLine(b.Reason))
	}
	a := in.Facts.Archive
	switch {
	case !a.OK:
		return fmt.Sprintf("  game library    s3://%s  COULD NOT BE LISTED - its size is unknown\n", b.Name)
	case a.V.Objects == 0:
		return fmt.Sprintf("  game library    s3://%s  EMPTY - no games archived\n", b.Name)
	case in.Rates.S3GBMonth != nil:
		return fmt.Sprintf("  game library    s3://%s  %d objects, %s  ($%.2f/mo)\n", b.Name, a.V.Objects, format.IEC(a.V.Bytes),
			float64(a.V.Bytes)/1073741824**in.Rates.S3GBMonth)
	}
	return fmt.Sprintf("  game library    s3://%s  %d objects, %s\n", b.Name, a.V.Objects, format.IEC(a.V.Bytes))
}

// resources is the block that says what exists in the region.
func (in Inputs) resources() string {
	f := in.Facts
	var b strings.Builder
	fmt.Fprintf(&b, "resources in %s:\n", in.Region)
	inst := in.instance()
	switch {
	case !f.Instance.OK:
		b.WriteString("  instance        ? (AWS could not be asked)\n")
	case inst == nil:
		b.WriteString("  instance        none\n")
	default:
		fmt.Fprintf(&b, "  instance        %s  (%s)\n", inst.ID, inst.State)
	}
	disk := f.DiskGB()
	orphan := ""
	if disk.OK && disk.V != 0 && f.Instance.OK && inst == nil {
		orphan = "  <- ORPHANED, still billing"
	}
	fmt.Fprintf(&b, "  volumes         %s GB %s\n", count(disk, "GB"), orphan)
	fmt.Fprintf(&b, "  snapshots       %s GB\n", count(f.SnapshotGB(), "GB"))
	if f.Images.OK {
		fmt.Fprintf(&b, "  images          %d\n", len(f.Images.V))
	} else {
		b.WriteString("  images          ?\n")
	}
	fmt.Fprintf(&b, "  key pair        %s\n", presence(f.KeyPair, in.Host))
	fmt.Fprintf(&b, "  security group  %s\n", presence(f.SecGroup, in.Host+"-sg"))
	// The game library is in S3 now; the EBS volume is legacy and the only thing
	// worth saying about it is that it still bills.
	if f.Legacy.OK && f.Legacy.V != nil {
		cost := "?"
		if in.Rates.EBSGBMonth != nil {
			cost = fmt.Sprintf("%.2f", f.Legacy.V.GB**in.Rates.EBSGBMonth)
		}
		fmt.Fprintf(&b, "  old EBS volume  %s  %.0f GB in %s  (~$%s/mo, LEGACY - cg games --volume --delete)\n",
			f.Legacy.V.ID, f.Legacy.V.GB, f.Legacy.V.AZ, cost)
	} else {
		b.WriteString(in.archiveLine())
	}
	switch {
	case !f.Budget.OK:
		b.WriteString("  budget          ?\n")
	case f.Budget.V == nil:
		b.WriteString("  budget          none\n")
	default:
		fmt.Fprintf(&b, "  budget          $%.0f/month\n", *f.Budget.V)
	}
	// Said for what it covers: this region's machine and disks. Saved games, and
	// other regions, are told apart.
	if f.Instance.OK && inst == nil && disk.OK && disk.V == 0 && f.SnapshotGB().OK && f.SnapshotGB().V == 0 && f.Images.OK && len(f.Images.V) == 0 {
		fmt.Fprintf(&b, "\nno machine, disks, snapshots or images in %s.\n\n", in.Region)
	}
	return b.String()
}

func presence(k costfacts.Known[bool], name string) string {
	switch {
	case !k.OK:
		return "?"
	case k.V:
		return name
	}
	return "none"
}

// Human is the plain report. daily adds the day-by-day table above the
// usage-type summary.
func (in Inputs) Human(daily bool, extra string) string {
	var b strings.Builder
	b.WriteString(in.resources())
	b.WriteString(extra)
	b.WriteString(in.Estimate().Render(in.Rates))
	b.WriteString("\n")
	credits := "?"
	if in.Facts.Credits.OK {
		credits = strconv.FormatFloat(in.Facts.Credits.V, 'f', -1, 64)
	}
	fmt.Fprintf(&b, "credits remaining: $%s\n", credits)
	b.WriteString("billed so far (the whole AWS account, every region - lags a day):\n")
	if !in.Facts.Month.OK {
		b.WriteString("  (Cost Explorer unavailable)\n")
	} else {
		days := in.Facts.Month.V
		cr := costdaily.Rates{INRPerUSD: in.Rates.INRPerUSD, TaxPct: in.Rates.TaxPct, FreeGB: &in.Rates.EgressFreeGB}
		if daily {
			b.WriteString(costdaily.Header + "\n" + costdaily.Table(days, cr) + "\n")
		}
		b.WriteString(costreport.Render(costdaily.Aggregate(days), costreport.Settings{
			INRPerUSD: in.Rates.INRPerUSD, EgressUSD: in.Rates.EgressGB, FreeGB: &in.Rates.EgressFreeGB, KBPS: in.BitrateKBPS},
			in.CacheEgress))
	}
	if in.Facts.Budget.OK && in.Facts.Budget.V == nil {
		b.WriteString("\n  WARNING: no budget exists - nothing will alert you about spend.\n")
		b.WriteString("  Run cg init to create it.\n")
	}
	return b.String()
}
