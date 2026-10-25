package library

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/jebin2/aws_cloud_gaming/internal/bucket"
)

type obj struct {
	data []byte
	head Head
}

type fakeS3 struct {
	buckets  map[string]string         // name -> region
	objects  map[string]map[string]obj // bucket -> key -> object
	lists    map[string][]Object       // bucket|prefix -> listing
	failGet  map[string]error
	failList map[string]error
	listing  []string
}

func (f *fakeS3) Get(_ context.Context, b, _, key string) ([]byte, error) {
	if e := f.failGet[b]; e != nil {
		return nil, e
	}
	if o, ok := f.objects[b][key]; ok {
		return o.data, nil
	}
	return nil, ErrNotFound
}
func (f *fakeS3) Head(_ context.Context, b, _, key string) (Head, error) {
	if o, ok := f.objects[b][key]; ok {
		return o.head, nil
	}
	return Head{}, ErrNotFound
}
func (f *fakeS3) List(_ context.Context, b, _, prefix string) ([]Object, error) {
	if e := f.failList[b]; e != nil {
		return nil, e
	}
	var out []Object
	for _, o := range f.lists[b] {
		if strings.HasPrefix(o.Key, prefix) {
			out = append(out, o)
		}
	}
	return out, nil
}
func (f *fakeS3) Location(_ context.Context, b string) (string, error) {
	if r, ok := f.buckets[b]; ok {
		return r, nil
	}
	return "", errors.New("no such bucket")
}
func (f *fakeS3) Buckets(context.Context) ([]string, error) {
	var out []string
	for b := range f.buckets {
		out = append(out, b)
	}
	return out, nil
}

type params map[string]string

func (p params) Path(context.Context, string) (map[string]string, error) { return p, nil }

func fl(v float64) *float64 { return &v }

const account, host = "123456789012", "gamevps"

var here = bucket.Name(account, host, "ap-south-1")

func indexJSON(apps ...App) []byte {
	b, _ := json.Marshal(index{Apps: apps})
	return b
}

func lib(f *fakeS3) Library {
	return Library{S3: f, Host: host, Region: "ap-south-1", Account: account, S3USD: fl(0.025), INR: fl(100)}
}

func world() *fakeS3 {
	return &fakeS3{
		buckets: map[string]string{here: "ap-south-1"},
		objects: map[string]map[string]obj{here: {"steam/index.json": {data: indexJSON(
			App{AppID: float64(2344520), Name: "Diablo IV", InstallDir: "Diablo IV", Bytes: 160 << 30, Pushed: "2026-10-10T12:00:00Z"},
			App{AppID: "440", Name: "Team Fortress 2", InstallDir: "Team Fortress 2", Bytes: 20 << 30, Pushed: "2026-10-11T08:30:00Z"})}}},
		lists: map[string][]Object{here: {
			{Key: "steam/steamapps/common/Diablo IV/a.bin", Size: 160 << 30},
			{Key: "steam/steamapps/common/Team Fortress 2/a.bin", Size: 20 << 30},
			{Key: "steam/steamapps/common/Half-Life/a.bin", Size: 5 << 30}, // no index entry: an unfinished push
			{Key: "steam/steamapps/compatdata/999/pfx", Size: 1 << 30},
			{Key: "steam/steamapps/compatdata/440/pfx", Size: 2 << 30},
		}},
		failGet: map[string]error{}, failList: map[string]error{},
	}
}

