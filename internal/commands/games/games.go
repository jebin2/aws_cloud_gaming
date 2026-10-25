// Package games is `cg games`: what Steam has on the box - installed,
// downloading, running, archived - and the old EBS volume if you still have one.
package games

import (
	"context"
	"fmt"
	"strconv"
	"strings"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"

	"github.com/jebin2/aws_cloud_gaming/internal/library"
)

const gib = 1073741824.0

// App is a game as the box's manifests describe it.
type App struct {
	ID, Name                string
	Flags, Size, Done, Want int64
	Running                 bool
	Stage                   int64
}

// Box is what the remote script printed.
type Box struct {
	Apps    []App
	Used    int64
	Avail   int64
	HasDisk bool
	Staging int64
	Rate    int64 // bytes a second, inbound, right now
}

func atoi(s string) int64 {
	n, _ := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
	return n
}

// ParseBox reads the script's output.
func ParseBox(raw string) Box {
	var b Box
	for _, line := range strings.Split(raw, "\n") {
		f := strings.Split(line, "\t")
		switch {
		case f[0] == "APP" && len(f) >= 9:
			b.Apps = append(b.Apps, App{ID: f[1], Name: f[2], Flags: atoi(f[3]), Size: atoi(f[4]), Done: atoi(f[5]), Want: atoi(f[6]), Running: f[7] == "1", Stage: atoi(f[8])})
		case f[0] == "DISK" && len(f) >= 3:
			b.Used, b.Avail, b.HasDisk = atoi(f[1]), atoi(f[2]), true
		case f[0] == "DL" && len(f) >= 2:
			b.Staging = atoi(f[1])
		case f[0] == "RATE" && len(f) >= 2:
			b.Rate = atoi(f[1])
		}
	}
	return b
}

// State is Steam's StateFlags in words.
func State(flags int64, running bool) string {
	switch {
	case running:
		return "RUNNING"
	case flags&1024 != 0:
		return "downloading"
	case flags&512 != 0:
		return "paused"
	case flags&2 != 0:
		return "update needed"
	case flags&32 != 0:
		return "files missing"
	case flags&128 != 0:
		return "files corrupt"
	case flags&4 != 0:
		return "installed"
	case flags&1 != 0:
		return "uninstalled"
	}
	return fmt.Sprintf("flags %d", flags)
}

type row struct {
	name, state string
	gb          float64
	extra       string
}

// Render is the table. archived is the index: games saved in S3.
func Render(b Box, archived []library.App) string {
	arch := map[string]library.App{}
	var order []string
	for _, a := range archived {
		id := library.IDString(a.AppID)
		if _, ok := arch[id]; !ok {
			order = append(order, id)
		}
		arch[id] = a
	}
	downloading := 0
	for _, a := range b.Apps {
		if a.Flags&1024 != 0 {
			downloading++
		}
	}
	var rows []row
	for _, a := range b.Apps {
		st := State(a.Flags, a.Running)
		extra := ""
		var shown float64
		if st == "downloading" && a.Stage > 0 {
			// Steam's own BytesDownloaded lags badly - it read 0.6 GB with 67 GB on
			// disk - so progress comes from the DISK: what is committed plus what is
			// staged in downloading/, against BytesToStage. downloading/ is shared,
			// so only attribute it when one game is using it.
			onDisk := float64(a.Done)
			if downloading == 1 {
				onDisk += float64(b.Staging)
			}
			pct := min(100.0, 100.0*onDisk/float64(a.Stage))
			left := max(0.0, float64(a.Stage)-onDisk)
			extra = fmt.Sprintf("%.0f%% of %.0f GB", pct, float64(a.Stage)/gib)
			if b.Rate > 1_000_000 {
				extra += fmt.Sprintf(", ~%.0f min left", left/float64(b.Rate)/60)
			}
			shown = onDisk
		} else {
			shown = float64(a.Size)
			if a.Size == 0 {
				shown = float64(a.Done)
			}
			// The manifest is one small file. A restore that copies it and then
			// runs out of room leaves a game that CLAIMS to be installed at full
			// size with most of its bytes missing - so trust the disk, not the
			// manifest.
			if a.Size != 0 && a.Done != 0 && float64(a.Done) < float64(a.Size)*0.95 {
				shown = float64(a.Done)
				extra = fmt.Sprintf("INCOMPLETE - %.0f GB of %.0f GB on disk", float64(a.Done)/gib, float64(a.Size)/gib)
			}
		}
		rows = append(rows, row{clip(a.Name, 28), st, shown / gib, extra})
		delete(arch, a.ID)
	}
	for _, id := range order {
		if a, ok := arch[id]; ok {
			name := a.Name
			if name == "" {
				name = "?"
			}
			rows = append(rows, row{clip(name, 28), "in S3 only", float64(a.Bytes) / gib, "cg init offers it"})
			delete(arch, id)
		}
	}
	var w strings.Builder
	if len(rows) == 0 {
		w.WriteString("  no games installed, and nothing archived\n")
	} else {
		fmt.Fprintf(&w, "  %-28s %-14s %9s  %s\n", "GAME", "STATE", "SIZE", "")
		for _, r := range rows {
			fmt.Fprintf(&w, "  %-28s %-14s %6.1f GB  %s\n", r.name, r.state, r.gb, r.extra)
		}
	}
	if b.HasDisk {
		fmt.Fprintf(&w, "\n  disk   %.0f GB used, %.0f GB free\n", float64(b.Used)/gib, float64(b.Avail)/gib)
		if b.Rate > 100_000 {
			fmt.Fprintf(&w, "  link   %.0f Mbps inbound right now\n", float64(b.Rate)*8/1e6)
		}
	}
	return w.String()
}

