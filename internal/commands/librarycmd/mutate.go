package librarycmd

import (
	"context"
	"errors"
	"fmt"
	"math"
	"os"
	"regexp"
	"strconv"
	"strings"

	"github.com/aws/aws-sdk-go-v2/service/ssm"

	"github.com/jebin2/aws_cloud_gaming/internal/ask"
	"github.com/jebin2/aws_cloud_gaming/internal/awscfg"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/configcmd"
	"github.com/jebin2/aws_cloud_gaming/internal/commands/watchdog"
	"github.com/jebin2/aws_cloud_gaming/internal/config"
	"github.com/jebin2/aws_cloud_gaming/internal/library"
	"github.com/jebin2/aws_cloud_gaming/internal/output"
)

// Changer is the archive's mutations with the questions they ask. None needs the box.
type Changer struct {
	M     library.Mutator
	Ask   *ask.Asker
	Out   *output.Out
	Env   *config.Env
	Price func(ctx context.Context, region, key string) *float64
	// Reinstall redeploys the cloud watchdog; Set saves a setting.
	Reinstall func(ctx context.Context) int
	Set       func(key, value string) error
}

// NewChanger wires it to AWS for the settings in force.
func NewChanger(ctx context.Context, r *Reader, env *config.Env, out *output.Out) (*Changer, error) {
	store, ok := r.Lib.S3.(*library.AWSStore)
	if !ok {
		return nil, errors.New("the archive is not reachable")
	}
	cfg, err := awscfg.New(ctx, env.Region())
	if err != nil {
		return nil, err
	}
	m := library.Mutator{Library: r.Lib, W: store, Marks: library.SSMMarks{Client: ssm.NewFromConfig(cfg)}}
	return &Changer{M: m, Ask: ask.New(out, os.Getenv("CG_YES") == "1"), Out: out, Env: env, Price: r.Prices,
		Reinstall: func(ctx context.Context) int { return watchdog.Reinstall(ctx, env, out) },
		Set:       func(k, v string) error { return configcmd.Set(env, k, v, out) }}, nil
}

func (c *Changer) die(text string) int {
	c.Out.Die(text)
	return 1
}

func gb(b int64) float64 { return float64(b) / 1073741824 }

// flags reads "<id> [--from <bucket>]", ignoring other flags.
func flags(args []string) (id, from string) {
	for i := 0; i < len(args); i++ {
		switch {
		case args[i] == "--from":
			if i+1 < len(args) {
				from = args[i+1]
			}
			i++
		case strings.HasPrefix(args[i], "-"):
		default:
			id = args[i]
		}
	}
	return
}

// Forget is `cg library forget <appid> [--from <bucket>]`.
func (c *Changer) Forget(ctx context.Context, args []string) int {
	id, from := flags(args)
	if id == "" {
		return c.die("which game? see: cg library list")
	}
	// The bucket in use must be named in .env to be deleted from - a derived name
	// is fine to read, not to delete in. Another bucket is checked as cg's instead.
	if from == "" && c.Env.Get("GAME_S3_BUCKET") == "" {
		return c.die("no bucket configured")
	}
	bucket, region, err := c.M.Place(ctx, from)
	if err != nil {
		return c.die(err.Error())
	}
	apps, err := c.M.IndexAt(ctx, bucket, region)
	if err != nil {
		return c.die("cannot read the archive: " + err.Error())
	}
	g, ok := library.Lookup(apps, id)
	if !ok {
		return c.die(fmt.Sprintf("appid %s is not in the archive (see: cg library list)", id))
	}
	c.Out.Echo(fmt.Sprintf("This permanently deletes %s (%s, %.1f GB) from the archive in %s.", g.Name, id, gb(g.Bytes), region))
	c.Out.Echo("No undo, no versioning. Playing it again means downloading it from Steam.")
	c.Out.Echo(fmt.Sprintf("At Steam speeds that is roughly %.1f hours.", float64(g.Bytes)/12582912/3600))
	if !c.Ask.Typed("forget-game", "type FORGET to confirm: ", "FORGET") {
		c.Out.Echo("aborted - nothing was deleted")
		return 1
	}
	c.Out.Say(fmt.Sprintf("deleting %s from %s", g.Name, region))
	switch err := c.M.ForgetAt(ctx, bucket, region, id, apps, c.Out.Log); {
	case errors.Is(err, library.ErrPartial):
		return c.die(fmt.Sprintf("only part of %s was deleted from %s - what is left still bills; run the delete again to finish it", g.Name, region))
	case errors.Is(err, library.ErrIndex):
		return c.die(fmt.Sprintf("%s was deleted from %s, but the list of saved games there could not be updated - run the delete again to tidy it", g.Name, region))
	case err != nil:
		return c.die(err.Error())
	}
	c.Out.Log(fmt.Sprintf("forgot %s (%s) - %.1f GB stops billing", g.Name, id, gb(g.Bytes)))
	return 0
}

