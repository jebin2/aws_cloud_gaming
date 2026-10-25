package library

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"
)

// Writer is S3 as far as changing the archive uses it.
type Writer interface {
	Store
	Put(ctx context.Context, bucket, region, key string, body []byte) error
	Delete(ctx context.Context, bucket, region, key string) error
	// DeletePrefix removes everything under a prefix; nothing under it is success.
	DeletePrefix(ctx context.Context, bucket, region, prefix string) error
	Copy(ctx context.Context, srcBucket, srcRegion, dstBucket, dstRegion, key string, size int64) error
	// DeleteBucket empties a bucket and removes it.
	DeleteBucket(ctx context.Context, bucket, region string) error
}

// MarkWriter writes the marks the cloud watchdog keeps (SSM parameters).
type MarkWriter interface {
	Put(ctx context.Context, name, value string) error
	Delete(ctx context.Context, name string) error
}

// Mutator changes the archive. Nothing here needs the box.
type Mutator struct {
	Library
	W     Writer
	Marks MarkWriter
	Now   func() time.Time
}

// Errors a caller tells apart.
var (
	// ErrPartial: part of a game is still there, and still bills. It stays in
	// the index so it stays listed, and the delete can be run again to finish it.
	ErrPartial = errors.New("only part was deleted")
	// ErrIndex: the files are gone but the list of saved games could not be updated.
	ErrIndex = errors.New("the index could not be updated")
	// ErrNotOurs: a bucket that is not one of this rig's.
	ErrNotOurs = errors.New("not one of this rig's buckets")
)

func (m Mutator) now() time.Time {
	if m.Now != nil {
		return m.Now()
	}
	return time.Now()
}

// Place is the bucket and region to act on: the one in use when none is named,
// else the named one - only if cg made it for this account and host. A name typed
// or passed in is checked here, once, for every command that writes.
func (m Mutator) Place(ctx context.Context, from string) (bucket, region string, err error) {
	cur, ok := m.BucketName()
	if from == "" {
		if !ok {
			return "", "", errors.New("could not work out the archive bucket - AWS did not answer")
		}
		bucket = cur
	} else if ok && from == cur {
		bucket = cur
	} else {
		if m.Account == "" {
			return "", "", errors.New("AWS did not answer - could not check that bucket is cg's")
		}
		r, err := m.S3.Location(ctx, from)
		if err != nil {
			return "", "", fmt.Errorf("no such bucket, or AWS did not answer: %s", from)
		}
		if !Ours(from, r, m.Account, m.Host) {
			return "", "", fmt.Errorf("not one of this rig's buckets: %s (see: cg library elsewhere)", from)
		}
		return from, r, nil
	}
	region, err = m.S3.Location(ctx, bucket)
	if err != nil || region == "" {
		region = m.Region
	}
	return bucket, region, nil
}

// rawIndex keeps every field of every entry, so writing it back loses nothing a
// newer box added.
func parseIndex(body []byte) []map[string]any {
	var d struct{ Apps []map[string]any }
	if json.Unmarshal(body, &d) != nil {
		return nil
	}
	return d.Apps
}

func indexBody(apps []map[string]any) []byte {
	if apps == nil {
		apps = []map[string]any{}
	}
	b, _ := json.MarshalIndent(map[string]any{"apps": apps}, "", " ")
	return b
}

func appID(a map[string]any) string { return IDString(a["appid"]) }

// IndexAt reads the index of a bucket as entries, or the reason it could not be.
func (m Mutator) IndexAt(ctx context.Context, bucket, region string) ([]map[string]any, error) {
	body, err := m.W.Get(ctx, bucket, region, "steam/index.json")
	if err != nil {
		if r := Reason(err, bucket); r == "missing" {
			return nil, nil
		} else {
			return nil, errors.New(r)
		}
	}
	return parseIndex(body), nil
}

// SafeDir: the folder is deleted recursively, so an empty or climbing name would
// take every game in the bucket with it.
func SafeDir(dir string) bool {
	return dir != "" && !strings.Contains(dir, "/") && dir != "." && dir != ".."
}

func find(apps []map[string]any, id string) map[string]any {
	for _, a := range apps {
		if appID(a) == id {
			return a
		}
	}
	return nil
}

func str(a map[string]any, k string) string {
	s, _ := a[k].(string)
	return s
}

