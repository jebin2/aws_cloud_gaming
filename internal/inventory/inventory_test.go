package inventory

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/jebin2/aws_cloud_gaming/internal/bucket"
	"github.com/jebin2/aws_cloud_gaming/internal/costfacts"
	"github.com/jebin2/aws_cloud_gaming/internal/library"
	"github.com/jebin2/aws_cloud_gaming/internal/pricing"
	"github.com/jebin2/aws_cloud_gaming/internal/storage"
)

type cloud struct {
	account   string
	regions   []string
	machines  map[string][]Machine
	machFail  map[string]bool
	watchdogs map[string]bool
	role      bool
	budget    bool
	settings  map[string][]string
}

func (c cloud) Account(context.Context) (string, error) {
	if c.account == "" {
		return "", errors.New("no")
	}
	return c.account, nil
}
func (c cloud) Regions(context.Context) ([]string, error) { return c.regions, nil }
func (c cloud) Machines(_ context.Context, r string) ([]Machine, error) {
	if c.machFail[r] {
		return nil, errors.New("denied")
	}
	return c.machines[r], nil
}
func (c cloud) Watchdog(_ context.Context, r string) bool     { return c.watchdogs[r] }
func (c cloud) Role(context.Context) bool                     { return c.role }
func (c cloud) Budget(context.Context, string) bool           { return c.budget }
func (c cloud) Settings(_ context.Context, r string) []string { return c.settings[r] }

type s3 struct {
	buckets map[string]string
	lists   map[string][]library.Object
	index   map[string][]byte
	listErr map[string]error
}

func (s s3) Get(_ context.Context, b, _, key string) ([]byte, error) {
	if key == "steam/index.json" {
		if d, ok := s.index[b]; ok {
			return d, nil
		}
	}
	return nil, library.ErrNotFound
}
func (s s3) Head(context.Context, string, string, string) (library.Head, error) {
	return library.Head{}, library.ErrNotFound
}
func (s s3) List(_ context.Context, b, _, prefix string) ([]library.Object, error) {
	if e := s.listErr[b]; e != nil {
		return nil, e
	}
	if _, ok := s.buckets[b]; !ok {
		return nil, errors.New("NoSuchBucket: the bucket does not exist")
	}
	var out []library.Object
	for _, o := range s.lists[b] {
		if strings.HasPrefix(o.Key, prefix) {
			out = append(out, o)
		}
	}
	return out, nil
}
func (s s3) Location(_ context.Context, b string) (string, error) {
	if r, ok := s.buckets[b]; ok {
		return r, nil
	}
	return "", errors.New("none")
}
func (s s3) Buckets(context.Context) ([]string, error) {
	var out []string
	for b := range s.buckets {
		out = append(out, b)
	}
	return out, nil
}

func fl(v float64) *float64 { return &v }

const account, host = "123456789012", "gamevps"

var here = bucket.Name(account, host, "ap-south-1")

func inv(c cloud, st s3, scan storage.Everywhere) Inventory {
	rates := pricing.Rates{S3GBMonth: fl(0.025), EBSGBMonth: fl(0.0912), SnapshotGBMonth: fl(0.05), INRPerUSD: fl(100)}
	return Inventory{
		Cloud:  c,
		Lib:    library.Library{S3: st, Host: host, Region: "ap-south-1", Account: account, S3USD: rates.S3GBMonth, INR: rates.INRPerUSD},
		Prices: func(context.Context, string, string) *float64 { return fl(0.025) },
		Scan:   func(context.Context, []string) storage.Everywhere { return scan },
		Rates:  rates, Here: "ap-south-1", Expiry: 14,
	}
}

func emptyWorld() cloud {
	return cloud{account: account, regions: []string{"us-east-1", "ap-south-1"}}
}

func TestNothingIsLeft(t *testing.T) {
	r := inv(emptyWorld(), s3{buckets: map[string]string{}}, storage.Everywhere{}).Read(context.Background())
	if r.Error != nil || len(r.Items) != 0 || r.USDMonth == nil || *r.USDMonth != 0 || r.Hourly {
		t.Errorf("%+v", r)
	}
	if Show(r) != "  nothing of cg is left in AWS\n" {
		t.Errorf("%q", Show(r))
	}
}