// Reset is `cg library reset|keep <appid> [--from <bucket>]`: start a game's
// countdown again today.
func (c *Changer) Reset(ctx context.Context, args []string) int {
	id, from := flags(args)
	if !regexp.MustCompile(`^[0-9]+$`).MatchString(id) {
		return c.die("which game? see: cg library list")
	}
	bucket, _, err := c.M.Place(ctx, from)
	if err != nil {
		return c.die(err.Error())
	}
	c.Out.Say("counting it from today")
	if err := c.M.Reset(ctx, bucket, id); err != nil {
		return c.die("could not save the new date - AWS did not answer")
	}
	c.Out.Log(fmt.Sprintf("kept: %s is counted from today - %d days with no machine before it is deleted", id, c.Env.Int("GAME_ARCHIVE_EXPIRY_DAYS")))
	return 0
}

// KeepFor is `cg library keep-for <days>`: how long saved games are kept with no
// machine, applied now. The setting alone changes nothing until the cloud
// watchdog is redeployed with it, so this does both, and the date the app shows
// is the date AWS will act on.
func (c *Changer) KeepFor(ctx context.Context, args []string) int {
	d := ""
	if len(args) > 0 {
		d = args[0]
	}
	if d == "forever" || d == "never" {
		d = "0"
	}
	if !regexp.MustCompile(`^[0-9]+$`).MatchString(d) {
		return c.die("how many days? e.g. cg library keep-for 14 (0 keeps them until you forget them)")
	}
	n, _ := strconv.Atoi(d)
	d = strconv.Itoa(n)
	c.Out.Say("saving the setting")
	if err := c.Set("GAME_ARCHIVE_EXPIRY_DAYS", d); err != nil {
		return c.die(err.Error())
	}
	c.Out.Say("updating auto-stop")
	if c.Reinstall(ctx) != 0 {
		return c.die("saved, but the cloud watchdog still counts the old days - run: cg watchdog install")
	}
	if n == 0 {
		c.Out.Log("saved games are kept until you forget them")
	} else {
		c.Out.Log(fmt.Sprintf("saved games are deleted %d days after a machine was last running", n))
	}
	return 0
}

// iec is numfmt --to=iec --suffix=B: 1024 steps, rounded up, one decimal under 10.
func iec(b int64) string {
	if b < 1024 {
		return fmt.Sprintf("%dB", b)
	}
	v := float64(b)
	for _, u := range []string{"K", "M", "G", "T", "P"} {
		v /= 1024
		if v < 1024 || u == "P" {
			if v < 10 {
				return fmt.Sprintf("%.1f%sB", math.Ceil(v*10)/10, u)
			}
			return fmt.Sprintf("%.0f%sB", math.Ceil(v), u)
		}
	}
	return ""
}

