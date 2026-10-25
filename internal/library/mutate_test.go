package library

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

type marks map[string]string

func (k marks) Put(_ context.Context, n, v string) error { k[n] = v; return nil }
func (k marks) Delete(_ context.Context, n string) error { delete(k, n); return nil }

const idx = `{"apps":[{"appid":1091500,"name":"Cyberpunk","installdir":"Cyberpunk 2077","bytes":100,"pushed":"x","extra":"kept"},{"appid":"2","name":"Diablo IV","installdir":"Diablo IV","bytes":50,"pushed":"y"}]}`

func fixture() (*MemStore, Mutator, marks) {
	s := NewMemStore()
	home := "cg-acct-gamevps-hash"
	s.Add(home, "ap-south-1", "steam/index.json", 0)
	s.Objs[home]["steam/index.json"] = []byte(idx)
	for _, k := range []string{
		"steam/steamapps/common/Cyberpunk 2077/a.bin", "steam/steamapps/common/Cyberpunk 2077/b.bin",
		"steam/steamapps/compatdata/1091500/p", "steam/steamapps/shadercache/1091500/s",
		"steam/steamapps/appmanifest_1091500.acf", "steam/meta/symlinks-1091500.tsv",
		// A game whose folder is a prefix of another's name.
		"steam/steamapps/common/Diablo IV/d", "steam/steamapps/common/Diablo IV Expansion/e",
		"steam/steamapps/compatdata/2/p",
	} {
		s.Add(home, "ap-south-1", k, 10)
	}
	k := marks{}
	m := Mutator{Library: Library{S3: s, Host: "gamevps", Region: "ap-south-1", Account: "123", Bucket: home}, W: s, Marks: k,
		Now: func() time.Time { return time.Date(2026, 10, 25, 9, 8, 7, 0, time.UTC) }}
	return s, m, k
}

func TestForgetDeletesTheGameAndOnlyThatGame(t *testing.T) {
	s, m, k := fixture()
	ctx := context.Background()
	k["/cloud-gaming/gamevps/kept/cg-acct-gamevps-hash/1091500"] = "2026-01-01T00:00:00Z"
	apps, err := m.IndexAt(ctx, "cg-acct-gamevps-hash", "ap-south-1")
	if err != nil || len(apps) != 2 {
		t.Fatal(err, apps)
	}
	if err := m.ForgetAt(ctx, "cg-acct-gamevps-hash", "ap-south-1", "1091500", apps, func(string) {}); err != nil {
		t.Fatal(err)
	}
	for key := range s.Objs["cg-acct-gamevps-hash"] {
		if strings.Contains(key, "Cyberpunk") || strings.Contains(key, "1091500") {
			t.Errorf("left behind: %s", key)
		}
	}
	// The trailing slash is the boundary: Diablo IV's prefix is not Diablo IV Expansion's.
	if _, ok := s.Objs["cg-acct-gamevps-hash"]["steam/steamapps/common/Diablo IV Expansion/e"]; !ok {
		t.Error("took a neighbour with it")
	}
	got, _ := m.IndexAt(ctx, "cg-acct-gamevps-hash", "ap-south-1")
	if len(got) != 1 || appID(got[0]) != "2" {
		t.Errorf("index %v", got)
	}
	if _, ok := k["/cloud-gaming/gamevps/kept/cg-acct-gamevps-hash/1091500"]; ok {
		t.Error("the reset mark is gone with the game")
	}
	// Fields cg does not know about survive a rewrite of the index.
	_ = m.W.Put(ctx, "cg-acct-gamevps-hash", "", "steam/index.json", []byte(idx))
	apps, _ = m.IndexAt(ctx, "cg-acct-gamevps-hash", "ap-south-1")
	if apps[0]["extra"] != "kept" {
		t.Error("lost a field")
	}
}

func TestAPartialDeleteStaysListedSoItCanBeFinished(t *testing.T) {
	s, m, _ := fixture()
	s.FailDel = map[string]bool{"steam/steamapps/compatdata/1091500": true}
	apps, _ := m.IndexAt(context.Background(), "cg-acct-gamevps-hash", "ap-south-1")
	if err := m.ForgetAt(context.Background(), "cg-acct-gamevps-hash", "ap-south-1", "1091500", apps, func(string) {}); !errors.Is(err, ErrPartial) {
		t.Fatalf("%v", err)
	}
	got, _ := m.IndexAt(context.Background(), "cg-acct-gamevps-hash", "ap-south-1")
	if len(got) != 2 {
		t.Error("dropped from the index, the rest would bill with nothing pointing at it")
	}
	// Files gone, index refused: a different, said difference.
	s2, m2, _ := fixture()
	s2.FailPut = true
	apps, _ = m2.IndexAt(context.Background(), "cg-acct-gamevps-hash", "ap-south-1")
	if err := m2.ForgetAt(context.Background(), "cg-acct-gamevps-hash", "ap-south-1", "1091500", apps, func(string) {}); !errors.Is(err, ErrIndex) {
		t.Errorf("%v", err)
	}
}

