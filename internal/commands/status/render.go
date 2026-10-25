package status

import (
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/jebin2/aws_cloud_gaming/internal/format"
	"github.com/jebin2/aws_cloud_gaming/internal/pricing"
)

// View is what the report is drawn from: the facts, the settings that give
// them meaning, and the prices.
type View struct {
	Facts        Facts
	Rates        pricing.Rates
	Host, Node   string
	Region       string
	Type         string
	Now          time.Time
	Flags        struct{ Notifications, TailscaleAPIKey, AlertEmail bool }
	DiskGB       int
	Spot         string
	LastBuildMin Known[int]
}

func (v View) configDisk() int { return v.DiskGB }
func (v View) configSpot() string {
	if v.Spot == "" {
		return "auto"
	}
	return v.Spot
}

func num(k Known[float64]) string {
	if !k.OK {
		return "?"
	}
	return strconv.FormatFloat(k.V, 'f', -1, 64)
}

func inum(k Known[int]) string {
	if !k.OK {
		return "?"
	}
	return strconv.Itoa(k.V)
}

func quotaLine(label string, q Known[float64], vcpus Known[int], warn string) string {
	if !q.OK {
		return fmt.Sprintf("  %s ?\n", label)
	}
	s := ""
	if vcpus.OK && q.V < float64(vcpus.V) {
		s = warn
	}
	return fmt.Sprintf("  %s %.0f vCPU%s\n", label, q.V, s)
}

// Human is the plain report.
func (v View) Human() string {
	f := v.Facts
	var b strings.Builder
	const markOK, markNo = "  [ok]   ", "  [--]   "

	b.WriteString("ACCOUNT\n")
	id := f.AccountID
	if id == "" {
		id = "NO CREDENTIALS"
	}
	fmt.Fprintf(&b, "  id              %s\n", id)
	note := ""
	if f.Plan == "FREE" {
		note = "   <- cannot launch GPU instances at all"
	}
	fmt.Fprintf(&b, "  plan            %s%s\n", f.Plan, note)
	fmt.Fprintf(&b, "  credits         $%s\n", f.Credits)

	fmt.Fprintf(&b, "\nQUOTAS in %s\n", v.Region)
	fmt.Fprintf(&b, "  %s needs %s vCPU\n", v.Type, inum(f.Spec.VCPUs))
	b.WriteString(quotaLine("on-demand G/VT ", f.QuotaOnDemand, f.Spec.VCPUs, "  <- too low to launch"))
	b.WriteString(quotaLine("spot G/VT      ", f.QuotaSpot, f.Spec.VCPUs, "  <- GAME_SPOT=1 will fail"))

	if f.ErrorMessage != "" {
		b.WriteString("\nCREDENTIALS\n")
		fmt.Fprintf(&b, "  %s Everything below is unknown, not empty.\n", f.ErrorMessage)
		b.WriteString("  Your games are in S3 and nothing here can see them right now.\n")
		b.WriteString("  Set a working key (cg creds set), then run this again.\n")
	}

	fmt.Fprintf(&b, "\nRESOURCES in %s\n", v.Region)
	if f.ErrorMessage != "" {
		// Printing "none", "0" and "not set up yet" here would describe an
		// account nobody looked at. Say that instead.
		b.WriteString("  unknown - the credentials above were rejected, so nothing was read\n")
	} else {
		v.resources(&b)
	}
	if f.SecGroup.OK && f.SecGroup.V != "none" {
		for _, in := range f.Inbound {
			fmt.Fprintf(&b, "    inbound       %s\n", in)
		}
	}

	b.WriteString("\nCOST GUARDS\n")
	switch {
	case f.BudgetLimit.OK:
		// AWS Budgets populates CalculatedSpend up to 24h AFTER a budget is
		// created, and `cg init` recreates this budget on every build - so it
		// reads $0.00 almost always. Printed bare, that says "nothing has been
		// spent" beside a real month, the opposite of what a guard should say.
		if f.BudgetSpent.V == 0 {
			fmt.Fprintf(&b, "  budget          $%.0f limit, AWS reports $0.00 spent - not calculated yet\n", f.BudgetLimit.V)
			b.WriteString("                  (Budgets lags up to 24h after creation; real spend: cg cost)\n")
		} else {
			fmt.Fprintf(&b, "  budget          $%.0f limit, $%.2f spent so far\n", f.BudgetLimit.V, f.BudgetSpent.V)
		}
	case f.BudgetExists.OK && !f.BudgetExists.V:
		b.WriteString("  budget          missing\n")
	default:
		b.WriteString("  budget          ? (AWS could not be asked)\n")
	}
	fmt.Fprintf(&b, "  budget alerts   %s configured\n", inum(f.BudgetAlerts))
	fmt.Fprintf(&b, "  game archive    %s\n", f.Decision)

	b.WriteString("\nLOCAL\n")
	line := func(good bool, yes, no string) {
		if good {
			b.WriteString(markOK + yes + "\n")
		} else {
			b.WriteString(markNo + no + "\n")
		}
	}
	line(f.Tailscale, "tailscale up", "tailscale not running")
	line(f.Moonlight, "moonlight installed", "moonlight missing (pacman -S moonlight-qt)")
	line(f.SSHKey, fmt.Sprintf("ssh key ~/.ssh/%s.pem", v.Host), fmt.Sprintf("no ssh key ~/.ssh/%s.pem", v.Host))
	line(f.AuthKeyKnown(), "tailscale auth key in .env", "no tailscale auth key (setup will prompt)")
	switch {
	case f.Node.Found && f.Node.Online:
		b.WriteString(markOK + "tailnet node " + f.Node.Name + " online\n")
	case f.Node.Found:
		// Registered but offline is the normal state while the box is stopped;
		// it is only a problem if it lingers after a destroy.
		b.WriteString(markNo + "tailnet node " + f.Node.Name + " registered but offline\n")
	default:
		b.WriteString(markNo + "no '" + v.Node + "' node on the tailnet\n")
	}
	return b.String()
}

