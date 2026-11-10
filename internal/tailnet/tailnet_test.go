package tailnet

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	fx "github.com/jebin2/ayis/internal/testfixture"
)

const before = `{"Peer":{"nodekey:a":{"DNSName":"phone.tail1.ts.net.","HostName":"Pixel","PublicKey":"nodekey:a"},
 "nodekey:b":{"DNSName":"","HostName":"old-laptop","PublicKey":"nodekey:b"}}}`

func runner(json string) *fx.Runner {
	return &fx.Runner{Installed: map[string]bool{"tailscale": true}, Answers: map[string]string{"tailscale status --json": json}}
}

func TestNodesAreKnownByKeyAndNamedFromTheirDNSOrHostname(t *testing.T) {
	ns := Nodes(context.Background(), runner(before))
	if len(ns) != 2 || ns[0].Name != "old-laptop" || ns[1].Name != "phone" || ns[1].Key != "nodekey:a" {
		t.Errorf("%+v", ns)
	}
	if Nodes(context.Background(), runner("garbage")) != nil {
		t.Error("nothing readable is no nodes")
	}
}

func TestANewBoxIsFoundByItsKeyEvenUnderAnOldName(t *testing.T) {
	// The prune freed the name "ayis", and the new box took it: a list of names would never show it.
	snap := Keys(Nodes(context.Background(), runner(`{"Peer":{"nodekey:z":{"DNSName":"ayis.t.ts.net.","PublicKey":"nodekey:z"}}}`)))
	now := Nodes(context.Background(), runner(`{"Peer":{"nodekey:z":{"DNSName":"ayis.t.ts.net.","PublicKey":"nodekey:z"},
	  "nodekey:y":{"DNSName":"ayis.t.ts.net.","PublicKey":"nodekey:y"}}}`))
	if got := New(now, snap, "ayis"); got != "ayis" {
		t.Errorf("%q", got)
	}
	// A phone that joins meanwhile is not the box; a suffixed name is.
	now = Nodes(context.Background(), runner(`{"Peer":{"nodekey:p":{"DNSName":"newphone.t.ts.net.","PublicKey":"nodekey:p"},"nodekey:q":{"DNSName":"ayis-2.t.ts.net.","PublicKey":"nodekey:q"},"nodekey:r":{"DNSName":"ayisx.t.ts.net.","PublicKey":"nodekey:r"}}}`))
	if got := New(now, map[string]bool{}, "ayis"); got != "ayis-2" {
		t.Errorf("%q", got)
	}
}

func TestWaitLogsAndTimesOut(t *testing.T) {
	r := runner(`{"Peer":{}}`)
	var logs []string
	var slept time.Duration
	_, ok := Wait(context.Background(), r, map[string]bool{}, "ayis", 3*time.Minute, func(d time.Duration) { slept += d }, func(s string) { logs = append(logs, s) })
	if ok || slept != 3*time.Minute || logs[len(logs)-1] != "TIMEOUT after 3m - no new node joined the tailnet" || !strings.Contains(strings.Join(logs, "|"), "still waiting for the box to join (60s)") {
		t.Errorf("%v %v", slept, logs)
	}
	r = runner(`{"Peer":{"nodekey:n":{"DNSName":"ayis.t.ts.net.","PublicKey":"nodekey:n"}}}`)
	logs = nil
	if name, ok := Wait(context.Background(), r, map[string]bool{}, "ayis", time.Minute, func(time.Duration) {}, func(s string) { logs = append(logs, s) }); !ok || name != "ayis" || logs[0] != "joined as 'ayis' after 0s" {
		t.Errorf("%v %v", name, logs)
	}
}

func TestNamesAndOffline(t *testing.T) {
	r := &fx.Runner{Installed: map[string]bool{"tailscale": true}, Answers: map[string]string{"tailscale status": "100.64.0.1   ayis    me@   linux   offline, last seen 3d ago\n100.64.0.2   phone   me@   android   -\nhealth: x\n"}}
	if n := Names(context.Background(), r); strings.Join(n, ",") != "ayis,phone" {
		t.Errorf("%v", n)
	}
	if !Offline(context.Background(), r, "ayis") || Offline(context.Background(), r, "phone") {
		t.Error("offline is read from the status line")
	}
}

func TestWaitBeatReportsEachPollAndStopsOnInterrupt(t *testing.T) {
	var beats []string
	beat := func(id, state, text string, secs, of int) {
		beats = append(beats, fmt.Sprintf("%s %s %d/%d", id, state, secs, of))
	}
	_, ok := WaitBeat(context.Background(), runner(`{"Peer":{}}`), map[string]bool{}, "ayis", 30*time.Second, func(time.Duration) {}, func(string) {}, beat)
	if ok || strings.Join(beats, "|") != "init.tailnet waiting 0/30|init.tailnet waiting 10/30|init.tailnet waiting 20/30|init.tailnet timeout 30/30" {
		t.Errorf("%v", beats)
	}
	// Ctrl-C ends it at once; it used to wait out the half hour.
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	beats = nil
	slept := time.Duration(0)
	if _, ok := WaitBeat(ctx, runner(`{"Peer":{}}`), map[string]bool{}, "ayis", 30*time.Minute, func(d time.Duration) { slept += d }, func(string) {}, beat); ok || slept != 0 || strings.Join(beats, "|") != "init.tailnet interrupted 0/1800" {
		t.Errorf("%v %v", slept, beats)
	}
}
