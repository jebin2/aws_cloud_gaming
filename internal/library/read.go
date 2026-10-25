package library

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"io"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// Params reads the watchdog's marks from SSM, free.
type Params interface {
	// Path returns name -> value for every parameter under the path, recursively.
	Path(ctx context.Context, path string) (map[string]string, error)
}

// ReadMarks reads the marks, nil when they could not be read.
func ReadMarks(ctx context.Context, p Params, host string) *Marks {
	if p == nil {
		return nil
	}
	prefix := "/cloud-gaming/" + host + "/"
	all, err := p.Path(ctx, prefix)
	if err != nil {
		return nil
	}
	m := &Marks{Kept: map[string]string{}}
	for name, v := range all {
		rest := strings.TrimPrefix(name, prefix)
		switch {
		case rest == "archive-last-seen":
			val := v
			m.LastSeen = &val
		case strings.HasPrefix(rest, "kept/"):
			m.Kept[strings.TrimPrefix(rest, "kept/")] = v
		}
	}
	return m
}

// AccountKey is the archived Steam login: a ~22 KB tarball that is what makes a
// rebuilt box come up already signed in. It was invisible on every screen while
// being counted as a game, which is how an archive with no games reported 22 KB
// of games.
const AccountKey = "steam/account/steam-account.tgz"

// SteamAccount is one account inside the login.
type SteamAccount struct {
	SteamID    string  `json:"steamid"`
	Account    *string `json:"account"`
	Persona    *string `json:"persona"`
	MostRecent bool    `json:"most_recent"`
	LastUsed   *int64  `json:"last_used"`
}

// Login is `cg library account --json`.
type Login struct {
	Bucket   *string
	Key      string
	Present  bool
	Bytes    *int64
	Modified *string
	USDMonth *float64
	// Accounts is null when the names could not be read, NOT "no accounts" - the
	// archive cannot exist with nobody in it, so an empty list would be a lie.
	Accounts *[]SteamAccount
}

// MarshalJSON: with no login archived there is a bucket, present:false and an
// empty list - and none of the rest.
func (l Login) MarshalJSON() ([]byte, error) {
	if !l.Present {
		return json.Marshal(map[string]any{"bucket": l.Bucket, "present": false, "accounts": []SteamAccount{}})
	}
	return json.Marshal(map[string]any{"bucket": l.Bucket, "key": l.Key, "present": true, "bytes": l.Bytes,
		"modified": l.Modified, "usd_month": l.USDMonth, "accounts": l.Accounts})
}

var (
	userBlock = regexp.MustCompile(`(?s)"(\d{6,})"\s*\{(.*?)\}`)
	kvPair    = regexp.MustCompile(`"([^"]+)"\s+"([^"]*)"`)
)

// ParseLoginUsers reads loginusers.vdf, Valve KeyValues: a "users" block, one
// nested block per account keyed by steamid. Parsed with a scanner rather than a
// regex per field so two accounts cannot have their fields crossed.
func ParseLoginUsers(vdf string) []SteamAccount {
	var rows []SteamAccount
	for _, m := range userBlock.FindAllStringSubmatch(vdf, -1) {
		f := map[string]string{}
		for _, kv := range kvPair.FindAllStringSubmatch(m[2], -1) {
			f[kv[1]] = kv[2]
		}
		a := SteamAccount{SteamID: m[1], MostRecent: f["MostRecent"] == "1"}
		if v := f["AccountName"]; v != "" {
			a.Account = &v
		}
		if v := f["PersonaName"]; v != "" {
			a.Persona = &v
		}
		if n, err := strconv.ParseInt(f["Timestamp"], 10, 64); err == nil {
			a.LastUsed = &n
		}
		rows = append(rows, a)
	}
	// Most recent first, then by timestamp: the one a new box would land on is
	// the one worth reading first.
	sort.SliceStable(rows, func(i, j int) bool {
		if rows[i].MostRecent != rows[j].MostRecent {
			return rows[i].MostRecent
		}
		var a, b int64
		if rows[i].LastUsed != nil {
			a = *rows[i].LastUsed
		}
		if rows[j].LastUsed != nil {
			b = *rows[j].LastUsed
		}
		return a > b
	})
	// Steam writes MostRecent only when there is a choice to record. With exactly
	// one archived account that key is absent, and leaving the row unmarked
	// implied a new box would sign in as nobody - when that one account is
	// precisely what it signs in as.
	if len(rows) == 1 {
		rows[0].MostRecent = true
	}
	return rows
}

// loginUsers finds loginusers.vdf in the tarball, and nothing else: ssfn files
// and userdata are none of this function's business.
func loginUsers(tgz []byte) (string, bool) {
	zr, err := gzip.NewReader(bytes.NewReader(tgz))
	if err != nil {
		return "", false
	}
	tr := tar.NewReader(zr)
	for {
		h, err := tr.Next()
		if err != nil {
			return "", false
		}
		if h.Typeflag == tar.TypeReg && strings.HasSuffix(h.Name, "loginusers.vdf") {
			b, err := io.ReadAll(io.LimitReader(tr, 1<<20))
			return string(b), err == nil
		}
	}
}

// AccountAt reads the archived login in a bucket. The names live in the tarball,
// so it takes the object itself - 22 KB, one GET.
func (l Library) AccountAt(ctx context.Context, b, region string, cache NamesCache) Login {
	bp := b
	login := Login{Bucket: &bp}
	h, err := l.S3.Head(ctx, b, region, AccountKey)
	if err != nil {
		return login // none archived, as far as can be told
	}
	login.Present, login.Key = true, AccountKey
	login.Bytes, login.Modified = &h.Size, ptr(h.Modified.UTC().Format("2006-01-02T15:04:05+00:00"))
	if l.S3USD != nil {
		v := float64(h.Size) / gib * *l.S3USD
		login.USDMonth = &v
	}
	tag := strings.Trim(h.ETag, `"`)
	if cache != nil {
		if rows, ok := cache.Get(tag); ok {
			login.Accounts = &rows
			return login
		}
	}
	if body, err := l.S3.Get(ctx, b, region, AccountKey); err == nil {
		if vdf, ok := loginUsers(body); ok {
			if rows := ParseLoginUsers(vdf); len(rows) > 0 {
				login.Accounts = &rows
				if cache != nil {
					cache.Put(tag, rows)
				}
			}
		}
	}
	return login
}

// NamesCache remembers the accounts against the object's ETag rather than a
// clock: the blob changes only when a push replaces it, and then the ETag changes
// with it, so the cache can never be stale.
type NamesCache interface {
	Get(etag string) ([]SteamAccount, bool)
	Put(etag string, rows []SteamAccount)
}

func ptr[T any](v T) *T { return &v }
