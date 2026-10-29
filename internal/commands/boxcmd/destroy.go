package boxcmd

import (
	"context"
	"errors"
	"fmt"
	iamtypes "github.com/aws/aws-sdk-go-v2/service/iam/types"
	"os"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/iam"

	"github.com/jebin2/aws_cloud_gaming/internal/destroy"
	"github.com/jebin2/aws_cloud_gaming/internal/format"
	"github.com/jebin2/aws_cloud_gaming/internal/library"
	"github.com/jebin2/aws_cloud_gaming/internal/local"
	"github.com/jebin2/aws_cloud_gaming/internal/session"
)

// IAM is what locking the archive uses.
type IAM interface {
	GetRole(context.Context, *iam.GetRoleInput, ...func(*iam.Options)) (*iam.GetRoleOutput, error)
	PutRolePolicy(context.Context, *iam.PutRolePolicyInput, ...func(*iam.Options)) (*iam.PutRolePolicyOutput, error)
}

// DestroyDeps is what `cg destroy` uses beyond the box.
type DestroyDeps struct {
	EC2 destroy.EC2
	IAM IAM
	Lib library.Library
	// Ender closes a stream; nil makes the real one.
	Ender *session.Ender
	// All is what --all uses; nil refuses it.
	All *AllDeps
}

// archiveLock revokes (ro) or restores (rw) the box's write access to the
// archive, so its own shutdown mirror cannot change anything. This is what makes
// `--no-push` mean what it says.
//
// Skipping the laptop-side push is only half the job: cg-library-shutdown.service
// runs ON the box from ExecStop, and terminating triggers a graceful shutdown, so
// it fires whether or not this end pushed. Disabling that unit would need ssh -
// unavailable exactly when it is most wanted, because a box too busy to answer
// ssh is the usual reason for wanting --no-push at all. IAM works from here
// regardless of the box's state.
func isNoSuchEntity(err error) bool {
	var ne *iamtypes.NoSuchEntityException
	return errors.As(err, &ne) || strings.Contains(err.Error(), "NoSuchEntity")
}

func (d Deps) archiveLock(ctx context.Context, x DestroyDeps, mode string) bool {
	role := d.Box.Host + "-box"
	b, ok := x.Lib.BucketName()
	if !ok {
		return true
	}
	if _, err := x.IAM.GetRole(ctx, &iam.GetRoleInput{RoleName: aws.String(role)}); err != nil {
		// Only a role that does not exist has nothing to lock. A refusal or a
		// throttle says nothing about whether the box can write, and answering
		// "locked" would let --no-push start with the archive still open.
		if isNoSuchEntity(err) {
			return true
		}
		d.Out.Log(fmt.Sprintf("could not read the role %s (%s) - cannot tell whether the archive is %s", role, firstErrorLine(err.Error()), map[string]string{"ro": "locked", "rw": "writable again"}[mode]))
		return false
	}
	write := ""
	if mode == "rw" {
		write = `,"s3:PutObject","s3:DeleteObject","s3:AbortMultipartUpload","s3:ListMultipartUploadParts"`
	}
	doc := fmt.Sprintf(`{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:ListBucket","s3:GetBucketLocation"],"Resource":"arn:aws:s3:::%s"},{"Effect":"Allow","Action":["s3:GetObject"%s],"Resource":"arn:aws:s3:::%s/*"}]}`, b, write, b)
	if _, err := x.IAM.PutRolePolicy(ctx, &iam.PutRolePolicyInput{RoleName: aws.String(role), PolicyName: aws.String("library-rw"), PolicyDocument: aws.String(doc)}); err != nil {
		d.Out.Log(fmt.Sprintf("could not set the archive to %s (needs iam:PutRolePolicy)", mode))
		return false
	}
	switch mode {
	case "ro":
		d.Out.Log(fmt.Sprintf("archive set read-only for %s - its shutdown mirror cannot write", role))
	case "rw":
		d.Out.Log(fmt.Sprintf("archive writable again for %s", role))
	}
	return true
}

