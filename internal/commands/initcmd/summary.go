package initcmd

import (
	"fmt"
	"regexp"
	"strings"
)

// BoxFacts is what only the box knows, in one ssh round trip.
type BoxFacts struct {
	Answered bool
	Login    string // "yes" | "no" | "": a Steam login token is present
	Library  string // "yes" | "no" | "": the games library is registered with Steam
	Games    []Game
}

// Game is an installed app manifest.
type Game struct {
	Name  string
	Bytes int64
}

// FactsScript asks the box (run under bash -s with the library dir as $1).
const FactsScript = `lib=$1
if grep -q '"ConnectCache"' ~/.local/share/Steam/local.vdf 2>/dev/null; then
  printf 'login\tyes\n'; else printf 'login\tno\n'; fi
if grep -qF "$lib" ~/.steam/steam/config/libraryfolders.vdf 2>/dev/null; then
  printf 'library\tyes\n'; else printf 'library\tno\n'; fi
for m in "$lib"/steamapps/appmanifest_*.acf; do
  [ -f "$m" ] || continue
  id=$(sed -nE 's/^[[:space:]]*"appid"[[:space:]]*"([0-9]+)".*/\1/p' "$m" | head -n 1)
  size=$(sed -nE 's/^[[:space:]]*"SizeOnDisk"[[:space:]]*"([0-9]+)".*/\1/p' "$m" | head -n 1)
  name=$(sed -nE 's/^[[:space:]]*"name"[[:space:]]*"(.*)".*/\1/p' "$m" | head -n 1)
  printf 'game\t%s\t%s\t%s\n' "$id" "${size:-0}" "$name"
done`

var runtimes = regexp.MustCompile(`^(Proton|Steam Linux Runtime|Steamworks Common)`)

// ParseFacts reads the tab-separated lines. Proton and the Steam runtimes have
// manifests too; they are not games.
func ParseFacts(out string) BoxFacts {
	f := BoxFacts{Answered: strings.TrimSpace(out) != ""}
	for _, l := range strings.Split(out, "\n") {
		c := strings.Split(l, "\t")
		switch {
		case len(c) >= 2 && c[0] == "login":
			f.Login = c[1]
		case len(c) >= 2 && c[0] == "library":
			f.Library = c[1]
		case len(c) >= 4 && c[0] == "game":
			if runtimes.MatchString(c[3]) {
				continue
			}
			var n int64
			fmt.Sscan(c[2], &n)
			f.Games = append(f.Games, Game{c[3], n})
		}
	}
	return f
}

// SummaryIn is what the end of cg init reports.
type SummaryIn struct {
	InstanceID, Type, Region string
	Spot                     bool
	Node, IP                 string
	ExpiryOff, Paired        bool
	SunshineUser             string
	SteamMsg                 string
	GamesLib                 string
	Facts                    BoxFacts
	WatchdogArmed            bool
	WatchdogIdleMin          int
	HostIdleMin              string // "" when unknown
	ExpiryDays               int
	BudgetINR                string
	NotificationsOn          bool
}

func row(label, text string) string { return fmt.Sprintf("  %-12s %s\n", label, text) }
func more(text string) string       { return fmt.Sprintf("  %-12s %s\n", "", text) }
func orDefault(s, d string) string {
	if s == "" {
		return d
	}
	return s
}