func num(a map[string]any, k string) int64 {
	switch v := a[k].(type) {
	case float64:
		return int64(v)
	case int64:
		return v
	}
	return 0
}

// Target is what a delete or a move is about to touch.
type Target struct {
	Name, InstallDir string
	Bytes            int64
}

// Lookup finds a game in an index.
func Lookup(apps []map[string]any, id string) (Target, bool) {
	a := find(apps, id)
	if a == nil {
		return Target{}, false
	}
	name := str(a, "name")
	if name == "" {
		name = "?"
	}
	return Target{name, str(a, "installdir"), num(a, "bytes")}, true
}

// pairs are the three folders a game lives in.
func pairs(dir, id string) []string {
	return []string{"common/" + dir, "compatdata/" + id, "shadercache/" + id}
}

// ForgetAt removes one game from one bucket, no questions: the asking is the
// caller's, and a move calls this once the copy is verified. A bucket that is
// not the one in use and holds no game afterwards is removed too - nothing points
// at it, and it only bills. say gets the news about that.
func (m Mutator) ForgetAt(ctx context.Context, bucket, region, id string, apps []map[string]any, say func(string)) error {
	g, ok := Lookup(apps, id)
	if !ok || !SafeDir(g.InstallDir) {
		return fmt.Errorf("refusing to delete %s: its install folder is '%s'", id, g.InstallDir)
	}
	failed := 0
	for _, p := range pairs(g.InstallDir, id) {
		// The trailing slash is the boundary: without it "common/Diablo IV" is a
		// prefix of "common/Diablo IV Expansion" too, and a recursive delete
		// takes both.
		if m.W.DeletePrefix(ctx, bucket, region, "steam/steamapps/"+p+"/") != nil {
			failed++
		}
	}
	for _, k := range []string{"steam/steamapps/appmanifest_" + id + ".acf", "steam/meta/symlinks-" + id + ".tsv"} {
		if m.W.Delete(ctx, bucket, region, k) != nil {
			failed++
		}
	}
	// Part of it is still there: leave it in the index, so it stays listed -
	// with a price - and Delete can be run again to finish it. Dropped from the
	// index, the rest would bill with nothing pointing at it.
	if failed > 0 {
		return ErrPartial
	}
	var left []map[string]any
	for _, a := range apps {
		if appID(a) != id {
			left = append(left, a)
		}
	}
	if m.W.Put(ctx, bucket, region, "steam/index.json", indexBody(left)) != nil {
		return ErrIndex
	}
	if m.Marks != nil {
		_ = m.Marks.Delete(ctx, fmt.Sprintf("/cloud-gaming/%s/kept/%s/%s", m.Host, bucket, id))
	}
	if cur, _ := m.BucketName(); len(left) == 0 && bucket != cur {
		if m.W.DeleteBucket(ctx, bucket, region) == nil {
			say(fmt.Sprintf("nothing else was saved in %s - removed it, so nothing bills there", region))
		} else {
			say(fmt.Sprintf("nothing else is saved in %s, but it could not be removed: cg library elsewhere", region))
		}
	}
	return nil
}

// Reset starts a game's countdown again today. The watchdog deletes a game N days
// after the later of "a machine was last seen" and this mark; it is an SSM
// parameter, which costs nothing.
func (m Mutator) Reset(ctx context.Context, bucket, id string) error {
	return m.Marks.Put(ctx, fmt.Sprintf("/cloud-gaming/%s/kept/%s/%s", m.Host, bucket, id), m.now().UTC().Format("2006-01-02T15:04:05Z"))
}

// Orphans finds what the index does not know in the bucket in use.
func (m Mutator) OrphansIn(ctx context.Context, bucket, region string) ([]Orphan, error) {
	apps, err := m.Index(ctx, bucket, region)
	if err != nil {
		return nil, err
	}
	objs, err := m.W.List(ctx, bucket, region, "steam/steamapps/")
	if err != nil {
		return nil, err
	}
	return Orphans(objs, apps), nil
}

// DeleteOrphan removes one orphan folder. The slash matters: an orphan called
// "common/Diablo" must not take "common/Diablo IV" with it.
func (m Mutator) DeleteOrphan(ctx context.Context, bucket, region, name string) error {
	return m.W.DeletePrefix(ctx, bucket, region, "steam/steamapps/"+name+"/")
}