// archiveReport says what the archive holds, asked from HERE rather than from the
// box - which is the only way to ask once the box is stopped or gone, and exactly
// when the question matters most. It reports whether anything is there.
func (d Deps) archiveReport(ctx context.Context, x DestroyDeps) bool {
	b, ok := x.Lib.BucketName()
	if !ok {
		d.Out.Log("could not work out the archive bucket - AWS did not answer")
		return false
	}
	region := x.Lib.Region
	if loc, err := x.Lib.S3.Location(ctx, b); err == nil && loc != "" {
		region = loc
	}
	objs, _ := x.Lib.S3.List(ctx, b, region, "steam/")
	var size int64
	for _, o := range objs {
		size += o.Size
	}
	fmt.Fprintf(d.Out.Stdout, "      archive s3://%s/steam holds %d objects, %s\n", b, len(objs), format.IEC(size))
	return len(objs) > 0
}

// sessionEndFirst: a stream open onto the box being deleted goes black mid-push,
// and the `cg open` behind it then offers to end a box that no longer exists.
// Close it first, and say so.
func (d Deps) sessionEndFirst(x DestroyDeps) {
	l, held := session.Running(d.SessionFile, d.Probe)
	if !held {
		return
	}
	d.Out.Log(fmt.Sprintf("a stream is open from this laptop (pid %d) - it streams the box being destroyed", l.PID))
	if !d.Ask.Confirm("end-session", "close the stream first? [Y/n] ", "Y") {
		d.Out.LogAs("warn", "leaving the stream open - Moonlight will lose the box mid-destroy")
		return
	}
	e := x.Ender
	if e == nil {
		e = &session.Ender{Path: d.SessionFile, Probe: d.Probe, Sleep: time.Sleep,
			Signal: func(pid int, s syscall.Signal) {
				if p, err := os.FindProcess(pid); err == nil {
					_ = p.Signal(s)
				}
			},
			Children: func(pid int, s syscall.Signal) {
				_, _ = d.R.Run(context.Background(), local.Cmd{Name: "pkill", Args: []string{"-" + strconv.Itoa(int(s)), "-P", strconv.Itoa(pid)}})
			}}
	}
	if e.End() {
		d.Out.LogAs("ok", "stream closed")
	} else {
		d.Out.LogAs("warn", fmt.Sprintf("could not close the stream (pid %d) - close the Moonlight window", l.PID))
	}
}

// DestroyBox is `cg destroy [--force] [--no-push]`.
func (d Deps) DestroyBox(ctx context.Context, x DestroyDeps, args []string) int {
	var all, force, nopush bool
	for _, a := range args {
		switch a {
		case "--all":
			all = true
		case "--force":
			force = true
		case "--no-push":
			nopush = true
		// Refuse anything else rather than ignore it: a typo like --everything
		// must not quietly behave as a plain destroy and leave the volume billing.
		default:
			return d.die(fmt.Sprintf("unknown option '%s' for destroy (--all, --force, --no-push)", a))
		}
	}
	// --no-push with --all would be a promise to leave the archive exactly as it is
	// while deleting it. The Bash accepted the combination and quietly ignored the
	// flag; refusing it is the only honest answer.
	if all && nopush {
		return d.die("--no-push cannot be combined with --all: --all deletes the game archive itself, so there is no archive to leave untouched")
	}
	d.sessionEndFirst(x)
	if all {
		if x.All == nil {
			return d.die("destroy --all is not available here")
		}
		// --all means the games go too, so mirroring them to S3 first and then
		// deleting the archive would be absurd. That path skips the push entirely.
		return d.destroyEverything(ctx, x, *x.All, force)
	}

	// Destroy takes the instance store with it, and that is where the games are. A
	// failed push is not a warning to print and carry on past - it means the next
	// `cg init` re-downloads everything, which is the exact problem this whole
	// design exists to solve.
	if nopush {
		d.Out.Say("destroying WITHOUT mirroring - the archive is left exactly as it is")
		if !d.archiveLock(ctx, x, "ro") {
			return d.die("could not revoke the box's write access, so its shutdown mirror could still\n       overwrite the archive. Either grant iam:PutRolePolicy, or wait for the box\n       to finish what it is doing and destroy normally.")
		}
		// Waited for in full, unlike a plain destroy: the box's own shutdown mirror
		// runs while it is shutting down, and the archive may be made writable again
		// only once that has finished - which is when the box is "terminated".
		rc := d.remove(ctx, x, true)
		if rc != 0 {
			d.Out.Log("archive left read-only - the box is not confirmed gone, and its shutdown mirror could still write. cg init restores it once a box is built")
			return rc
		}
		// The instance is gone, so restore normal access. If this is interrupted the
		// policy stays read-only, and `cg init` rewrites it on the next build.
		if !d.archiveLock(ctx, x, "rw") {
			d.Out.Log("archive left read-only - cg init restores it")
		}
		return rc
	}

	// But only a RUNNING box can be pushed from. Gating on the push regardless of
	// state made destroying a stopped box impossible without --force, which would
	// have trained the habit of passing --force to destroy.
	st, _ := d.Box.State(ctx)
	if d.Box.ID == "" {
		st = "none"
	} else if st == "" {
		st = "unknown"
	}
	if st == "running" {
		if !d.Push(ctx, "", "box is not reachable - no push", "mirroring the game library to S3 before the box goes away") {
			if !force {
				d.block("The push from here failed",
					"",
					"  The push from here failed, which usually means ssh cannot reach the box.",
					"  That is not the same as 'the games are lost':",
					"",
					"    cg-library-shutdown.service runs ON the box, from ExecStop, and",
					"    mirrors the library as the machine shuts down. It needs no ssh.",
					"    Terminating sends a graceful shutdown, so it still runs.",
					"",
					"  So --force is usually safe here. Afterwards, confirm it worked:",
					"      cg library list      # the archive, read straight from S3",
					"")
				return d.die("not mirrored from here - see above, then: cg destroy --force")
			}
			d.Out.Log("WARNING: proceeding without a mirror (--force) - games will be re-downloaded")
		}
	} else {
		d.Out.Log(fmt.Sprintf("box is %s - nothing local to push", st))
		if !d.archiveReport(ctx, x) {
			d.Out.Log("the archive is EMPTY - if you expected games in it, stop here")
		}
	}
	return d.remove(ctx, x, false)
}