func TestReasonsAreNotInterchangeable(t *testing.T) {
	for msg, want := range map[string]string{
		"operation error S3: GetObject, https response error StatusCode: 400, InvalidAccessKeyId": "the AWS credentials are not valid - check: aws sts get-caller-identity",
		"NoSuchBucket: the bucket is gone":                "the bucket s3://b does not exist",
		"AccessDenied: no":                                "these AWS credentials may not read s3://b",
		"StatusCode: 403, Forbidden":                      "S3 refused the read (403) - the credentials are invalid, or may not read s3://b. Check: aws sts get-caller-identity",
		"dial tcp: lookup s3.amazonaws.com: no such host": "cannot reach S3 - no network, or no credentials configured",
		"something odd\nsecond line":                      "something odd",
	} {
		if got := Reason(errors.New(msg), "b"); got != want {
			t.Errorf("%q: got %q want %q", msg, got, want)
		}
	}
	if Reason(ErrNotFound, "b") != "missing" || Reason(nil, "b") != "" {
		t.Error("missing / none")
	}
}

// An index that could not be read must never read as an empty archive.
func TestAnUnreadableIndexIsAnErrorNotAnEmptyArchive(t *testing.T) {
	f := world()
	f.failGet[here] = errors.New("ExpiredToken: the security token has expired")
	l := lib(f)
	if _, err := l.Index(context.Background(), here, "ap-south-1"); err == nil || !strings.Contains(err.Error(), "credentials are not valid") {
		t.Fatalf("%v", err)
	}
	listing := l.List(context.Background(), nil, Disk{}, 14)
	b, _ := json.Marshal(listing)
	var m map[string]any
	_ = json.Unmarshal(b, &m)
	if m["error"] == nil || m["games"] != nil || m["total_bytes"] != nil || m["login"] != nil || m["bucket"] != here {
		t.Errorf("%s", b)
	}
	text, ok := l.Human(context.Background(), nil, Disk{})
	if ok || !strings.Contains(text, "cannot read the archive:") || !strings.Contains(text, "this is NOT the same as the archive being empty.") || strings.Contains(text, "the archive is empty") {
		t.Errorf("%s", text)
	}
	// And a bucket with no index at all is an empty one.
	f = world()
	delete(f.objects[here], "steam/index.json")
	if apps, err := lib(f).Index(context.Background(), here, "ap-south-1"); err != nil || len(apps) != 0 {
		t.Errorf("%v %v", apps, err)
	}
}

func TestOrphansAreWhatTheIndexDoesNotKnow(t *testing.T) {
	f := world()
	l := lib(f)
	apps, _ := l.Index(context.Background(), here, "ap-south-1")
	got := Orphans(f.lists[here], apps)
	if len(got) != 2 || got[0].Name != "common/Half-Life" || got[0].Bytes != 5<<30 || got[1].Name != "compatdata/999" {
		t.Errorf("%+v", got)
	}
}

func TestTheListing(t *testing.T) {
	f := world()
	f.objects[here]["steam/account/steam-account.tgz"] = obj{head: Head{Size: 22458, Modified: time.Date(2026, 10, 10, 16, 30, 3, 0, time.UTC), ETag: `"abc"`}, data: []byte("not a tarball")}
	l := lib(f)
	gb := 250
	res := l.List(context.Background(), params{"/cloud-gaming/gamevps/archive-last-seen": "2026-10-24T20:44:20Z", "/cloud-gaming/gamevps/kept/" + here + "/440": "2026-10-20"},
		Disk{Type: "g6.xlarge", GB: &gb, Measured: true, ReserveGB: ptr(20)}, 14)
	g := *res.Games
	if len(g) != 2 || g[0].Name != "Diablo IV" || *g[0].USDMonth != 4 || g[1].Kept == nil || *g[1].Kept != "2026-10-20" {
		t.Errorf("biggest first, priced, with the Reset mark: %+v", g)
	}
	if *res.TotalBytes != 180<<30 || *res.USDMonth != 4.5 || *res.OrphanBytes != 6<<30 || *res.SelectableGB != 230 || !*res.DiskMeasured {
		t.Errorf("%+v", res)
	}
	if !res.Login.Present || *res.Login.Bytes != 22458 || res.Login.Accounts != nil {
		t.Errorf("a login whose names could not be read is present, with accounts null: %+v", res.Login)
	}
	if res.LastSeen == nil || *res.LastSeen != "2026-10-24T20:44:20Z" || !*res.MarksRead {
		t.Errorf("%+v", res.LastSeen)
	}
	b, _ := json.Marshal(res)
	if !strings.Contains(string(b), `"accounts":null`) {
		t.Errorf("accounts must be null, not missing or empty: %s", b)
	}
}