func clip(s string, n int) string {
	r := []rune(s)
	if len(r) > n {
		return string(r[:n])
	}
	return s
}

// Volume is the old EBS games volume.
type Volume struct {
	ID, AZ, State string
	GB            int32
}

// FindVolume looks for it by name; nil when there is none.
func FindVolume(ctx context.Context, c interface {
	DescribeVolumes(context.Context, *ec2.DescribeVolumesInput, ...func(*ec2.Options)) (*ec2.DescribeVolumesOutput, error)
}, host string) (*Volume, error) {
	o, err := c.DescribeVolumes(ctx, &ec2.DescribeVolumesInput{Filters: []ec2types.Filter{{Name: aws.String("tag:Name"), Values: []string{host + "-games"}}}})
	if err != nil {
		return nil, err
	}
	if len(o.Volumes) == 0 {
		return nil, nil
	}
	v := o.Volumes[0]
	return &Volume{aws.ToString(v.VolumeId), aws.ToString(v.AvailabilityZone), string(v.State), aws.ToInt32(v.Size)}, nil
}

// ShowVolume is `cg games --volume`: legacy, and the only thing worth saying is
// that it still bills. Delete is a separate port, and the command it names is
// one that exists (the Bash named `cg games --delete`, which does not).
func ShowVolume(v *Volume, ebs, inr *float64) string {
	if v == nil {
		return "no EBS game volume exists - nothing billing.\nthe game library lives in S3 now: cg library\n"
	}
	var b strings.Builder
	fmt.Fprintf(&b, "  volume   %s  (%s)\n", v.ID, v.State)
	fmt.Fprintf(&b, "  zone     %s\n", v.AZ)
	fmt.Fprintf(&b, "  size     %d GB\n", v.GB)
	if ebs != nil {
		m := float64(v.GB) * *ebs
		rupees := "?"
		if inr != nil {
			rupees = fmt.Sprintf("%.0f", m**inr)
		}
		fmt.Fprintf(&b, "  cost     $%.2f/month (INR %s) - billed whether or not the box exists\n", m, rupees)
	} else {
		b.WriteString("  cost     ? - the disk price could not be read from AWS\n")
	}
	b.WriteString("  status   LEGACY - nothing mounts or attaches this any more.\n")
	b.WriteString("           the library is in S3: cg library\n")
	b.WriteString("  delete   cg games --volume --delete   (permanent; anything left on it goes too)\n")
	return b.String()
}
