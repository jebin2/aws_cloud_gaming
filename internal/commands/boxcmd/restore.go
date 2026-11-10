package boxcmd

import (
	"context"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/jebin2/ayis/internal/format"
)

// want is one game ayis open brings onto the machine: its id, and how many bytes
// Saved games holds for it (0 when not known, which turns the percentage off).
type want struct {
	ID    string
	Bytes int64
}

var gameWant = regexp.MustCompile(`^[0-9]+(:[0-9]+)?$`)

// parseGames reads "appid:bytes,appid:bytes"; a bare appid is a game of unknown size.
func parseGames(s string) ([]want, error) {
	var out []want
	seen := map[string]bool{}
	for _, f := range strings.Split(strings.TrimSpace(s), ",") {
		if f == "" {
			continue
		}
		if !gameWant.MatchString(f) {
			return nil, fmt.Errorf("those games are not a list of game ids and sizes: %s", s)
		}
		id, b, _ := strings.Cut(f, ":")
		if seen[id] {
			continue
		}
		seen[id] = true
		n, _ := strconv.ParseInt(b, 10, 64)
		out = append(out, want{ID: id, Bytes: n})
	}
	return out, nil
}

// wanted is every game this play brings: --games, or - for the form that only
// named the games going on the added disk - those.
func (d Deps) wanted() ([]want, error) {
	if strings.TrimSpace(d.Games) != "" {
		return parseGames(d.Games)
	}
	return parseGames(d.ExtraApps)
}

func idSet(csv string) map[string]bool {
	m := map[string]bool{}
	for _, f := range strings.Split(csv, ",") {
		if f = strings.TrimSpace(f); f != "" {
			m[f] = true
		}
	}
	return m
}

// probeScript prints how many bytes of each game are on the machine, then the
// state of the unit doing the copying:
//
//	G <appid> <bytes>
//	U <ActiveState> <SubState>
//
// A game's bytes are what pull itself counts: the game's folder, its Proton
// prefix and its shader cache, not what Steam is still downloading.
func probeScript(ws []want, extra map[string]bool, unit string) string {
	var b strings.Builder
	b.WriteString(". /etc/ayis-library.conf 2>/dev/null\n")
	b.WriteString("L=${AYIS_LIB_DIR:-/scratch/steam}; X=${AYIS_EXTRA_LIB:-/scratch2/steam}\n")
	b.WriteString(`g() { m="$2/steamapps/appmanifest_$1.acf"; d=""; [ -f "$m" ] && d=$(sed -n 's/.*"installdir"[[:space:]]*"\([^"]*\)".*/\1/p' "$m" | head -1)
  n=0; [ -n "$d" ] && n=$(du -sb --exclude=downloading --exclude=temp "$2/steamapps/common/$d" "$2/steamapps/compatdata/$1" "$2/steamapps/shadercache/$1" 2>/dev/null | awk '{t+=$1} END{print t+0}')
  echo "G $1 $n"; }` + "\n")
	for _, w := range ws {
		lib := "$L"
		if extra[w.ID] {
			lib = "$X"
		}
		fmt.Fprintf(&b, "g %s \"%s\"\n", w.ID, lib)
	}
	fmt.Fprintf(&b, "echo \"U $(systemctl show -p ActiveState --value %s) $(systemctl show -p SubState --value %s)\"\n", unit, unit)
	// What the copy last said, for a screen to show while a game is still "waiting".
	fmt.Fprintf(&b, "echo \"J $(sudo -n journalctl -u %s -n 1 -o cat --no-pager 2>/dev/null | head -c 200 | tr -d '\\n')\"\n", unit)
	return b.String()
}

// parseJournal is the copy's last line of its own, from probeScript's output.
func parseJournal(out string) string {
	for _, l := range strings.Split(out, "\n") {
		if rest, ok := strings.CutPrefix(l, "J "); ok {
			return strings.TrimSpace(rest)
		}
	}
	return ""
}

// parseProbe reads probeScript's output.
func parseProbe(out string) (got map[string]int64, active, sub string) {
	got = map[string]int64{}
	for _, l := range strings.Split(out, "\n") {
		f := strings.Fields(l)
		switch {
		case len(f) == 3 && f[0] == "G":
			n, _ := strconv.ParseInt(f[2], 10, 64)
			got[f[1]] = n
		case len(f) >= 2 && f[0] == "U":
			active = f[1]
			if len(f) > 2 {
				sub = f[2]
			}
		}
	}
	return got, active, sub
}