// Clean is `cg library clean`: delete the objects of pushes that never finished.
func (c *Changer) Clean(ctx context.Context) int {
	if c.Env.Get("GAME_S3_BUCKET") == "" {
		return c.die("no bucket configured")
	}
	bucket, region, err := c.M.Place(ctx, "")
	if err != nil {
		return c.die(err.Error())
	}
	orphans, err := c.M.OrphansIn(ctx, bucket, region)
	if err != nil {
		// An archive that could not be read is not an archive with nothing in it.
		return c.die("cannot read the archive: " + err.Error())
	}
	if len(orphans) == 0 {
		c.Out.Echo("  no orphaned objects - everything in the archive is indexed")
		return 0
	}
	c.Out.Echo("These objects belong to no archived game - a push that never finished:")
	var total int64
	for _, o := range orphans {
		total += o.Bytes
		c.Out.Echo(fmt.Sprintf("  %10s  %s", iec(o.Bytes), o.Name))
	}
	c.Out.Gap()
	if c.M.S3USD != nil && c.M.INR != nil {
		usd := gb(total) * *c.M.S3USD
		c.Out.Echo(fmt.Sprintf("  %.1f GB, costing $%.2f/month (INR %.0f) for files no game can use", gb(total), usd, usd**c.M.INR))
	} else {
		c.Out.Echo(fmt.Sprintf("  %.1f GB, costing an amount that could not be read, for files no game can use", gb(total)))
	}
	c.Out.Echo("  They are not restorable: with no manifest, Steam cannot see them.")
	if !c.Ask.Typed("clean-orphans", "type CLEAN to delete them: ", "CLEAN") {
		c.Out.Echo("aborted - nothing was deleted")
		return 1
	}
	kept := 0
	for _, o := range orphans {
		if err := c.M.DeleteOrphan(ctx, bucket, region, o.Name); err != nil {
			c.Out.Log("could not delete " + o.Name)
			kept++
		} else {
			c.Out.Log("deleted " + o.Name)
		}
	}
	if kept > 0 {
		return c.die(fmt.Sprintf("could not delete %d of them (%d in all) - they still bill; run the clean up again", kept, len(orphans)))
	}
	c.Out.Log("storage charges for those stop now")
	return 0
}

// Move is `cg library move <appid> --from <bucket>`: bring a game left in another
// region to the one the machine is built in. Copied server to server, checked
// file for file, and only then deleted at the source. AWS bills the copy once,
// between regions; after it a build downloads the game in its own region, which
// is free.
func (c *Changer) Move(ctx context.Context, args []string) int {
	id, from := flags(args)
	if !regexp.MustCompile(`^[0-9]+$`).MatchString(id) || from == "" {
		return c.die("usage: cg library move <appid> --from <bucket>")
	}
	sb, sr, err := c.M.Place(ctx, from)
	if err != nil {
		return c.die(err.Error())
	}
	db, ok := c.M.BucketName()
	if !ok {
		return c.die("could not work out where your machine's games are kept - AWS did not answer")
	}
	if sb == db {
		return c.die("that game is already where your machine is built")
	}
	dr, err := c.M.S3.Location(ctx, db)
	if err != nil {
		return c.die("nothing is saved where your machine is built yet - build once, then move")
	}
	sidx, err := c.M.IndexAt(ctx, sb, sr)
	if err != nil {
		return c.die("cannot read the games in " + sr)
	}
	didx, err := c.M.IndexAt(ctx, db, dr)
	if err != nil {
		return c.die("cannot read the games in " + dr)
	}
	g, ok := library.Lookup(sidx, id)
	if !ok {
		return c.die(fmt.Sprintf("appid %s is not saved in %s (see: cg library elsewhere)", id, sr))
	}
	if !library.SafeDir(g.InstallDir) {
		return c.die(fmt.Sprintf("refusing to move %s: its install folder is '%s'", id, g.InstallDir))
	}
	c.Out.Echo(fmt.Sprintf("This copies %s (%.1f GB) from %s to %s, checks every file, then deletes it from %s.", g.Name, gb(g.Bytes), sr, dr, sr))
	// Billed where the bytes leave, at that region's price - and not at all
	// inside one region, where a copy pays only its requests.
	switch {
	case sr == dr:
		c.Out.Echo(fmt.Sprintf("Both are in %s, so there is no transfer charge - only a few rupees of requests.", dr))
	default:
		if p := c.Price(ctx, sr, "CG_XREGION_USD_GB"); p != nil && c.M.INR != nil {
			c.Out.Echo(fmt.Sprintf("AWS charges about INR %.0f once to copy between regions.", gb(g.Bytes)**p**c.M.INR))
		} else {
			c.Out.Echo("AWS charges once, by the GB, to copy between regions - the price could not be read.")
		}
	}
	if !c.Ask.Typed("move-game", "type MOVE to confirm: ", "MOVE") {
		c.Out.Echo("aborted - nothing was copied")
		return 1
	}
	err = c.M.MoveCopy(ctx, sb, sr, db, dr, id, g, library.MoveSteps{
		Part:  func(n int, name string) { c.Out.Say(fmt.Sprintf("copying %s (part %d of 3)", name, n)) },
		Check: func() { c.Out.Say("checking the copy") },
	})
	var mm *library.MismatchError
	switch {
	case errors.As(err, &mm):
		return c.die(fmt.Sprintf("%s - nothing was deleted from %s; run the move again", mm, sr))
	case err != nil:
		return c.die(fmt.Sprintf("the copy stopped - nothing was deleted from %s; run the move again to finish it", sr))
	}
	if err := c.M.MoveIndex(ctx, db, dr, id, didx, sidx); err != nil {
		return c.die(fmt.Sprintf("copied, but the index in %s could not be written - nothing was deleted from %s", dr, sr))
	}
	c.Out.Say("deleting it from " + sr)
	switch err := c.M.ForgetAt(ctx, sb, sr, id, sidx, c.Out.Log); {
	case errors.Is(err, library.ErrPartial):
		return c.die(fmt.Sprintf("moved %s to %s, but part of it is still in %s and still bills there - delete it there to finish", g.Name, dr, sr))
	case errors.Is(err, library.ErrIndex):
		return c.die(fmt.Sprintf("moved %s to %s, but the list of saved games in %s could not be updated - it may still show there", g.Name, dr, sr))
	case err != nil:
		return c.die(err.Error())
	}
	c.Out.Log(fmt.Sprintf("moved %s to %s - a build there downloads it free", g.Name, dr))
	return 0
}