func TestTheHumanList(t *testing.T) {
	f := world()
	l := lib(f)
	gb := 250
	text, ok := l.Human(context.Background(), nil, Disk{Type: "g6.xlarge", GB: &gb, ReserveGB: ptr(20)})
	if !ok {
		t.Fatal("not ok")
	}
	for _, want := range []string{"APPID      GAME", "2344520    Diablo IV", "440        Team Fortress 2", "160.0 GB  2026-10-10 12:00",
		"total                             180.0 GB   $4.50/month (INR 450)", "250 GB fits on a g6.xlarge at once (230 GB selectable, 20 GB kept free; AWS figure, not yet measured)",
		"plus 6.0 GB of ORPHANED objects from an unfinished push", "remove them: cg library clean"} {
		if !strings.Contains(text, want) {
			t.Errorf("lacks %q:\n%s", want, text)
		}
	}
	small := 100
	text, _ = l.Human(context.Background(), nil, Disk{Type: "g4dn.xlarge", GB: &small, ReserveGB: ptr(20)})
	if !strings.Contains(text, "the archive is larger than that - cg init asks which to restore") {
		t.Errorf("%s", text)
	}
	text, _ = l.Human(context.Background(), nil, Disk{Type: "g6.xlarge"})
	if !strings.Contains(text, "how much a g6.xlarge holds could not be read") {
		t.Errorf("%s", text)
	}
}

func TestAnArchiveWithNoIndexIsNotCalledEmpty(t *testing.T) {
	f := world()
	delete(f.objects[here], "steam/index.json")
	text, ok := lib(f).Human(context.Background(), nil, Disk{})
	if !ok || strings.Contains(text, "the archive is empty") {
		t.Errorf("%s", text)
	}
	for _, want := range []string{"archive holds 5 objects, 188GB", "but no per-game index yet", "  - Diablo IV", "  - Half-Life"} {
		if !strings.Contains(text, want) {
			t.Errorf("lacks %q:\n%s", want, text)
		}
	}
	// A brand new bucket carrying nothing but a copied login is empty, not an old-format archive.
	f = world()
	delete(f.objects[here], "steam/index.json")
	f.lists[here] = []Object{{Key: "steam/account/steam-account.tgz", Size: 22458}}
	if text, _ := lib(f).Human(context.Background(), nil, Disk{}); !strings.Contains(text, "the archive is empty") {
		t.Errorf("%s", text)
	}
}

func tgz(t *testing.T, vdf string) []byte {
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	tw := tar.NewWriter(zw)
	for _, f := range []struct{ name, body string }{{"./ssfn123", "x"}, {"./.steam/config/loginusers.vdf", vdf}} {
		_ = tw.WriteHeader(&tar.Header{Name: f.name, Mode: 0o644, Size: int64(len(f.body)), Typeflag: tar.TypeReg})
		_, _ = tw.Write([]byte(f.body))
	}
	_ = tw.Close()
	_ = zw.Close()
	return buf.Bytes()
}

const vdf = `"users"
{
	"76561198000000001"
	{
		"AccountName"		"alice"
		"PersonaName"		"Alice"
		"MostRecent"		"0"
		"Timestamp"		"1700000000"
	}
	"76561198000000002"
	{
		"AccountName"		"bob"
		"PersonaName"		"Bob"
		"MostRecent"		"1"
		"Timestamp"		"1600000000"
	}
}`

type memCache map[string][]SteamAccount

func (m memCache) Get(t string) ([]SteamAccount, bool) { r, ok := m[t]; return r, ok }
func (m memCache) Put(t string, r []SteamAccount)      { m[t] = r }