// gameRow is one game's line in the progress.
type gameRow struct {
	ID    string
	State string // waiting, copying, done, failed
	Got   int64
	Of    int64
}

// finished: the unit that copies has ended, one way or the other.
func finished(active, sub string) bool {
	return active == "failed" || active == "inactive" || sub == "exited" || sub == "dead"
}

// whole is the same test pull applies: 98% of what was archived is there.
func whole(got, of int64) bool { return of <= 0 || got*100 >= of*98 }

// judge turns one probe into every game's row. Until the copy ends a game is only
// waiting or copying; a game is called done or failed once it has - a "done" read
// from the byte count alone would say so over a game whose last files had not
// landed.
func judge(ws []want, got map[string]int64, active, sub string) (rows []gameRow, end bool) {
	end = finished(active, sub)
	for _, w := range ws {
		g := got[w.ID]
		r := gameRow{ID: w.ID, Got: g, Of: w.Bytes}
		switch {
		case end && whole(g, w.Bytes) && (w.Bytes > 0 || (active != "failed" && g > 0)):
			r.State = "done"
		case end:
			r.State = "failed"
		case g > 0:
			r.State = "copying"
		default:
			r.State = "waiting"
		}
		rows = append(rows, r)
	}
	return rows, end
}

// restoreGames brings the wanted games onto the machine and waits for them,
// saying how far each one is. A game restores whole or not at all; one that does
// not make it is named, and the machine is left running for another try.
func (d Deps) restoreGames(ctx context.Context) int {
	ws, err := d.wanted()
	if err != nil {
		return d.die(err.Error())
	}
	if len(ws) == 0 {
		return 0
	}
	extra := idSet(d.ExtraApps)
	// A game already installed somewhere else on the machine - the root disk, the
	// games disk, a library Steam made itself - is not copied again: that made a
	// second whole copy that Steam then saw twice. Both disks outlive a stop, so a
	// game "to bring back" can be there all along.
	ws = d.leaveOutWhatIsThere(ctx, ws, extra)
	if len(ws) == 0 {
		return 0
	}
	var ids []string
	for _, w := range ws {
		ids = append(ids, w.ID)
	}
	csv := strings.Join(ids, ",")
	d.Out.SayID("open.restore", "Copying your games from Saved games")
	unit := "ayis-restore-play-" + strconv.FormatInt(d.Now().Unix(), 10)
	cmd := "set -a; . /etc/ayis-library.conf; set +a; export AYIS_EXTRA_APPS=" + d.ExtraApps +
		"; exec /usr/local/bin/ayis-library pull --apps " + csv
	run := remote("sudo", "systemd-run", "--quiet", "--remain-after-exit", "--unit="+unit,
		"--uid=ubuntu", "--gid=ubuntu", "/bin/bash", "-c", cmd)
	if err := d.relay(ctx, run); err != nil {
		d.said(err)
		return d.die("could not start bringing the games back. Run it again to retry")
	}
	for _, w := range ws {
		d.Out.Restore(w.ID, "waiting", 0, w.Bytes)
	}
	script := probeScript(ws, extra, unit)
	bad, last, lastJ := 0, map[string]string{}, ""
	for {
		if ctx.Err() != nil {
			return 1
		}
		out, err := d.Box.SSH(ctx, script, nil)
		if err != nil {
			// The machine can be busy or the link can blink; a long run of misses is not.
			if bad++; bad > 15 {
				return d.die("lost touch with the machine while the games were being copied")
			}
			d.sleep(4 * time.Second)
			continue
		}
		bad = 0
		if j := parseJournal(string(out)); j != "" && j != lastJ {
			d.Out.Log("  copy says: " + j)
			lastJ = j
		}
		got, active, sub := parseProbe(string(out))
		rows, end := judge(ws, got, active, sub)
		failed := 0
		for _, r := range rows {
			d.Out.Restore(r.ID, r.State, r.Got, r.Of)
			if r.State == "failed" {
				failed++
			}
			line := fmt.Sprintf("  %s: %s", r.ID, r.State)
			if r.Of > 0 {
				line = fmt.Sprintf("  %s: %s, %s of %s", r.ID, r.State, format.IEC(r.Got), format.IEC(r.Of))
			}
			if last[r.ID] != r.State {
				d.Out.Echo(line)
				last[r.ID] = r.State
			}
		}
		if end {
			if failed > 0 {
				return d.die(fmt.Sprintf("%d of %d game(s) did not come back whole - most often the disk had no room. Nothing was removed; the machine is still running", failed, len(rows)))
			}
			d.Out.Echo("the games are back")
			return 0
		}
		d.sleep(4 * time.Second)
	}
}

