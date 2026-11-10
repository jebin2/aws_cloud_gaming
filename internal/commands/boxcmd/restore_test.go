package boxcmd

import (
	"context"
	"strings"
	"testing"
)

func TestParseGames(t *testing.T) {
	ws, err := parseGames("1:100,2,1:100,3:5")
	if err != nil || len(ws) != 3 || ws[0] != (want{"1", 100}) || ws[1] != (want{"2", 0}) || ws[2] != (want{"3", 5}) {
		t.Fatalf("got %v %v", ws, err)
	}
	if ws, err := parseGames(""); err != nil || len(ws) != 0 {
		t.Fatalf("empty: %v %v", ws, err)
	}
	for _, bad := range []string{"a", "1;rm -rf /", "1:x", "1:2:3"} {
		if _, err := parseGames(bad); err == nil {
			t.Errorf("%q should be refused: it ends up in a shell line", bad)
		}
	}
}

func TestProbeScriptPicksTheRightLibrary(t *testing.T) {
	s := probeScript([]want{{"10", 1}, {"20", 1}}, map[string]bool{"20": true}, "u1")
	if !strings.Contains(s, `g 10 "$L"`) || !strings.Contains(s, `g 20 "$X"`) {
		t.Fatalf("script:\n%s", s)
	}
	if !strings.Contains(s, "systemctl show -p ActiveState --value u1") {
		t.Fatalf("unit not asked: %s", s)
	}
}

func TestParseProbe(t *testing.T) {
	got, a, b := parseProbe("G 10 500\nG 20 0\nU active running\n")
	if got["10"] != 500 || got["20"] != 0 || a != "active" || b != "running" {
		t.Fatalf("%v %s %s", got, a, b)
	}
}

func TestJudge(t *testing.T) {
	ws := []want{{"1", 1000}, {"2", 1000}, {"3", 0}}
	state := func(rows []gameRow) string {
		var s []string
		for _, r := range rows {
			s = append(s, r.State)
		}
		return strings.Join(s, " ")
	}
	// Mid-copy: only waiting or copying, whatever the byte count says.
	rows, end := judge(ws, map[string]int64{"1": 1000, "2": 0, "3": 5}, "active", "running")
	if end || state(rows) != "copying waiting copying" {
		t.Fatalf("mid: %v %v", end, state(rows))
	}
	// Ended clean: whole games are done, an empty one failed, an unsized one done once it has bytes.
	rows, end = judge(ws, map[string]int64{"1": 990, "2": 400, "3": 5}, "active", "exited")
	if !end || state(rows) != "done failed done" {
		t.Fatalf("clean: %v %v", end, state(rows))
	}
	// The unit failed: a game of unknown size cannot be called done.
	rows, end = judge(ws, map[string]int64{"1": 1000, "2": 1000, "3": 5}, "failed", "failed")
	if !end || state(rows) != "done done failed" {
		t.Fatalf("failed: %v %v", end, state(rows))
	}
}

// While a game is still "waiting" the copy's own last line is what tells why.
func TestTheProbeAsksForTheCopysLastLine(t *testing.T) {
	s := probeScript([]want{{ID: "1", Bytes: 5}}, nil, "ayis-restore-play-9")
	if !strings.Contains(s, "journalctl -u ayis-restore-play-9 -n 1") {
		t.Errorf("no journal in\n%s", s)
	}
	if got := parseJournal("G 1 0\nJ restoring Ori (1, 11 GB)\nU active running\n"); got != "restoring Ori (1, 11 GB)" {
		t.Errorf("journal %q", got)
	}
	if parseJournal("G 1 0\n") != "" {
		t.Error("nothing said is nothing")
	}
}

// A game already whole elsewhere on the machine is not copied again; one in the
// copy's own library is left to the copy, and a quarter of a game is not a game.
func TestWhatIsAlreadyThereIsNotCopiedAgain(t *testing.T) {
	r := newRig(t, "")
	prev := r.r.Hook
	r.r.Hook = func(line string) (bool, string, error) {
		if strings.Contains(line, "appmanifest_") && strings.Contains(line, "StateFlags") {
			return true, "H 111 root /home/ubuntu/.local/share/Steam 950\nH 222 nvme /scratch/steam 1000\nH 333 extra /scratch2/SteamLibrary 100\n", nil
		}
		return prev(line)
	}
	got := r.d.leaveOutWhatIsThere(context.Background(), []want{{"111", 1000}, {"222", 1000}, {"333", 1000}}, map[string]bool{})
	var ids []string
	for _, w := range got {
		ids = append(ids, w.ID)
	}
	if strings.Join(ids, ",") != "222,333" || !strings.Contains(r.o.String()+r.w.String(), "111 is already on the machine (the root disk") {
		t.Errorf("kept %v\n%s%s", ids, r.o, r.w)
	}
}