func TestTheArchivedLoginAndItsAccounts(t *testing.T) {
	rows := ParseLoginUsers(vdf)
	if len(rows) != 2 || *rows[0].Account != "bob" || !rows[0].MostRecent || rows[1].MostRecent || *rows[1].LastUsed != 1700000000 {
		t.Errorf("most recent first: %+v", rows)
	}
	// With one account the key is absent, and that account is what a new box signs in as.
	one := ParseLoginUsers(strings.Split(vdf, `"76561198000000002"`)[0] + "}")
	if len(one) != 1 || !one[0].MostRecent {
		t.Errorf("%+v", one)
	}
	f := world()
	f.objects[here]["steam/account/steam-account.tgz"] = obj{head: Head{Size: 22458, Modified: time.Date(2026, 10, 10, 16, 30, 3, 0, time.UTC), ETag: `"etag1"`}, data: tgz(t, vdf)}
	cache := memCache{}
	login := lib(f).AccountAt(context.Background(), here, "ap-south-1", cache)
	if !login.Present || login.Accounts == nil || len(*login.Accounts) != 2 || len(cache) != 1 {
		t.Fatalf("%+v", login)
	}
	if *login.Modified != "2026-10-10T16:30:03+00:00" || *login.USDMonth <= 0 {
		t.Errorf("%+v", login)
	}
	// Against the ETag, so it cannot be stale: a second read does not fetch.
	f.failGet[here] = errors.New("must not be fetched")
	if again := lib(f).AccountAt(context.Background(), here, "ap-south-1", cache); again.Accounts == nil || len(*again.Accounts) != 2 {
		t.Errorf("%+v", again)
	}
	// None archived: a bucket, present:false and an empty list, nothing else.
	none := lib(world()).AccountAt(context.Background(), here, "ap-south-1", nil)
	b, _ := json.Marshal(none)
	if string(b) != `{"accounts":[],"bucket":"`+here+`","present":false}` {
		t.Errorf("%s", b)
	}
}

func TestOnlyMyBucketsAreMine(t *testing.T) {
	if !Ours(bucket.Name(account, host, "ap-south-2"), "ap-south-2", account, host) || !Ours(bucket.NameNoRegion(account, host), "ap-south-1", account, host) {
		t.Error("derived and legacy names are cg's")
	}
	if Ours("cg-library-000000000000", "ap-south-1", account, host) || Ours(bucket.Name(account, host, "ap-south-2"), "ap-south-1", account, host) {
		t.Error("a name merely like ours, or ours in another region, is not ours")
	}
}

func prices(_ context.Context, region, key string) *float64 {
	if key == "CG_XREGION_USD_GB" {
		return fl(0.086)
	}
	if region == "ap-south-2" {
		return fl(0.025)
	}
	return fl(0.023)
}

