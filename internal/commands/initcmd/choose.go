package initcmd

import (
	"context"
	"fmt"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/jebin2/aws_cloud_gaming/internal/ask"
	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/library"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
)

// Chooser asks which archived games to restore, before anything launches: the
// restore itself runs on the box at boot, started so it overlaps the build, and
// there is no terminal there. So the choice has to be made here and travel in
// user-data.
//
// Sizes come from the archive's one small index, rather than listing a few hundred
// thousand keys.
type Chooser struct {
	Lib library.Library
	Env *config.Env
	Out *output.Out
	Ask *ask.Asker
	// AvailGB is the machine's game disk less what is kept free, for the type being
	// built; nil when it could not be read, and then nothing is refused here - the
	// box enforces the real limit at boot.
	AvailGB   *float64
	ReserveGB float64
}

const gib = 1073741824.0

func (c Chooser) say(format string, a ...any) { fmt.Fprintf(c.Ask.Prompts, format, a...) }

// Choose settles GAME_APPS and remembers it in .env, so the common case next time
// is pressing Enter. On failure it keeps whatever .env already said rather than
// reaching for "all": "all" is only safe while the archive is smaller than the disk,
// and the whole reason this prompt exists is that it no longer is. A chooser that
// broke should not decide to move 158 GB.
func (c Chooser) Choose(ctx context.Context) string {
	current := c.Env.Get("GAME_APPS")
	sel, ok := c.pick(ctx, current)
	if !ok {
		sel = current
		if sel == "" {
			sel = "none"
		}
	}
	if sel == "" {
		sel = current
		if sel == "" {
			sel = "none"
		}
	}
	_ = c.Env.Set("GAME_APPS", sel)
	return sel
}

// pick is the decision; ok is false when the picker could not get an answer.
func (c Chooser) pick(ctx context.Context, current string) (string, bool) {
	bucket, known := c.Lib.Bucket, c.Lib.Bucket != ""
	if !known {
		// No bucket in .env: a new laptop before its first cg init writes one, or the
		// state a region move leaves behind. This used to answer "all" without asking,
		// so a new laptop's first build restored every archived game.
		b, ok := c.Lib.BucketName()
		if !ok {
			c.say("  could not tell which game archive to read - restoring none; cg library pull fetches games later\n")
			return "none", true
		}
		bucket = b
	}
	region := c.Lib.Region
	if loc, err := c.Lib.S3.Location(ctx, bucket); err == nil && loc != "" {
		region = loc
	}
	apps, missing, err := c.Lib.IndexAt(ctx, bucket, region)
	if missing {
		if !known {
			c.say("  no archive found at the derived name - restoring none; cg library pull fetches games later\n")
			return "none", true
		}
		return "all", true
	}
	if err != nil {
		// A missing INDEX in a bucket we were told about means nothing was archived,
		// and "all" of nothing restores nothing - harmless. A missing BUCKET is a
		// different thing entirely: we guessed the name, and a guess that found nothing
		// is not evidence of an empty archive. Answering "all" there told the box to
		// restore every game in the real archive - 163 GB onto a 229 GB disk, which is
		// the exact overflow this chooser exists to prevent.
		if strings.Contains(err.Error(), "does not exist") && !known {
			c.say("  no archive found at the derived name - restoring none; cg library pull fetches games later\n")
			return "none", true
		}
		if strings.Contains(err.Error(), "does not exist") {
			return "all", true
		}
		c.say("  could not read the game archive's index - restoring none; cg library pull fetches games later\n")
		return "none", true
	}
	// Nothing archived yet: no question worth asking.
	if len(apps) == 0 {
		return "all", true
	}
	// Not a terminal (a script, the app): honour .env and do not block. "all" is the
	// fallback only here, where a human already made a choice once and it was written
	// to .env; the interactive default is "none".
	if !c.Ask.TTY {
		if current == "" {
			return "all", true
		}
		return current, true
	}
	return c.interactive(apps)
}

func (c Chooser) gb(a library.App) float64 { return float64(a.Bytes) / gib }

// fit truncates to n columns and pads to exactly n.
func fit(s string, n int) string {
	if utf8.RuneCountInString(s) > n {
		s = string([]rune(s)[:n])
	}
	return s + strings.Repeat(" ", n-utf8.RuneCountInString(s))
}