// thereScript prints "H <appid> <where> <path> <bytes>" for every game Steam has
// fully installed (StateFlags 4) in any library on the machine.
const thereScript = `
libs=$( { echo /scratch/steam; echo /scratch2/steam
          for v in /home/*/.local/share/Steam/config/libraryfolders.vdf; do
            [ -f "$v" ] && sed -n "s/.*\"path\"[[:space:]]*\"\(.*\)\".*/\1/p" "$v"
          done
          for r in /home/*/.local/share/Steam; do [ -d "$r" ] && echo "$r"; done
        } | while read -r p; do p=$(readlink -f "$p" 2>/dev/null) && [ -d "$p/steamapps" ] && echo "$p"; done | awk '!s[$0]++' )
for L in $libs; do
  t=$(df --output=target "$L" 2>/dev/null | tail -1 | tr -d " ")
  case "$t" in /scratch) w=nvme ;; /scratch2) w=extra ;; *) w=root ;; esac
  for f in "$L"/steamapps/appmanifest_*.acf; do
    [ -f "$f" ] || continue
    id=$(basename "$f" .acf); id=${id#appmanifest_}
    fl=$(sed -n 's/.*"StateFlags"[[:space:]]*"\([0-9]*\)".*/\1/p' "$f" | head -1)
    [ $(( ${fl:-0} & 4 )) -ne 0 ] || continue
    d=$(sed -n 's/.*"installdir"[[:space:]]*"\(.*\)".*/\1/p' "$f" | head -1)
    n=$(du -sb --exclude=downloading --exclude=temp "$L/steamapps/common/$d" 2>/dev/null | cut -f1)
    echo "H $id $w $L ${n:-0}"
  done
done`

// leaveOutWhatIsThere drops the games the machine already has whole in a library
// other than the one the copy would put them in, and says so. The copy's own
// library is left to the copy: it finishes what is there and skips what is whole.
// A machine that cannot be asked keeps the whole list - copying is the old way,
// and still correct.
func (d Deps) leaveOutWhatIsThere(ctx context.Context, ws []want, extra map[string]bool) []want {
	out, err := d.Box.SSH(ctx, thereScript, nil)
	if err != nil {
		return ws
	}
	type there struct {
		where, lib string
		bytes      int64
	}
	have := map[string][]there{}
	for _, l := range strings.Split(string(out), "\n") {
		f := strings.Fields(l)
		if len(f) < 5 || f[0] != "H" {
			continue
		}
		n, _ := strconv.ParseInt(f[len(f)-1], 10, 64)
		have[f[1]] = append(have[f[1]], there{where: f[2], lib: strings.Join(f[3:len(f)-1], " "), bytes: n})
	}
	words := map[string]string{"nvme": "the fast drive", "extra": "the games disk", "root": "the root disk"}
	var keep []want
	for _, w := range ws {
		target := "/scratch/steam"
		if extra[w.ID] {
			target = "/scratch2/steam"
		}
		found := false
		for _, h := range have[w.ID] {
			// Whole by Steam's flag, and by size against what was saved: a manifest
			// over a quarter of the files is not a game.
			if h.lib != target && (w.Bytes <= 0 || h.bytes*10 >= w.Bytes*9) {
				d.Out.Log(fmt.Sprintf("  %s is already on the machine (%s, %s) - not copied", w.ID, words[h.where], h.lib))
				d.Out.Restore(w.ID, "there", h.bytes, h.bytes)
				found = true
				break
			}
		}
		if !found {
			keep = append(keep, w)
		}
	}
	return keep
}