// remove is the destroy itself: the instance, cg's images and their snapshots,
// the box's leftover volumes.
func (d Deps) remove(ctx context.Context, x DestroyDeps, waitForTerminated bool) int {
	plan, err := destroy.Read(ctx, x.EC2, d.Box.Host, d.tagKey())
	if err != nil {
		return d.die("could not tell what to delete - AWS did not answer: " + err.Error())
	}
	d.Out.Block("What this destroy does", destroy.Describe(plan, d.Box.Host, d.Env.Int("GAME_ARCHIVE_EXPIRY_DAYS"), d.Now()))
	rm := destroy.Remover{C: x.EC2, Say: d.Out.Say, Log: d.Out.Log, Fail: func(s string) { d.Out.LogAs("fail", s) },
		Wait: func(ctx context.Context, id string) bool {
			b := d.Box
			b.ID = id
			if waitForTerminated {
				return b.WaitState(ctx, "terminated", 600*time.Second)
			}
			// A spot box takes 6-7 minutes to reach "terminated", and billing
			// for it ended when it began shutting down. Nothing after this needs
			// it gone (--all, which deletes the security group, waits in full).
			if b.WaitState(ctx, "terminated", 45*time.Second) {
				return true
			}
			if s, _ := b.State(ctx); s == "shutting-down" {
				d.Out.Log("AWS is still tearing the machine down (a few more minutes) - it is no longer billing")
				return true
			}
			return false
		}}
	failures, gone := rm.Run(ctx, plan)
	// Sunshine credentials and the tailnet node belong to the box being deleted;
	// leaving them behind makes the next build authenticate against nothing. Only
	// once the box is gone: the id of one that is still running must not be lost.
	//
	// GAME_REGION is NOT in this list, and must never be: it is a setting the
	// person chose, not state this box created. Deleting it made the next
	// `cg init` fall back to the registry default - so a destroy followed by a
	// rebuild silently moved the rig to a different region, with a different
	// archive bucket, and said nothing.
	if gone {
		for _, k := range []string{"GAME_INSTANCE_ID", "GAME_TS_HOST", "GAME_TS_NODE", "SUNSHINE_USER", "SUNSHINE_PASS"} {
			_ = d.Env.Unset(k)
		}
	}
	d.Out.Log(fmt.Sprintf("keeping the budget %s-monthly - it guards the account, not the box", d.Box.Host))
	if len(failures) > 0 {
		return d.die(fmt.Sprintf("%d thing(s) could not be deleted and may still bill - see above, then run cg destroy again", len(failures)))
	}
	d.Out.Say("box deleted - security group, key pair and tailnet node kept for cg init")
	return 0
}

func (d Deps) tagKey() string {
	if d.Box.TagKey != "" {
		return d.Box.TagKey
	}
	return "cg:host"
}
