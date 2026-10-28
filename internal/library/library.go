package library

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strconv"
	"strings"

	"github.com/jebin2/aws_cloud_gaming/internal/bucket"
)

// App is a game in the archive's index.
type App struct {
	AppID      any    `json:"appid"`
	Name       string `json:"name"`
	InstallDir string `json:"installdir"`
	Bytes      int64  `json:"bytes"`
	Pushed     string `json:"pushed"`
}

type index struct {
	Apps []App `json:"apps"`
}

// Library reads one rig's archive.
type Library struct {
	S3      Store
	Host    string
	Region  string // where the machine is built
	Account string // "" until known
	Bucket  string // GAME_S3_BUCKET; derived from the account when empty
	S3USD   *float64
	INR     *float64
}

// BucketName is the bucket in use: .env's, else the one cg derives for this
// account, host and region - the same function the creation script uses. It was
// required to be in .env, which made every library read fail until an init had
// written it, and clearing it to move region did exactly that.
func (l Library) BucketName() (string, bool) {
	if l.Bucket != "" {
		return l.Bucket, true
	}
	if l.Account == "" {
		return "", false
	}
	return bucket.Name(l.Account, l.Host, l.Region), true
}

// Ours reports whether a bucket is one cg made for this account and host: the
// name it derives for the bucket's own region, or the form it used before the
// region was in the hash. Never anything merely named like them.
func Ours(name, region, account, host string) bool {
	return name == bucket.Name(account, host, region) || name == bucket.NameNoRegion(account, host)
}

// Index reads steam/index.json from a bucket. A bucket we can read that holds no
// index really is an empty archive, and so is a bucket that is not there yet: it is
// made by the first cg init, and until then nothing can have been archived in it
// (the AWS CLI could not tell the two apart either - a HEAD answers 404 for both).
// Anything else is an error with its reason.
func (l Library) Index(ctx context.Context, b, region string) ([]App, error) {
	apps, _, err := l.IndexAt(ctx, b, region)
	return apps, err
}

// IndexAt is Index that also says when the bucket itself is not there, for a caller
// that must not take a name it guessed for evidence of an empty archive.
func (l Library) IndexAt(ctx context.Context, b, region string) (apps []App, bucketMissing bool, err error) {
	body, err := l.S3.Get(ctx, b, region, "steam/index.json")
	if err != nil {
		switch r := Reason(err, b); {
		case r == "missing":
			return []App{}, false, nil
		case strings.Contains(r, "does not exist") && strings.Contains(r, "the bucket"):
			return []App{}, true, nil
		default:
			return nil, false, fmt.Errorf("%s", r)
		}
	}
	var ix index
	if json.Unmarshal(body, &ix) != nil {
		return []App{}, false, nil
	}
	return ix.Apps, false, nil
}

// Orphan is a folder in the archive that the index does not know.
type Orphan struct {
	Bytes int64
	Name  string // "common/<dir>" or "compatdata/<appid>"
}

// Orphans finds objects the index does not know about.
//
// A push that dies leaves files with no manifest and no index entry - by design,
// so a half-uploaded game is never mistaken for a complete one. But nothing
// could then SEE them: `cg library list` read the index and reported an empty
// archive while 76 GB of a dead download sat there billing, and `forget` could
// not touch it because forget works off the index too.
func Orphans(objs []Object, apps []App) []Orphan {
	dirs, ids := map[string]bool{}, map[string]bool{}
	for _, a := range apps {
		dirs[a.InstallDir] = true
		ids[IDString(a.AppID)] = true
	}
	size := map[string]int64{}
	for _, o := range objs {
		parts := strings.Split(o.Key, "/") // steam/steamapps/<area>/<name>/...
		if len(parts) < 4 {
			continue
		}
		area, name := parts[2], parts[3]
		switch {
		case area == "common":
			if !dirs[name] {
				size["common/"+name] += o.Size
			}
		case area == "compatdata" || area == "shadercache":
			if !ids[name] {
				size[area+"/"+name] += o.Size
			}
		}
	}
	var out []Orphan
	for k, v := range size {
		out = append(out, Orphan{v, k})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Bytes != out[j].Bytes {
			return out[i].Bytes > out[j].Bytes
		}
		return out[i].Name < out[j].Name
	})
	return out
}

const gib = 1073741824.0

// IDString is an appid as text, whether the index wrote it as a number or a
// string.
func IDString(v any) string {
	switch x := v.(type) {
	case nil:
		return ""
	case string:
		return x
	case float64:
		return strconv.FormatFloat(x, 'f', -1, 64)
	}
	return fmt.Sprint(v)
}

func monthly(b int64, rate *float64) *float64 {
	if rate == nil {
		return nil
	}
	v := math.Round(float64(b)/gib**rate*100) / 100
	return &v
}

// Marks are the dates the cloud watchdog keeps in SSM: when a machine was last
// seen, and each game's Reset. Nil when they could not be read - which is not
// "no marks", and the app says it does not know the dates rather than invent them.
type Marks struct {
	LastSeen *string           `json:"last_seen"`
	Kept     map[string]string `json:"kept"`
}

// Game is one archived game, priced.
type Game struct {
	AppID      any      `json:"appid"`
	Name       string   `json:"name"`
	InstallDir string   `json:"installdir"`
	Bytes      int64    `json:"bytes"`
	Pushed     string   `json:"pushed"`
	USDMonth   *float64 `json:"usd_month"`
	// Kept is the Reset mark: the watchdog counts from the later of this and the
	// last machine.
	Kept *string `json:"kept"`
}

func games(apps []App, b string, marks *Marks, rate *float64) []Game {
	out := []Game{}
	for _, a := range apps {
		g := Game{a.AppID, a.Name, a.InstallDir, a.Bytes, a.Pushed, monthly(a.Bytes, rate), nil}
		if marks != nil {
			if v, ok := marks.Kept[b+"/"+IDString(a.AppID)]; ok {
				g.Kept = &v
			}
		}
		out = append(out, g)
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Bytes > out[j].Bytes })
	return out
}