// ForgetLogin deletes the archived Steam login. It is all-or-nothing on
// purpose: removing ONE account would mean editing loginusers.vdf, that
// account's entry in local.vdf and its userdata, then repacking - undocumented
// Steam internals where a near miss produces an archive that restores a BROKEN
// login, which is worse than having none.
func (m Mutator) ForgetLogin(ctx context.Context, bucket, region string) error {
	return m.W.Delete(ctx, bucket, region, AccountKey)
}

// Summary is how many objects and bytes sit under a prefix, for a copy to be checked.
func (m Mutator) Summary(ctx context.Context, bucket, region, prefix string) (int, int64, error) {
	objs, err := m.W.List(ctx, bucket, region, prefix)
	var n int64
	for _, o := range objs {
		n += o.Size
	}
	return len(objs), n, err
}

// Move brings a game left in another bucket to the one the machine is built in.
// Copied server to server, checked file for file, and only then deleted at the
// source: a copy that does not match leaves both where they were.
type MoveSteps struct {
	Part   func(n int, name string) // "copying <name> (part n of 3)"
	Check  func()
	Delete func()
}

var (
	ErrCopy    = errors.New("the copy stopped")
	ErrDestIdx = errors.New("copied, but the index could not be written")
)

// MismatchError: a folder that is not the same size at both ends after the copy.
type MismatchError struct {
	Pair        string
	Here, There string // "<objects> <bytes>"
}

func (e *MismatchError) Error() string {
	return fmt.Sprintf("the copy of %s does not match (%s here, %s there)", e.Pair, e.Here, e.There)
}

// Copy copies the three folders and the two small files, and verifies them. A
// mismatch names the folder.
func (m Mutator) MoveCopy(ctx context.Context, sb, sr, db, dr, id string, g Target, steps MoveSteps) error {
	for i, p := range pairs(g.InstallDir, id) {
		if steps.Part != nil {
			steps.Part(i+1, g.Name)
		}
		if err := m.syncPrefix(ctx, sb, sr, db, dr, "steam/steamapps/"+p+"/"); err != nil {
			return fmt.Errorf("%w: %v", ErrCopy, err)
		}
	}
	for _, k := range []string{"steam/steamapps/appmanifest_" + id + ".acf", "steam/meta/symlinks-" + id + ".tsv"} {
		if h, err := m.W.Head(ctx, sb, sr, k); err == nil {
			_ = m.W.Copy(ctx, sb, sr, db, dr, k, h.Size)
		}
	}
	if steps.Check != nil {
		steps.Check()
	}
	for _, p := range pairs(g.InstallDir, id) {
		prefix := "steam/steamapps/" + p + "/"
		an, as, e1 := m.Summary(ctx, sb, sr, prefix)
		bn, bs, e2 := m.Summary(ctx, db, dr, prefix)
		if e1 != nil || e2 != nil || an != bn || as != bs {
			return &MismatchError{p, fmt.Sprintf("%d %d", an, as), fmt.Sprintf("%d %d", bn, bs)}
		}
	}
	return nil
}

// syncPrefix copies what is missing or different, as `aws s3 sync` does.
func (m Mutator) syncPrefix(ctx context.Context, sb, sr, db, dr, prefix string) error {
	src, err := m.W.List(ctx, sb, sr, prefix)
	if err != nil {
		return err
	}
	dst, err := m.W.List(ctx, db, dr, prefix)
	if err != nil {
		return err
	}
	have := map[string]int64{}
	for _, o := range dst {
		have[o.Key] = o.Size
	}
	sort.Slice(src, func(i, j int) bool { return src[i].Key < src[j].Key })
	for _, o := range src {
		if sz, ok := have[o.Key]; ok && sz == o.Size {
			continue
		}
		if err := m.W.Copy(ctx, sb, sr, db, dr, o.Key, o.Size); err != nil {
			return err
		}
	}
	return nil
}

// MoveIndex puts the game in the machine's index before it leaves the old one:
// at no moment is the game in neither.
func (m Mutator) MoveIndex(ctx context.Context, db, dr, id string, dest, src []map[string]any) error {
	var next []map[string]any
	for _, a := range dest {
		if appID(a) != id {
			next = append(next, a)
		}
	}
	if a := find(src, id); a != nil {
		next = append(next, a)
	}
	if m.W.Put(ctx, db, dr, "steam/index.json", indexBody(next)) != nil {
		return ErrDestIdx
	}
	return nil
}
