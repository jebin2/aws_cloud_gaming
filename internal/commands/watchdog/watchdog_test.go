package watchdog

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

	fx "github.com/jebin2/aws_cloud_gaming/internal/testfixture"
	wd "github.com/jebin2/aws_cloud_gaming/internal/watchdog"
)

const (
	host    = "gamevps"
	region  = "ap-south-2"
	account = "123456789012"
)

var now = time.Date(2026, 10, 25, 12, 0, 0, 0, time.UTC)

func settings(string) wd.Settings {
	return wd.Settings{Host: host, Account: account, Bucket: "cg-library-test", IdleMinutes: 30, StuckMinutes: 60, ExpiryDays: 14,
		S3GBMonth: "0.025", INRPerUSD: "112.041"}
}

// current is a watchdog deployed exactly as this repo would make it.
func current(t *testing.T) (*fx.Scenario, *wd.Reader) {
	t.Helper()
	src, err := os.ReadFile("../../../lambda/cloud_watchdog.py")
	if err != nil {
		t.Fatal(err)
	}
	_, sha := wd.Zip(src)
	role := "arn:aws:iam::" + account + ":role/" + wd.Name(host)
	fn := "arn:aws:lambda:" + region + ":" + account + ":function:" + wd.Name(host)
	pol, _ := json.Marshal(settings("").Policy(region))
	s := &fx.Scenario{
		LogEvents: []fx.LogEvent{
			{At: now.Add(-20 * time.Minute), Msg: "cg-watchdog: box i-1 idle 4m"},
			{At: now.Add(-6 * time.Minute), Msg: "cg-watchdog: archive: kept - last used 16h ago; deleted in 6d 7h unless a box is launched"},
			{At: now.Add(-5 * time.Minute), Msg: "cg-watchdog: no box"},
		},
		WD: fx.WatchdogState{Installed: true, CodeSHA: sha, State: "Active", Update: "Successful", Runtime: "python3.13", Role: role,
			Description: "cloud_gaming layer 3 idle watchdog cfg=" + settings("").Fingerprint(role),
			RuleState:   "ENABLED", Schedule: "rate(5 minutes)", Target: fn, StateRuleState: "ENABLED", StateTarget: fn,
			Permission: `{"Statement":[{"Condition":{"ArnLike":{"AWS:SourceArn":"arn:aws:events:` + region + `:` + account + `:rule/` + wd.Name(host) + `"}}},` +
				`{"Condition":{"ArnLike":{"AWS:SourceArn":"arn:aws:events:` + region + `:` + account + `:rule/` + wd.StateRule(host) + `"}}}]}`,
			PolicyJSON: string(pol)},
	}
	return s, &wd.Reader{Lambda: fx.Lambda{S: s}, Events: fx.Events{S: s}, IAM: fx.RolePolicies{S: s}, Logs: fx.Logs{S: s},
		Now: func() time.Time { return now }, Host: host, Region: region, Source: src, Settings: settings}
}

func TestADeploymentMadeByThisRepoIsCurrent(t *testing.T) {
	_, r := current(t)
	st := r.Current(context.Background())
	if len(st.Drift) != 0 {
		t.Fatalf("drift: %v", st.Drift)
	}
	if st.LastMsg != "no box" || st.ArchiveMsg == "" {
		t.Errorf("last %q archive %q", st.LastMsg, st.ArchiveMsg)
	}
}

func TestEachPieceThatDriftsIsNamed(t *testing.T) {
	for name, c := range map[string]struct {
		change func(*fx.WatchdogState)
		want   string
	}{
		"code":         {func(w *fx.WatchdogState) { w.CodeSHA = "other" }, "code changed"},
		"settings":     {func(w *fx.WatchdogState) { w.Description = "cfg=000000000000" }, "settings changed"},
		"state":        {func(w *fx.WatchdogState) { w.Update = "InProgress" }, "function Active/InProgress"},
		"schedule":     {func(w *fx.WatchdogState) { w.RuleState = "DISABLED" }, "schedule not enabled"},
		"target":       {func(w *fx.WatchdogState) { w.Target = "" }, "schedule has no target"},
		"permission":   {func(w *fx.WatchdogState) { w.Permission = "{}" }, "schedule cannot invoke it"},
		"state rule":   {func(w *fx.WatchdogState) { w.StateRuleState = "DISABLED" }, "state-change rule not enabled"},
		"state target": {func(w *fx.WatchdogState) { w.StateTarget = "" }, "state-change rule has no target"},
		"policy":       {func(w *fx.WatchdogState) { w.PolicyJSON = `{"Version":"2012-10-17","Statement":[]}` }, "role policy changed"},
		"log group":    {func(w *fx.WatchdogState) { w.NoLogGroup = true }, "no log group"},
	} {
		s, r := current(t)
		c.change(&s.WD)
		st := r.Current(context.Background())
		if !strings.Contains(strings.Join(st.Drift, ", "), c.want) {
			t.Errorf("%s: drift %v lacks %q", name, st.Drift, c.want)
		}
	}
}

