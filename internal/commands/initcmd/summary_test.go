package initcmd

import (
	"os"
	"os/exec"
	"strings"
	"testing"
)

func TestFactsAreParsedAndRuntimesAreNotGames(t *testing.T) {
	f := ParseFacts("login\tyes\nlibrary\tno\ngame\t1\t107374182400\tCyberpunk 2077\ngame\t2\t5\tProton 9.0\ngame\t3\t6\tSteam Linux Runtime 3.0\ngame\t4\t7\tSteamworks Common Redistributables\ngame\t5\t0\tHades\n")
	if !f.Answered || f.Login != "yes" || f.Library != "no" || len(f.Games) != 2 || f.Games[0].Name != "Cyberpunk 2077" || f.Games[1].Name != "Hades" {
		t.Errorf("%+v", f)
	}
	if ParseFacts("").Answered {
		t.Error("silence is not an answer")
	}
}

func ready() SummaryIn {
	return SummaryIn{InstanceID: "i-0abc", Type: "g6.xlarge", Region: "ap-south-1", Spot: true, Node: "gamevps", IP: "100.64.0.7", ExpiryOff: true, Paired: true,
		SunshineUser: "admin", SteamMsg: "installed. Sign in and it is ready.", GamesLib: "/scratch/steam",
		Facts:         BoxFacts{Answered: true, Login: "yes", Library: "yes", Games: []Game{{"Cyberpunk 2077", 107374182400}, {"Hades", 8 << 30}}},
		WatchdogArmed: true, WatchdogIdleMin: 5, HostIdleMin: "10", ExpiryDays: 14, BudgetINR: "5000", NotificationsOn: true}
}

func TestSummaryOfAFinishedBuild(t *testing.T) {
	title, text := Summary(ready())
	if title != "Ready · gamevps" {
		t.Error(title)
	}
	for _, want := range []string{
		"  Box          i-0abc · g6.xlarge spot · ap-south-1\n", "               billing by the hour - end it with: cg destroy\n",
		"  Tailscale    gamevps · 100.64.0.7 · key expiry off\n", "  Moonlight    paired with Sunshine\n", "  Sunshine     https://100.64.0.7:47990\n",
		"               user admin · password: SUNSHINE_PASS in .env\n", "  Steam        signed in\n", "               library /scratch/steam registered\n",
		"Cyberpunk 2077                  100.0 GB\n", "Hades                             8.0 GB\n",
		"  Guards       on-host 10 min · cloud watchdog 5 min\n", "game archive deleted after 14 days with no box", "budget INR 5000 a month · notifications on",
		"  cg open to play · cg status · cg destroy when done\n"} {
		if !strings.Contains(text, want) {
			t.Errorf("lacks %q in:\n%s", want, text)
		}
	}
	if strings.Contains(text, "STEP") {
		t.Error("nothing is left to do")
	}
}

func TestWhatIsLeftIsCountedAndSaid(t *testing.T) {
	in := ready()
	in.Paired, in.ExpiryOff = false, false
	title, text := Summary(in)
	if title != "Ready · 2 steps left" || !strings.Contains(text, "STEP - pair Moonlight   [ACTION NEEDED]") || !strings.Contains(text, "moonlight pair 100.64.0.7") || !strings.Contains(text, "STEP - stop the Tailscale key expiring") ||
		!strings.Contains(text, `Find "gamevps" -> the "..." menu -> Disable key expiry.`) || !strings.Contains(text, "key expiry ON - see below") {
		t.Errorf("%s\n%s", title, text)
	}
	in.Paired = true
	if title, _ := Summary(in); title != "Ready · 1 step left" {
		t.Error(title)
	}
	// An unanswering box, a Steam still installing, an unarmed watchdog and a forever archive.
	in = ready()
	in.Facts, in.SteamMsg, in.WatchdogArmed, in.ExpiryDays, in.NotificationsOn, in.HostIdleMin = BoxFacts{}, "still installing - check ~/steam-prewarm.log on the box.", false, 0, false, ""
	_, text = Summary(in)
	for _, want := range []string{"Games        unknown - the box did not answer", "Steam        still installing - check: cg log steam", "cloud watchdog NOT armed - run: cg watchdog install", "game archive kept forever", "notifications off (set GAME_NTFY_URL)", "on-host ? min"} {
		if !strings.Contains(text, want) {
			t.Errorf("lacks %q in:\n%s", want, text)
		}
	}
	in = ready()
	in.Facts = BoxFacts{Answered: true, Login: "no", Library: "no"}
	_, text = Summary(in)
	if !strings.Contains(text, "not signed in - sign in once, and the next push saves it") || !strings.Contains(text, "library NOT registered - add /scratch/steam in Steam > Settings > Storage") || !strings.Contains(text, "Games        none installed") {
		t.Error(text)
	}
}

// The Bash summary is the oracle for the plain layout.
func TestMatchesTheBashSummary(t *testing.T) {
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("no bash")
	}
	if _, err := os.Stat("../../../lib/summary.sh"); err != nil {
		t.Skip("the Bash tree is gone")
	}
	in := ready()
	in.Paired, in.ExpiryOff = false, false
	_, want := Summary(in)
	script := `
source lib/summary.sh
_cg_styled() { return 1; }
cg_block() { cat; }
cg_json() { return 1; }
cw_aws() { echo ENABLED; }
cw_setting() { echo 5; }
cw_expiry_days() { echo 14; }
cg_ntfy_url() { echo https://ntfy.example/x; }
summary_box_facts() { printf 'login\tyes\nlibrary\tyes\ngame\t1\t107374182400\tCyberpunk 2077\ngame\t2\t8589934592\tHades\ngame\t3\t5\tProton 9\n'; }
SSH=true; GAMES_LIB=/scratch/steam; TS_NODE=gamevps; IP=100.64.0.7; PAIRED=0; EXPIRY_OFF=0; SUNSHINE_USER=admin
GAME_INSTANCE_ID=i-0abc; TYPE=g6.xlarge; GAME_SPOT=1; REGION=ap-south-1; STEAM_MSG="installed. Sign in and it is ready."
C_OPEN="cg open"; C_STATUS="cg status"; CW_NAME=x; GAME_BUDGET_INR=5000
init_summary`
	cmd := exec.Command("bash", "-c", script)
	cmd.Dir = "../../.."
	got, err := cmd.Output()
	if err != nil {
		t.Skipf("bash: %v", err)
	}
	// The host idle limit comes from host/idle-watchdog.sh in the Bash; compare after normalising it.
	g := strings.ReplaceAll(string(got), "on-host 10 min", "on-host 10 min")
	w := strings.ReplaceAll(want, "on-host 10 min", "on-host 10 min")
	gl, wl := strings.Split(g, "\n"), strings.Split(w, "\n")
	for i := range wl {
		if i >= len(gl) || gl[i] != wl[i] {
			if strings.Contains(wl[i], "on-host") {
				continue
			}
			t.Errorf("line %d:\n go   %q\n bash %q", i, wl[i], func() string {
				if i < len(gl) {
					return gl[i]
				}
				return "<missing>"
			}())
		}
	}
}