func TestEverythingThatBills(t *testing.T) {
	c := emptyWorld()
	c.machines = map[string][]Machine{"ap-south-1": {{"i-1", "running", "g6.xlarge"}}, "us-east-1": {{"i-2", "stopped", "g4dn.xlarge"}}}
	c.watchdogs = map[string]bool{"ap-south-1": true}
	c.role, c.budget = true, true
	c.settings = map[string][]string{"ap-south-1": {"/cloud-gaming/gamevps/archive-last-seen"}}
	old := bucket.Name(account, host, "us-east-1")
	st := s3{buckets: map[string]string{here: "ap-south-1", old: "us-east-1"},
		lists: map[string][]library.Object{
			here: {{Key: "steam/steamapps/common/G/a", Size: 100 << 30}, {Key: "steam/account/steam-account.tgz", Size: 22000}},
			old:  {{Key: "steam/steamapps/common/H/a", Size: 50 << 30}}},
		index: map[string][]byte{here: []byte(`{"apps":[{"appid":1,"name":"G","installdir":"G","bytes":107374182400}]}`)}}
	scan := storage.Everywhere{Found: []storage.Found{
		{Region: "ap-south-1", Volumes: []costfacts.Volume{{ID: "vol-a", GB: 50}}},
		{Region: "us-east-1", Volumes: []costfacts.Volume{{ID: "vol-b", GB: 30}},
			Images:    []costfacts.Image{{ID: "ami-1", Snapshots: []costfacts.Snapshot{{ID: "s", GB: 40}}}},
			Snapshots: []costfacts.Snapshot{{ID: "sn", GB: 10}}}}}
	r := inv(c, st, scan).Read(context.Background())
	if r.Error != nil || !r.Hourly {
		t.Fatalf("%+v", r)
	}
	text := Show(r)
	for _, want := range []string{"Machine                g6.xlarge, running\n", "Machine                g4dn.xlarge, stopped in us-east-1\n",
		"Saved games            1 game, 100.0 GB and the saved Steam login\n", "Saved games elsewhere  1 game, 50.0 GB in us-east-1\n",
		"Leftover disks         2, 80 GB - in us-east-1\n", "Disk images            1, with their snapshots - in us-east-1\n",
		"Disk snapshots         1, 10 GB - in us-east-1\n", "Cloud watchdog         function, schedule, role, logs in ap-south-1\n",
		"Budget alert", "Game timers            1 setting in SSM\n"} {
		if !strings.Contains(text, want) {
			t.Errorf("lacks %q:\n%s", want, text)
		}
	}
	// Machines have no price here: the total is unknown, because one of its parts is.
	if r.USDMonth != nil {
		t.Errorf("a machine's cost is by the hour, so the month is unknown: %v", *r.USDMonth)
	}
	var games, disks Item
	for _, it := range r.Items {
		switch it.Kind {
		case "disks":
			disks = it
		case "games":
			if games.Label == "" {
				games = it
			}
		}
	}
	if *games.USDMonth != 2.5 || *disks.USDMonth != 7.3 || *games.Games != 1 {
		t.Errorf("%+v %+v", games, disks)
	}
	b, _ := json.Marshal(r)
	if !strings.Contains(string(b), `"hourly":true`) {
		t.Errorf("%s", b)
	}
}

func TestWhatCouldNotBeAskedIsSaid(t *testing.T) {
	c := emptyWorld()
	c.machFail = map[string]bool{"ap-south-1": true}
	st := s3{buckets: map[string]string{}}
	r := inv(c, st, storage.Everywhere{Failed: []string{"eu-west-1"}}).Read(context.Background())
	if r.Error == nil || *r.Error != "AWS could not be asked: machines, volumes" {
		t.Errorf("%v", r.Error)
	}
	if !strings.Contains(Show(r), "  AWS could not be asked: machines, volumes\n") {
		t.Errorf("%q", Show(r))
	}
	// A machine call that fails in a region that is NOT this one is not fatal.
	c = emptyWorld()
	c.machFail = map[string]bool{"us-east-1": true}
	if r := inv(c, st, storage.Everywhere{}).Read(context.Background()); r.Error != nil {
		t.Errorf("%v", *r.Error)
	}
	// No account, nothing else can be trusted.
	r = inv(cloud{}, st, storage.Everywhere{}).Read(context.Background())
	if r.Error == nil || *r.Error != "AWS could not be asked what is there" || len(r.Items) != 0 || r.USDMonth != nil {
		t.Errorf("%+v", r)
	}
}

func TestAnUnreadableOtherBucketIsAnError(t *testing.T) {
	old := bucket.Name(account, host, "us-east-1")
	st := s3{buckets: map[string]string{old: "us-east-1"}, listErr: map[string]error{old: errors.New("AccessDenied: no")}}
	r := inv(emptyWorld(), st, storage.Everywhere{}).Read(context.Background())
	if r.Error == nil || !strings.Contains(*r.Error, "elsewhere") {
		t.Errorf("a listing that failed is not an empty bucket: %+v", r)
	}
}