// A region move left games in a bucket cg no longer looks at.
func TestGamesSavedSomewhereElse(t *testing.T) {
	old := bucket.Name(account, host, "ap-south-2")
	f := world()
	f.buckets[old] = "ap-south-2"
	f.buckets["some-other-project"] = "us-east-1"
	f.buckets["cg-library-deadbeef0000"] = "us-east-1" // named like ours, not ours
	f.objects[old] = map[string]obj{"steam/index.json": {data: indexJSON(App{AppID: "2344520", Name: "Diablo IV", InstallDir: "Diablo IV", Bytes: 160 << 30})},
		"steam/account/steam-account.tgz": {head: Head{Size: 22458, ETag: `"e"`}, data: tgz(t, vdf)}}
	f.lists[old] = []Object{{Key: "steam/steamapps/common/Diablo IV/a.bin", Size: 160 << 30}, {Key: "steam/account/steam-account.tgz", Size: 22458}}
	e := lib(f).ReadElsewhere(context.Background(), params{}, prices, 14)
	if e.Error != nil || len(*e.Places) != 1 {
		t.Fatalf("%+v", e)
	}
	p := (*e.Places)[0]
	if p.Bucket != old || *p.Region != "ap-south-2" || *p.Bytes != 160<<30+22458 || !p.Login || p.LoginDetail == nil || *p.XRegionUSD != 0.086 {
		t.Errorf("%+v", p)
	}
	if p.Games[0].AppID != "2344520" || *p.Games[0].USDMonth != 4 || *p.USDMonth != 4 {
		t.Errorf("that region's own price: %+v", p.Games[0])
	}
	if *e.Bytes != 160<<30+22458 || e.USDMonth == nil || !*e.MarksRead && e.MarksRead != nil {
		t.Errorf("%+v", e)
	}
	text, ok := ShowElsewhere(e, fl(100))
	for _, want := range []string{"ap-south-2", "160.0 GB   INR 400 a month   s3://" + old, "2344520    Diablo IV", "(and a Steam login)", "cg library move <appid> --from <bucket>"} {
		if !strings.Contains(text, want) {
			t.Errorf("lacks %q:\n%s", want, text)
		}
	}
	if !ok {
		t.Error("ok")
	}
}

func TestElsewhereFailuresAreSaidNotHidden(t *testing.T) {
	old := bucket.Name(account, host, "ap-south-2")
	f := world()
	f.buckets[old] = "ap-south-2"
	f.failList[old] = errors.New("AccessDenied: no")
	e := lib(f).ReadElsewhere(context.Background(), params{}, prices, 14)
	p := (*e.Places)[0]
	if p.Error == nil || p.Bytes != nil || p.USDMonth != nil {
		t.Errorf("a listing that failed is not an empty bucket: %+v", p)
	}
	text, ok := ShowElsewhere(e, nil)
	if !ok || !strings.Contains(text, "ap-south-2     could not be read: these AWS credentials may not read s3://"+old) {
		t.Errorf("%s", text)
	}
	if e.USDMonth == nil {
		t.Error("nothing known to add up is a total of 0, but an unreadable place has no cost to leave out")
	}
	// AWS would not list the buckets at all.
	noAcct := lib(f)
	noAcct.Account = ""
	if e := noAcct.ReadElsewhere(context.Background(), nil, prices, 14); e.Error == nil || e.Places != nil {
		t.Errorf("%+v", e)
	}
	// A real empty account (no buckets) is an answer: after a disconnect it is THE answer.
	empty := lib(&fakeS3{buckets: map[string]string{}})
	e = empty.ReadElsewhere(context.Background(), nil, prices, 14)
	text, _ = ShowElsewhere(e, nil)
	if e.Error != nil || !strings.Contains(text, "nothing saved anywhere else") {
		t.Errorf("%+v %s", e, text)
	}
}

func TestMarks(t *testing.T) {
	m := ReadMarks(context.Background(), params{"/cloud-gaming/gamevps/archive-last-seen": "2026-10-24T20:44:20Z",
		"/cloud-gaming/gamevps/kept/b/440": "2026-10-20", "/cloud-gaming/gamevps/other": "x"}, host)
	if *m.LastSeen != "2026-10-24T20:44:20Z" || m.Kept["b/440"] != "2026-10-20" || len(m.Kept) != 1 {
		t.Errorf("%+v", m)
	}
	if ReadMarks(context.Background(), nil, host) != nil {
		t.Error("unreadable marks are nil, not empty")
	}
}

func TestBucketIsDerivedWhenEnvIsSilent(t *testing.T) {
	l := lib(world())
	if b, ok := l.BucketName(); !ok || b != here {
		t.Errorf("%s %v", b, ok)
	}
	l.Bucket = "mine"
	if b, _ := l.BucketName(); b != "mine" {
		t.Error("the env wins")
	}
	l.Bucket, l.Account = "", ""
	if _, ok := l.BucketName(); ok {
		t.Error("no account, no derived name")
	}
}
