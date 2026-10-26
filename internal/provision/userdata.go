package provision

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"fmt"
	"io/fs"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/jebin2/aws_cloud_gaming/internal/render"
)

// UserDataLimit is what EC2 allows user-data to be, in bytes.
const UserDataLimit = 16384

// comment is a whole-line comment. Shebangs are exempt: `#!` lines matter inside
// the heredocs that write the on-host scripts.
var comment = regexp.MustCompile(`^[ \t\r\f\v]*#([^!]|$)`)

func stripComments(b []byte) []byte {
	var out []byte
	for _, line := range bytes.SplitAfter(b, []byte("\n")) {
		if len(line) == 0 || comment.Match(bytes.TrimSuffix(line, []byte("\n"))) {
			continue
		}
		out = append(out, line...)
	}
	return out
}

// HostBundle is host/ as a tarball, for the box to fetch: the on-host scripts and
// units, with whole-line comments stripped and the scripts made executable. The
// notification address rides in this bundle rather than in user-data: the bundle
// is a private object behind a two-hour presigned URL, and install-watchdog.sh
// turns the file into a root-only config. Absent is off.
//
// Comment-stripping matters here for the same reason as in the modules, and with
// one extra: base64 of a gzip is incompressible, so every byte of host/ would cost
// a full byte of the 16 KB budget. It goes to S3 and the box fetches it, rather
// than riding along inside user-data. It used to: 9,572 bytes of 16,384 - 58% -
// which left 68 bytes of headroom, not a budget but a tripwire.
func HostBundle(fsys fs.FS, ntfyURL string) ([]byte, error) {
	entries, err := fs.ReadDir(fsys, "host")
	if err != nil {
		return nil, err
	}
	var names []string
	for _, e := range entries {
		if !e.IsDir() {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	put := func(name string, mode int64, body []byte) error {
		if err := tw.WriteHeader(&tar.Header{Name: name, Mode: mode, Size: int64(len(body)), ModTime: time.Unix(0, 0)}); err != nil {
			return err
		}
		_, err := tw.Write(body)
		return err
	}
	for _, n := range names {
		b, err := fs.ReadFile(fsys, "host/"+n)
		if err != nil {
			return nil, err
		}
		b = stripComments(b)
		mode := int64(0o644)
		if strings.HasSuffix(n, ".sh") || n == "cg-library" || n == "cg-notify" {
			mode = 0o755
		}
		if err := put(n, mode, b); err != nil {
			return nil, err
		}
	}
	if ntfyURL != "" {
		if err := put("notify.url", 0o644, []byte(ntfyURL+"\n")); err != nil {
			return nil, err
		}
	}
	if err := tw.Close(); err != nil {
		return nil, err
	}
	if err := gz.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// UserData is the build, assembled and gzipped. EC2 caps user-data at 16 KB;
// cloud-init detects the gzip magic bytes and decompresses on its own, so shipping
// it compressed costs nothing and roughly quadruples the room available.
type UserData struct {
	Raw, Gzipped []byte
	Modules      int
}

// Assemble renders the modules with the values for an AWS box.
func Assemble(fsys fs.FS, vars map[string]string) (UserData, error) {
	s, err := render.Bootstrap(fsys, vars)
	if err != nil {
		return UserData{}, err
	}
	mods, _ := fs.Glob(fsys, render.Dir+"/*.sh")
	var buf bytes.Buffer
	gz, _ := gzip.NewWriterLevel(&buf, gzip.BestCompression)
	if _, err := gz.Write([]byte(s)); err != nil {
		return UserData{}, err
	}
	if err := gz.Close(); err != nil {
		return UserData{}, err
	}
	u := UserData{Raw: []byte(s), Gzipped: buf.Bytes(), Modules: len(mods)}
	if len(u.Gzipped) >= UserDataLimit {
		return u, fmt.Errorf("user-data still too large even gzipped")
	}
	return u, nil
}

// Uploader puts the host bundle where the box can fetch it.
type Uploader interface {
	Put(ctx context.Context, bucket, region, key string, body []byte) error
	Presign(ctx context.Context, bucket, region, key string, valid time.Duration) (string, error)
	List(ctx context.Context, bucket, region, prefix string) ([]Object, error)
}

// Object is the part of a listing this needs.
type Object struct{ Size int64 }

// CrossRegion is what to say when the archive is not where the box is. Said out
// loud, because it is money and it is invisible otherwise: every byte the box pulls
// from a bucket in another region is billed inter-region egress, and the game
// archive is the big one. archiveBytes < 0 means it could not be measured; price is
// AWS's per-GB price for data leaving the archive's region (nil: unknown), inr the
// rupee rate (nil: unknown). Measured, not remembered: this used to quote "INR
// 1,234 for a 163 GB library" - the size the archive happened to be the day it was
// written - which on an empty bucket is a bill for games that are not there.
func CrossRegion(bucketRegion, region string, archiveBytes int64, price, inr *float64) []string {
	out := []string{fmt.Sprintf("!! the archive is in %s but the box is in %s", bucketRegion, region)}
	txt := "a per-GB price"
	if price != nil {
		txt = fmt.Sprintf("$%g/GB", *price)
	}
	switch {
	case archiveBytes < 0:
		out = append(out, "   the box can read it, but every GB crossing regions is billed at",
			"   "+txt+". The size could not be read - cg library list shows it.")
	case archiveBytes < 1<<30:
		out = append(out, "   nothing is archived there yet, so nothing is being billed to cross",
			"   regions. Once games are pushed, every GB back is "+txt+".")
	default:
		out = append(out, "   the box can read it, but every GB crossing regions is billed at")
		gb := archiveBytes / (1 << 30)
		if price != nil && inr != nil {
			out = append(out, fmt.Sprintf("   %s - about INR %.0f for the %d GB in it now, each pull.", txt, float64(archiveBytes)/(1<<30)**price**inr, gb))
		} else {
			out = append(out, fmt.Sprintf("   %s, for the %d GB in it now, each pull.", txt, gb))
		}
	}
	return append(out, "   To keep everything in "+region+" instead, clear GAME_S3_BUCKET from .env",
		"   and let cg init make one there - the games in "+bucketRegion+" stay put.")
}
