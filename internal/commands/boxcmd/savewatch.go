package boxcmd

import (
	"context"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// A save to Saved games is one long `ayis-library push` that prints a line per game
// and nothing in between, so a screen could only show a spinner. The bar is drawn
// from the OUTSIDE, which also works on a machine built before this existed: a
// second ssh asks how big each game is on the machine, once, and then, every few
// seconds, how much of it is in the archive. Whatever the archive already held
// counts as saved, so a game that barely changed starts near full.

const saveEvery = 5 * time.Second

// saveSizesScript prints "A <appid> <installdir> <bytes>" for each game on the machine.
//
// Every Steam library on the machine, found as ayis-library's push finds them: the
// archive's own, the games disk, every folder Steam lists (Add Drive makes its own
// /scratch2/SteamLibrary) and Steam's default folder on the root disk. Looking in
// the first two only, the bar said "No games to save" over a save of a game Steam
// had put somewhere else.
const saveSizesScript = `
libs=$( { echo /scratch/steam; echo /scratch2/steam
          for v in /home/*/.local/share/Steam/config/libraryfolders.vdf; do
            [ -f "$v" ] && sed -n "s/.*\"path\"[[:space:]]*\"\(.*\)\".*/\1/p" "$v"
          done
          for r in /home/*/.local/share/Steam; do [ -d "$r" ] && echo "$r"; done
        } | while read -r p; do p=$(readlink -f "$p" 2>/dev/null) && [ -d "$p/steamapps" ] && echo "$p"; done | awk '!s[$0]++' )
for L in $libs; do
  for f in "$L"/steamapps/appmanifest_*.acf; do
    [ -f "$f" ] || continue
    id=$(basename "$f" .acf); id=${id#appmanifest_}
    d=$(sed -n 's/.*"installdir"[[:space:]]*"\(.*\)".*/\1/p' "$f" | head -1)
    n=$(du -sb --exclude=downloading --exclude=temp "$L/steamapps/common/$d" "$L/steamapps/compatdata/$id" "$L/steamapps/shadercache/$id" 2>/dev/null | awk '{t+=$1} END{print t+0}')
    echo "A $id $d $n"
  done
done`

type saveGame struct{ id, dir string }

// parseSaveSizes reads saveSizesScript's output.
func parseSaveSizes(out string) (games []saveGame, total int64) {
	for _, l := range strings.Split(out, "\n") {
		f := strings.SplitN(strings.TrimSpace(l), " ", 4)
		if len(f) != 4 || f[0] != "A" {
			continue
		}
		// The size is the last field; the folder name may hold spaces.
		rest := strings.TrimSpace(f[2] + " " + f[3])
		i := strings.LastIndex(rest, " ")
		if i < 0 {
			continue
		}
		n, err := strconv.ParseInt(rest[i+1:], 10, 64)
		if err != nil {
			continue
		}
		games = append(games, saveGame{id: f[1], dir: rest[:i]})
		total += n
	}
	return
}

// saveSoFarScript asks the archive how many bytes it holds of these games.
func saveSoFarScript(games []saveGame) string {
	var b strings.Builder
	b.WriteString(". /etc/ayis-library.conf 2>/dev/null\n")
	b.WriteString(`S3="s3://$AYIS_S3_BUCKET/${AYIS_S3_PREFIX:-steam}/steamapps"` + "\n")
	b.WriteString(`t=0; du1() { b=$(/usr/local/bin/s5cmd du "$S3/$1/*" 2>/dev/null | awk 'NR==1{print $1}'); t=$((t+${b:-0})); }` + "\n")
	for _, g := range games {
		fmt.Fprintf(&b, "du1 %s; du1 compatdata/%s; du1 shadercache/%s\n", quote("common/"+g.dir), g.id, g.id)
	}
	b.WriteString(`echo "R $t"` + "\n")
	return b.String()
}

func parseSoFar(out string) (int64, bool) {
	for _, l := range strings.Split(out, "\n") {
		if f := strings.Fields(l); len(f) == 2 && f[0] == "R" {
			n, err := strconv.ParseInt(f[1], 10, 64)
			return n, err == nil
		}
	}
	return 0, false
}

// watchSave reports the save's progress until the returned function is called. It
// only does anything for a screen (events); a terminal has the push's own lines.
func (d Deps) watchSave(ctx context.Context) func() {
	if !d.Out.JSON {
		return func() {}
	}
	wctx, cancel := context.WithCancel(ctx)
	done := make(chan struct{})
	go func() {
		defer close(done)
		// Said at once, so the bar is there from the first second of the save and
		// not only after the machine has been measured.
		d.Out.Save("all", "Measuring what to save", 0, 0)
		out, err := d.Box.SSH(wctx, saveSizesScript, nil)
		if err != nil {
			d.Out.Save("all", "Saving (the machine could not be measured, so there is no bar)", 0, 0)
			return
		}
		games, total := parseSaveSizes(string(out))
		games, total = d.toSave(games, total, string(out))
		if total <= 0 {
			d.Out.Save("all", "No games to save - saving your Steam login", 0, 0)
			return
		}
		script := saveSoFarScript(games)
		first, done := true, false
		for wctx.Err() == nil {
			if out, err := d.Box.SSH(wctx, script, nil); err == nil {
				if got, ok := parseSoFar(string(out)); ok {
					if got > total {
						got = total
					}
					text := "Saving your games"
					// Already all there when the save began: nothing is uploaded, and
					// what runs is the check that no file is missing or changed. A full
					// bar that says "saving" for that minute looked like a hang.
					if first && got*1000 >= total*999 {
						done = true
					}
					if done {
						text = "Everything is already saved - checking that nothing is missing"
					}
					first = false
					d.Out.Save("all", text, got, total)
				}
			}
			select {
			case <-wctx.Done():
				return
			case <-time.After(saveEvery):
			}
		}
	}()
	return func() { cancel(); <-done }
}

// toSave keeps the games this save will actually copy: not the ones unticked
// (--skip), and not Steam's own tools, which ayis-library never saves. Otherwise the
// bar counted gigabytes nobody was copying.
func (d Deps) toSave(games []saveGame, _ int64, out string) ([]saveGame, int64) {
	skip := idSet(d.Skip)
	size := map[string]int64{}
	for _, l := range strings.Split(out, "\n") {
		f := strings.Fields(l)
		if len(f) >= 4 && f[0] == "A" {
			n, _ := strconv.ParseInt(f[len(f)-1], 10, 64)
			size[f[1]] = n
		}
	}
	var keep []saveGame
	var total int64
	for _, g := range games {
		if skip[g.id] || steamToolDir(g.id, g.dir) {
			continue
		}
		keep = append(keep, g)
		total += size[g.id]
	}
	return keep, total
}

// steamToolDir is ayis-library's is_steam_tool, by folder, as that script has it.
func steamToolDir(id, dir string) bool {
	switch id {
	case "228980", "1826330", "1161040":
		return true
	}
	return dir == "Proton" || strings.HasPrefix(dir, "Proton ") || strings.HasPrefix(dir, "SteamLinuxRuntime")
}