// AuthKeyKnown is whether a Tailscale auth key is set in .env.
func (f Facts) AuthKeyKnown() bool { return f.authKey }

func (v View) resources(b *strings.Builder) {
	f := v.Facts
	switch {
	case !f.Box.OK:
		b.WriteString("  instance        ? (AWS could not be asked)\n")
	case f.Box.V == nil:
		b.WriteString("  instance        none\n")
	default:
		x := f.Box.V
		fmt.Fprintf(b, "  instance        %s  %s  %s\n", x.ID, x.Type, x.State)
		fmt.Fprintf(b, "  public ip       %s\n", x.PublicIP)
		fmt.Fprintf(b, "  launched        %s\n", x.Launched.UTC().Format("2006-01-02T15:04:05+00:00"))
	}
	// A stream held open from this laptop, which is why a second `cg open` refuses.
	if f.Session.OK {
		age := ""
		if d, known := f.Session.V.Age(v.Now); known {
			age = ", " + format.Duration(int64(d.Seconds()))
		}
		fmt.Fprintf(b, "  streaming       yes - cg open is running here (pid %d%s)\n", f.Session.V.PID, age)
	}
	fmt.Fprintf(b, "  volumes         %s GB total\n", num(f.Volumes))
	fmt.Fprintf(b, "  snapshots       %s\n", inum(f.Snapshots))
	fmt.Fprintf(b, "  saved images    %s\n", inum(f.Images))
	eip := ""
	if f.EIPs.OK && f.EIPs.V != 0 {
		eip = "   <- in this region, not made by cg; they bill while idle"
	}
	fmt.Fprintf(b, "  elastic ips     %s%s\n", inum(f.EIPs), eip)
	fmt.Fprintf(b, "  key pair        %s\n", orQ(f.KeyPair))
	fmt.Fprintf(b, "  security group  %s\n", orQ(f.SecGroup))

	if f.Legacy.OK && f.Legacy.V != nil {
		cost := "?"
		if v.Rates.EBSGBMonth != nil {
			cost = fmt.Sprintf("%.2f", f.Legacy.V.GB**v.Rates.EBSGBMonth)
		}
		fmt.Fprintf(b, "  old EBS volume  %s  %.0f GB in %s  (~$%s/mo, LEGACY - cg games --volume --delete)\n",
			f.Legacy.V.ID, f.Legacy.V.GB, f.Legacy.V.AZ, cost)
		return
	}
	a := f.Archive
	switch {
	case a.Bucket == "":
		b.WriteString("  game library    not set up yet - cg init creates it\n")
	case a.Err != "":
		// Unknown, not empty. The difference is 160 GB of games.
		fmt.Fprintf(b, "  game library    s3://%s  UNREADABLE - %s\n", a.Bucket, a.Err)
		b.WriteString("                  this says nothing about what is in it\n")
	case a.Objects == 0:
		fmt.Fprintf(b, "  game library    s3://%s  EMPTY - no games archived\n", a.Bucket)
	default:
		usd := ""
		if v.Rates.S3GBMonth != nil {
			usd = fmt.Sprintf("  ($%.2f/mo)", float64(a.Bytes)/1073741824**v.Rates.S3GBMonth)
		}
		fmt.Fprintf(b, "  game library    s3://%s  %d objects, %s%s\n", a.Bucket, a.Objects, format.IEC(a.Bytes), usd)
	}
	if a.Bucket != "" {
		switch {
		case !a.Login.Present.OK:
			// Unknown is its own answer. Saying "none" because the listing
			// failed is the lie this file keeps having to unlearn.
			b.WriteString("  steam login     unknown - the archive could not be listed\n")
		case a.Login.Present.V:
			size := ""
			if a.Login.Bytes > 0 {
				size = ", " + format.IEC(a.Login.Bytes)
			}
			fmt.Fprintf(b, "  steam login     archived%s - a new box comes up signed in  (cg library account)\n", size)
			if a.Login.Pushed != "" {
				fmt.Fprintf(b, "                  pushed %s\n", a.Login.Pushed)
			}
		default:
			b.WriteString("  steam login     none archived - a new box will ask you to sign in\n")
		}
	}
	// Status used to show no IAM at all, and that is how a live access key
	// survived `cg destroy --all` unnoticed: anything that can act on the
	// account, or cost money, belongs in a status view.
	role := func(k Known[bool], label, name, what string) {
		switch {
		case !k.OK:
			fmt.Fprintf(b, "  %s ? (AWS could not be asked)\n", label)
		case k.V:
			fmt.Fprintf(b, "  %s %s  (%s)\n", label, name, what)
		default:
			fmt.Fprintf(b, "  %s none - cg init creates it\n", label)
		}
	}
	role(f.RoleBox, "instance role  ", v.Host+"-box", "lets the box read/write its library bucket")
	role(f.RoleWatchdog, "watchdog role  ", v.Host+"-cloud-watchdog", "the cloud watchdog: ends only the "+v.Host+" box")
	if s := f.Stranded; s != nil {
		fmt.Fprintf(b, "  STRANDED       this stopped spot box can never start again (request: %s)\n", s.Request)
		g := float64(s.GB)
		switch {
		case v.Rates.EBSGBMonth == nil:
			fmt.Fprintf(b, "                 its %d GB root volume still bills, every month\n", s.GB)
		case v.Rates.INRPerUSD == nil:
			fmt.Fprintf(b, "                 its %d GB root volume still bills $%.2f/mo\n", s.GB, g**v.Rates.EBSGBMonth)
		default:
			fmt.Fprintf(b, "                 its %d GB root volume still bills $%.2f/mo (INR %.0f)\n", s.GB, g**v.Rates.EBSGBMonth, g**v.Rates.EBSGBMonth**v.Rates.INRPerUSD)
		}
		b.WriteString("                 reclaim it: cg destroy\n")
	}
}

func orQ(k Known[string]) string {
	if !k.OK {
		return "?"
	}
	return k.V
}