func (c Chooser) table(apps []library.App) {
	if c.AvailGB == nil {
		c.say("\nArchive (the machine's space could not be read - it restores what fits):\n\n")
	} else {
		c.say("\nArchive (%.0f GB selectable of %.0f GB - %.0f GB reserved for Proton, shaders, headroom):\n\n", *c.AvailGB, *c.AvailGB+c.ReserveGB, c.ReserveGB)
	}
	c.say("  %-3s %-10s %-32s %9s  %s\n", "#", "APPID", "GAME", "SIZE", "ARCHIVED")
	for i, a := range apps {
		pushed := a.Pushed
		if pushed == "" {
			pushed = "?"
		}
		if len(pushed) > 16 {
			pushed = pushed[:16]
		}
		c.say("  %-3d %-10s %s %6.1f GB  %s\n", i+1, library.IDString(a.AppID), fit(a.Name, 32), c.gb(a), strings.Replace(pushed, "T", " ", 1))
	}
	c.say("\n")
}

// resolve turns numbers or appids into apps; the error names what was wrong.
func resolve(apps []library.App, text string) ([]library.App, error) {
	var out []library.App
	seen := map[string]bool{}
	for _, tok := range strings.Split(text, ",") {
		tok = strings.TrimSpace(tok)
		if tok == "" {
			continue
		}
		var hit *library.App
		if n, err := strconv.Atoi(tok); err == nil && len(tok) <= 2 && n >= 1 && n <= len(apps) {
			hit = &apps[n-1]
		} else {
			for i := range apps {
				if library.IDString(apps[i].AppID) == tok {
					hit = &apps[i]
					break
				}
			}
		}
		if hit == nil {
			return nil, fmt.Errorf("'%s' is not one of the numbers or appids above", tok)
		}
		if id := library.IDString(hit.AppID); !seen[id] {
			seen[id] = true
			out = append(out, *hit)
		}
	}
	return out, nil
}

// interactive asks until it has an answer that fits. The default is NONE,
// deliberately, and not the last selection: Enter is what people press to get past
// a prompt, and here that would start a 158 GB transfer - minutes of build time and
// an S3 bill - for a box they might have wanted empty. Restoring a game is cheap to
// ask for and annoying to undo. Nothing is lost by defaulting low: the archive is
// untouched, and `cg library pull --apps <id>` fetches it later.
func (c Chooser) interactive(apps []library.App) (string, bool) {
	const def = "none"
	c.table(apps)
	for {
		c.say("Restore which? (numbers or appids, comma separated | all | none)\nEnter = %s\n> ", def)
		line, err := c.Ask.In.ReadString('\n')
		if err != nil && line == "" {
			// No more input. Re-asking would spin forever whenever the default does not
			// fit - which is the normal state once the archive outgrows the disk. Fail
			// loudly and let the caller decide, rather than looping or guessing which
			// games to restore.
			c.say("\n  no answer (input ended) - not guessing which games to restore\n")
			return "", false
		}
		raw := strings.TrimSpace(line)
		if raw == "" {
			raw = def
		}
		low := strings.ToLower(raw)
		if low == "none" {
			c.say("  restoring nothing - the box will boot with an empty library\n\n")
			return "none", true
		}
		sel := apps
		if low != "all" {
			var err error
			if sel, err = resolve(apps, raw); err != nil {
				c.say("  %s\n\n", err)
				continue
			}
			if len(sel) == 0 {
				c.say("  nothing selected - type numbers, 'all', or 'none'\n\n")
				continue
			}
		}
		var total float64
		var names, ids []string
		for _, a := range sel {
			total += c.gb(a)
			names = append(names, a.Name)
			ids = append(ids, library.IDString(a.AppID))
		}
		if c.AvailGB != nil && total > *c.AvailGB {
			// Refuse and explain, rather than silently picking a subset: which game to
			// drop is not a decision a tool should make for you.
			c.say("  %.0f GB selected, %.0f GB available - over by %.0f GB.\n", total, *c.AvailGB, total-*c.AvailGB)
			var parts []string
			for _, a := range sel {
				parts = append(parts, fmt.Sprintf("%s %.0f GB", trunc(a.Name, 20), c.gb(a)))
			}
			c.say("   %s\n", strings.Join(parts, " + "))
			var fits []string
			for _, a := range apps {
				if c.gb(a) <= *c.AvailGB {
					fits = append(fits, fmt.Sprintf("%s (%.0f GB)", trunc(a.Name, 20), c.gb(a)))
				}
			}
			if len(fits) > 0 {
				c.say("  These fit on their own: %s\n", strings.Join(fits, ", "))
			}
			c.say("\n")
			continue
		}
		if c.AvailGB != nil {
			c.say("  %.0f GB selected, %.0f GB spare. Restoring: %s\n\n", total, *c.AvailGB-total, strings.Join(names, ", "))
		} else {
			c.say("  %.0f GB selected. Restoring: %s\n\n", total, strings.Join(names, ", "))
		}
		return strings.Join(ids, ","), true
	}
}

func trunc(s string, n int) string {
	if utf8.RuneCountInString(s) > n {
		return string([]rune(s)[:n])
	}
	return s
}