// ForgetLogin is `cg library account forget [--from <bucket>]`. Deleting is
// all-or-nothing on purpose: replacing the blob is the supported way to change
// accounts.
func (c *Changer) ForgetLogin(ctx context.Context, args []string, cache library.NamesCache) int {
	_, from := flags(args)
	bucket, region, err := c.M.Place(ctx, from)
	if err != nil {
		return c.die(err.Error())
	}
	d := c.M.AccountAt(ctx, bucket, region, cache)
	if !d.Present {
		c.Out.Echo("there is no archived Steam login - nothing to delete")
		return 0
	}
	c.Out.Echo("This permanently deletes the archived Steam login.")
	if d.Accounts != nil && len(*d.Accounts) > 0 {
		var names []string
		for _, a := range *d.Accounts {
			n := "?"
			if a.Account != nil {
				n = *a.Account
			}
			names = append(names, n)
		}
		s := "s"
		if len(names) == 1 {
			s = ""
		}
		c.Out.Echo(fmt.Sprintf("It holds %d account%s: %s", len(names), s, strings.Join(names, ", ")))
	}
	c.Out.Gap()
	c.Out.Echo("  No undo, no versioning. Your games are NOT affected - they are a")
	c.Out.Echo("  separate archive. What you lose is the signed-in state: the next box")
	c.Out.Echo("  will ask for your password and Steam Guard code.")
	c.Out.Gap()
	usd := 0.0
	if d.USDMonth != nil {
		usd = *d.USDMonth
	}
	c.Out.Echo(fmt.Sprintf("  It saves $%.6f a month, which is to say nothing. Delete it to change", usd))
	c.Out.Echo("  which account a new box uses, not to save money.")
	if !c.Ask.Typed("forget-login", "type FORGET to confirm: ", "FORGET") {
		c.Out.Echo("aborted - nothing was deleted")
		return 1
	}
	c.Out.Say("deleting the Steam login saved in " + region)
	if err := c.M.ForgetLogin(ctx, bucket, region); err != nil {
		return c.die(fmt.Sprintf("could not delete s3://%s/%s", bucket, library.AccountKey))
	}
	c.Out.Log("deleted the archived Steam login")
	if from == "" {
		c.Out.Log("the next box will ask you to sign in; it is re-archived on shutdown")
		return 0
	}
	// A copy beside games left in another region: if nothing else is saved there
	// now, the bucket goes too - nothing points at it.
	apps, err := c.M.IndexAt(ctx, bucket, region)
	if err != nil || len(apps) != 0 {
		return 0
	}
	if c.M.W.DeleteBucket(ctx, bucket, region) == nil {
		c.Out.Log(fmt.Sprintf("nothing else was saved in %s - removed it, so nothing bills there", region))
	}
	return 0
}