// The closing quote on the ARN matters: the schedule's ARN is a prefix of the
// state-change rule's, and without it one permission passed for both.
func TestOnePermissionDoesNotPassForBoth(t *testing.T) {
	s, r := current(t)
	s.WD.Permission = `{"x":"arn:aws:events:` + region + `:` + account + `:rule/` + wd.StateRule(host) + `"}`
	if d := strings.Join(r.Current(context.Background()).Drift, ", "); !strings.Contains(d, "schedule cannot invoke it") {
		t.Errorf("the state rule's permission was taken for the schedule's: %v", d)
	}
}

func TestNotInstalled(t *testing.T) {
	s, r := current(t)
	s.WD = fx.WatchdogState{NoLogGroup: true}
	st := r.Current(context.Background())
	if st.Installed || len(st.Drift) != 1 || st.Drift[0] != "no function" {
		t.Errorf("%+v", st)
	}
	out := Status(context.Background(), r, 14)
	for _, want := range []string{"function  not installed - cg init creates it", "schedule  none"} {
		if !strings.Contains(out, want) {
			t.Errorf("lacks %q:\n%s", want, out)
		}
	}
}

func TestAnUnreadableLogIsNotAnEmptyOne(t *testing.T) {
	s, r := current(t)
	s.Fail = map[string]bool{"FilterLogEvents": true}
	st := r.Current(context.Background())
	if !st.LogUnknown || !strings.Contains(strings.Join(st.Drift, ","), "log unreadable") {
		t.Errorf("%+v", st)
	}
	out := Status(context.Background(), r, 14)
	if !strings.Contains(out, "(the log could not be read)") || strings.Contains(out, "none in the last hour") {
		t.Errorf("an unreadable log read as quiet:\n%s", out)
	}
}

func TestStatusText(t *testing.T) {
	_, r := current(t)
	out := Status(context.Background(), r, 14)
	for _, want := range []string{
		"  function  gamevps-cloud-watchdog  Active python3.13\n",
		"  schedule  every 5 minutes, ENABLED\n",
		"  can end   only the instance tagged gamevps\n",
		"  archive   kept - last used 16h ago; deleted in 6d 7h unless a box is launched  (checked 6 min ago)\n",
		"  recent decisions:\n",
		" no box\n",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("lacks %q:\n%s", want, out)
		}
	}
	if got := ArchiveText(wd.State{}, 0, now); got != "kept forever (GAME_ARCHIVE_EXPIRY_DAYS=0)" {
		t.Errorf("off: %q", got)
	}
	if got := ArchiveText(wd.State{}, 14, now); got != "deleted after 14 days with no box - not checked yet (hourly)" {
		t.Errorf("never: %q", got)
	}
}

func TestWatcherRows(t *testing.T) {
	s, r := current(t)
	rows := WatcherLines(context.Background(), r)
	if rows[0] != [2]string{"ok", "cloud watchdog    ENABLED  (Lambda gamevps-cloud-watchdog, every 5 min)"} {
		t.Errorf("%v", rows[0])
	}
	if rows[1][1] != "  last            5 min ago: no box" {
		t.Errorf("%v", rows[1])
	}
	s.LogEvents = nil
	rows = WatcherLines(context.Background(), r)
	if rows[1] != [2]string{"warn", "  ^ nothing logged in the last hour, but it runs every 5 min"} {
		t.Errorf("%v", rows)
	}
	s.LogEvents = []fx.LogEvent{{At: now.Add(-time.Minute), Msg: "cg-watchdog: CANNOT QUERY AWS"}}
	rows = WatcherLines(context.Background(), r)
	if len(rows) != 3 || rows[2][0] != "fail" {
		t.Errorf("%v", rows)
	}
	s.WD.Installed, s.WD.RuleState = false, ""
	if rows = WatcherLines(context.Background(), r); rows[0][0] != "warn" || !strings.Contains(rows[0][1], "not installed") {
		t.Errorf("%v", rows[0])
	}
}

// CloudWatch Logs hands the message back with its newline.
func TestLogLinesCarryNoNewline(t *testing.T) {
	s, r := current(t)
	s.LogEvents = []fx.LogEvent{{At: now.Add(-6 * time.Minute), Msg: "cg-watchdog: archive: kept - fine\n"}, {At: now.Add(-5 * time.Minute), Msg: "cg-watchdog: no box\n"}}
	out := Status(context.Background(), r, 14)
	if strings.Contains(out, "\n\n") || !strings.Contains(out, "kept - fine  (checked 6 min ago)\n") {
		t.Errorf("%q", out)
	}
}