func TestForgetRefusesAnUnsafeFolder(t *testing.T) {
	_, m, _ := fixture()
	for _, dir := range []string{"", ".", "..", "a/b"} {
		apps := []map[string]any{{"appid": 5.0, "name": "x", "installdir": dir}}
		if err := m.ForgetAt(context.Background(), "cg-acct-gamevps-hash", "ap-south-1", "5", apps, func(string) {}); err == nil || !strings.Contains(err.Error(), "refusing to delete 5") {
			t.Errorf("%q: %v", dir, err)
		}
	}
	// And a game that is not in the index at all.
	if err := m.ForgetAt(context.Background(), "b", "r", "999", nil, func(string) {}); err == nil {
		t.Error("nothing to delete")
	}
}

func TestAnEmptiedOtherBucketIsRemovedAndTheOneInUseIsNot(t *testing.T) {
	s := NewMemStore()
	other := "cg-other"
	s.Add(other, "us-east-1", "steam/index.json", 0)
	s.Objs[other]["steam/index.json"] = []byte(`{"apps":[{"appid":7,"name":"G","installdir":"G","bytes":1}]}`)
	s.Add(other, "us-east-1", "steam/steamapps/common/G/f", 5)
	m := Mutator{Library: Library{S3: s, Host: "gamevps", Region: "ap-south-1", Account: "123", Bucket: "cg-home"}, W: s, Marks: marks{}}
	apps, _ := m.IndexAt(context.Background(), other, "us-east-1")
	var said string
	if err := m.ForgetAt(context.Background(), other, "us-east-1", "7", apps, func(x string) { said = x }); err != nil {
		t.Fatal(err)
	}
	if _, ok := s.Objs[other]; ok || !strings.Contains(said, "removed it, so nothing bills there") {
		t.Errorf("bucket kept: %v %q", s.Objs, said)
	}
	// The bucket in use keeps its (now empty) index.
	_, m2, _ := fixture()
	apps, _ = m2.IndexAt(context.Background(), "cg-acct-gamevps-hash", "ap-south-1")
	for _, id := range []string{"1091500", "2"} {
		if err := m2.ForgetAt(context.Background(), "cg-acct-gamevps-hash", "ap-south-1", id, apps, func(string) {}); err != nil {
			t.Fatal(err)
		}
		apps, _ = m2.IndexAt(context.Background(), "cg-acct-gamevps-hash", "ap-south-1")
	}
	if _, ok := m2.W.(*MemStore).Objs["cg-acct-gamevps-hash"]; !ok {
		t.Error("the bucket in use must stay")
	}
}

func TestResetWritesTodayAsTheMark(t *testing.T) {
	_, m, k := fixture()
	if err := m.Reset(context.Background(), "cg-acct-gamevps-hash", "1091500"); err != nil {
		t.Fatal(err)
	}
	if k["/cloud-gaming/gamevps/kept/cg-acct-gamevps-hash/1091500"] != "2026-10-25T09:08:07Z" {
		t.Errorf("%v", k)
	}
}

func TestPlaceAcceptsOnlyBucketsCgMade(t *testing.T) {
	s, m, _ := fixture()
	ctx := context.Background()
	if b, r, err := m.Place(ctx, ""); err != nil || b != "cg-acct-gamevps-hash" || r != "ap-south-1" {
		t.Errorf("%s %s %v", b, r, err)
	}
	s.Add("somebody-elses", "us-east-1", "x", 1)
	if _, _, err := m.Place(ctx, "somebody-elses"); err == nil || !strings.Contains(err.Error(), "not one of this rig's buckets: somebody-elses (see: cg library elsewhere)") {
		t.Errorf("%v", err)
	}
	if _, _, err := m.Place(ctx, "no-such"); err == nil || !strings.Contains(err.Error(), "no such bucket") {
		t.Errorf("%v", err)
	}
	m.Account = ""
	m.Bucket = ""
	if _, _, err := m.Place(ctx, ""); err == nil {
		t.Error("cannot work out the bucket")
	}
}