// Summary is the end of cg init: what you now have, and only then what is left to
// do. It used to be a list of numbered steps, most of which said "[DONE
// automatically]". Once pairing and key expiry both happen on their own, a list of
// finished chores is noise; what is worth seeing is what the box ended up with, and
// where to look if something is off.
//
// The Sunshine PASSWORD is deliberately not printed. This output gets pasted into
// chats and issues; the password stays in .env as SUNSHINE_PASS.
func Summary(in SummaryIn) (title, text string) {
	left := 0
	if !in.Paired {
		left++
	}
	if !in.ExpiryOff {
		left++
	}
	switch left {
	case 0:
		title = "Ready · " + in.Node
	case 1:
		title = "Ready · 1 step left"
	default:
		title = fmt.Sprintf("Ready · %d steps left", left)
	}
	var b strings.Builder
	b.WriteString("\n")
	model := "on-demand"
	if in.Spot {
		model = "spot"
	}
	b.WriteString(row("Box", fmt.Sprintf("%s · %s %s · %s", orDefault(in.InstanceID, "unknown"), in.Type, model, in.Region)))
	b.WriteString(more("billing by the hour - end it with: cg destroy"))
	expiry := "ON - see below"
	if in.ExpiryOff {
		expiry = "off"
	}
	b.WriteString(row("Tailscale", fmt.Sprintf("%s · %s · key expiry %s", in.Node, in.IP, expiry)))
	b.WriteString(more("https://login.tailscale.com/admin/machines"))
	if in.Paired {
		b.WriteString(row("Moonlight", "paired with Sunshine"))
	} else {
		b.WriteString(row("Moonlight", "NOT paired - see below"))
	}
	b.WriteString(row("Sunshine", "https://"+in.IP+":47990"))
	b.WriteString(more(fmt.Sprintf("user %s · password: SUNSHINE_PASS in .env", orDefault(in.SunshineUser, "admin"))))

	var steam string
	switch {
	case strings.HasPrefix(in.SteamMsg, "still installing"):
		steam = "still installing - check: cg log steam"
	case in.Facts.Login == "yes":
		steam = "signed in"
	case in.Facts.Login == "no":
		steam = "not signed in - sign in once, and the next push saves it"
	default:
		steam = "unknown - the box did not answer"
	}
	b.WriteString(row("Steam", steam))
	switch in.Facts.Library {
	case "yes":
		b.WriteString(more("library " + in.GamesLib + " registered"))
	case "no":
		b.WriteString(more("library NOT registered - add " + in.GamesLib + " in Steam > Settings > Storage"))
	}

	switch {
	case !in.Facts.Answered:
		b.WriteString(row("Games", "unknown - the box did not answer"))
	case len(in.Facts.Games) == 0:
		b.WriteString(row("Games", "none installed"))
	default:
		for i, g := range in.Facts.Games {
			line := fmt.Sprintf("%-30s %9s", g.Name, fmt.Sprintf("%.1f GB", float64(g.Bytes)/1073741824))
			if i == 0 {
				b.WriteString(row("Games", line))
			} else {
				b.WriteString(more(line))
			}
		}
	}

	watchdog := "cloud watchdog NOT armed - run: cg watchdog install"
	if in.WatchdogArmed {
		watchdog = fmt.Sprintf("cloud watchdog %d min", in.WatchdogIdleMin)
	}
	b.WriteString(row("Guards", fmt.Sprintf("on-host %s min · %s", orDefault(in.HostIdleMin, "?"), watchdog)))
	if in.ExpiryDays == 0 {
		b.WriteString(more("game archive kept forever"))
	} else {
		b.WriteString(more(fmt.Sprintf("game archive deleted after %d days with no box", in.ExpiryDays)))
	}
	// The budget as you set it, in rupees - not turned into dollars at a rate
	// written down years ago and back again.
	notes := "off (set GAME_NTFY_URL)"
	if in.NotificationsOn {
		notes = "on"
	}
	b.WriteString(more(fmt.Sprintf("budget INR %s a month · notifications %s", orDefault(in.BudgetINR, "5000"), notes)))
	b.WriteString("\n")
	if !in.Paired {
		fmt.Fprintf(&b, "  STEP - pair Moonlight   [ACTION NEEDED]\n  ------------------------------------------------------------------\n  a) Run this. It prints a 4-digit PIN and waits:\n\n       moonlight pair %s\n\n  b) Open this, log in with SUNSHINE_USER / SUNSHINE_PASS from .env,\n     go to 'PIN', and enter that PIN. Accept the certificate warning.\n\n       https://%s:47990\n\n  c) Confirm - this should list Desktop:\n\n       moonlight list %s\n\n", in.IP, in.IP, in.IP)
	}
	if !in.ExpiryOff {
		fmt.Fprintf(&b, "  STEP - stop the Tailscale key expiring   [ACTION NEEDED]\n  ------------------------------------------------------------------\n  Tailscale keys expire after ~180 days by default. When this one does,\n  the node drops off the tailnet and cg open hangs waiting for it.\n  cg init does this itself when TAILSCALE_API_KEY is set and valid; why it\n  could not this time is under \"turning off Tailscale key expiry\" above.\n\n       https://login.tailscale.com/admin/machines\n\n  Find \"%s\" -> the \"...\" menu -> Disable key expiry.\n\n", in.Node)
	}
	b.WriteString("  cg open to play · cg status · cg destroy when done\n\n")
	return title, b.String()
}