func TestOrphansAreDeletedWithoutTakingANeighbour(t *testing.T) {
	s, m, _ := fixture()
	ctx := context.Background()
	s.Add("cg-acct-gamevps-hash", "ap-south-1", "steam/steamapps/common/Diablo/x", 99)
	o, err := m.OrphansIn(ctx, "cg-acct-gamevps-hash", "ap-south-1")
	// Diablo IV Expansion is unindexed too, so there are two - the bigger first.
	if err != nil || len(o) != 2 || o[0].Name != "common/Diablo" || o[0].Bytes != 99 {
		t.Fatalf("%v %v", o, err)
	}
	if err := m.DeleteOrphan(ctx, "cg-acct-gamevps-hash", "ap-south-1", o[0].Name); err != nil {
		t.Fatal(err)
	}
	if _, ok := s.Objs["cg-acct-gamevps-hash"]["steam/steamapps/common/Diablo IV/d"]; !ok {
		t.Error("an orphan called Diablo took Diablo IV with it - the Bash did this, rm without a trailing slash")
	}
	if _, ok := s.Objs["cg-acct-gamevps-hash"]["steam/steamapps/common/Diablo IV Expansion/e"]; !ok {
		t.Error("nor its sibling orphan")
	}
	if _, ok := s.Objs["cg-acct-gamevps-hash"]["steam/steamapps/common/Diablo/x"]; ok {
		t.Error("the orphan is still there")
	}
}

func TestMoveCopiesChecksThenDeletesAtTheSource(t *testing.T) {
	s, m, _ := fixture()
	ctx := context.Background()
	src := "cg-old-bucket"
	s.Add(src, "us-east-1", "steam/index.json", 0)
	s.Objs[src]["steam/index.json"] = []byte(`{"apps":[{"appid":9,"name":"Moved","installdir":"Moved Game","bytes":30}]}`)
	for _, k := range []string{"steam/steamapps/common/Moved Game/a", "steam/steamapps/common/Moved Game/b", "steam/steamapps/compatdata/9/p", "steam/steamapps/appmanifest_9.acf"} {
		s.Add(src, "us-east-1", k, 10)
	}
	sidx, _ := m.IndexAt(ctx, src, "us-east-1")
	didx, _ := m.IndexAt(ctx, "cg-acct-gamevps-hash", "ap-south-1")
	g, ok := Lookup(sidx, "9")
	if !ok || g.Name != "Moved" || g.Bytes != 30 {
		t.Fatalf("%+v", g)
	}
	var parts []int
	if err := m.MoveCopy(ctx, src, "us-east-1", "cg-acct-gamevps-hash", "ap-south-1", "9", g, MoveSteps{Part: func(n int, _ string) { parts = append(parts, n) }}); err != nil {
		t.Fatal(err)
	}
	if len(parts) != 3 {
		t.Errorf("three parts: %v", parts)
	}
	if _, ok := s.Objs["cg-acct-gamevps-hash"]["steam/steamapps/appmanifest_9.acf"]; !ok {
		t.Error("the manifest comes too")
	}
	// In the machine's index before it leaves the old one.
	if err := m.MoveIndex(ctx, "cg-acct-gamevps-hash", "ap-south-1", "9", didx, sidx); err != nil {
		t.Fatal(err)
	}
	got, _ := m.IndexAt(ctx, "cg-acct-gamevps-hash", "ap-south-1")
	if len(got) != 3 {
		t.Errorf("index %v", got)
	}
	if err := m.ForgetAt(ctx, src, "us-east-1", "9", sidx, func(string) {}); err != nil {
		t.Fatal(err)
	}
	if _, ok := s.Objs[src]; ok {
		t.Error("the emptied old bucket is removed")
	}
	if _, ok := s.Objs["cg-acct-gamevps-hash"]["steam/steamapps/common/Moved Game/a"]; !ok {
		t.Error("the game is where the machine is")
	}
}

func TestAMoveThatDoesNotMatchLeavesBothWhereTheyWere(t *testing.T) {
	s, m, _ := fixture()
	ctx := context.Background()
	src := "cg-old-bucket"
	for _, k := range []string{"steam/steamapps/common/Moved Game/a", "steam/steamapps/compatdata/9/p"} {
		s.Add(src, "us-east-1", k, 10)
	}
	g := Target{"Moved", "Moved Game", 20}
	s.FailCp = "compatdata"
	if err := m.MoveCopy(ctx, src, "us-east-1", "cg-acct-gamevps-hash", "ap-south-1", "9", g, MoveSteps{}); !errors.Is(err, ErrCopy) {
		t.Errorf("%v", err)
	}
	if len(s.Objs[src]) != 2 {
		t.Error("nothing is deleted from the source")
	}
	// A destination that holds a different size for a key is copied again (sync), and a
	// listing that still differs afterwards is a mismatch, not a success.
	s.FailCp = ""
	s.Add("cg-acct-gamevps-hash", "ap-south-1", "steam/steamapps/common/Moved Game/extra", 5)
	if err := m.MoveCopy(ctx, src, "us-east-1", "cg-acct-gamevps-hash", "ap-south-1", "9", g, MoveSteps{}); !errors.As(err, new(*MismatchError)) {
		t.Errorf("an extra file there is not 'the same': %v", err)
	}
}

func TestSafeDir(t *testing.T) {
	for dir, want := range map[string]bool{"Game": true, "My Game": true, "": false, ".": false, "..": false, "a/b": false} {
		if SafeDir(dir) != want {
			t.Errorf("%q", dir)
		}
	}
}
