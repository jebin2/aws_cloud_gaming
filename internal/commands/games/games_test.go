package games

import (
	"context"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"

	"github.com/jebin2/aws_cloud_gaming/internal/library"
)

const GB = 1 << 30

func app(id, name string, flags, size, done, want, on, stage int64) string {
	return strings.Join([]string{"APP", id, name, i(flags), i(size), i(done), i(want), i(on), i(stage)}, "\t") + "\n"
}

func i(n int64) string {
	return strings.TrimSpace(strings.Replace(string(rune('0'+0)), "0", itoa(n), 1))
}

func itoa(n int64) string {
	if n == 0 {
		return "0"
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	return string(b)
}

func TestStates(t *testing.T) {
	for _, c := range []struct {
		flags   int64
		running bool
		want    string
	}{{4, false, "installed"}, {4, true, "RUNNING"}, {1024, false, "downloading"}, {512, false, "paused"}, {2, false, "update needed"},
		{32, false, "files missing"}, {128, false, "files corrupt"}, {1, false, "uninstalled"}, {0, false, "flags 0"}, {4 | 2, false, "update needed"}} {
		if got := State(c.flags, c.running); got != c.want {
			t.Errorf("%d: got %s want %s", c.flags, got, c.want)
		}
	}
}

func TestInstalledIncompleteAndArchived(t *testing.T) {
	raw := app("1", "Half Installed", 4, 100*GB, 40*GB, 0, 0, 0) +
		app("2", "Whole", 4, 20*GB, 20*GB, 0, 0, 0) +
		app("3", "Playing", 4, 10*GB, 10*GB, 0, 1, 0) +
		"DISK\t" + itoa(60*GB) + "\t" + itoa(190*GB) + "\nDL\t0\nRATE\t0\n"
	archived := []library.App{{AppID: "2", Name: "Whole", Bytes: 20 * GB}, {AppID: float64(9), Name: "Left In S3", Bytes: 30 * GB}}
	text := Render(ParseBox(raw), archived)
	for _, want := range []string{"GAME                         STATE               SIZE", "Half Installed", "installed        40.0 GB  INCOMPLETE - 40 GB of 100 GB on disk",
		"Whole                        installed        20.0 GB", "Playing                      RUNNING          10.0 GB", "Left In S3                   in S3 only       30.0 GB  cg init offers it",
		"disk   60 GB used, 190 GB free"} {
		if !strings.Contains(text, want) {
			t.Errorf("lacks %q:\n%s", want, text)
		}
	}
	// "Whole" is archived and installed: shown once, not also as "in S3 only".
	if strings.Count(text, "Whole") != 1 {
		t.Errorf("listed twice:\n%s", text)
	}
	if strings.Contains(text, "link") {
		t.Error("no rate, no link line")
	}
}

// Steam's own BytesDownloaded lags badly - it read 0.6 GB with 67 GB on disk - so
// progress comes from the disk.
func TestADownloadComesFromTheDisk(t *testing.T) {
	raw := app("5", "Big Game", 1024, 0, 40*GB, 0, 0, 100*GB) + "DISK\t" + itoa(80*GB) + "\t" + itoa(100*GB) + "\nDL\t" + itoa(10*GB) + "\nRATE\t12500000\n"
	text := Render(ParseBox(raw), nil)
	// 40 GB committed + 10 GB staged (one game is downloading), of 100 GB; 50 GB left at 12.5 MB/s.
	if !strings.Contains(text, "downloading      50.0 GB  50% of 100 GB, ~72 min left") || !strings.Contains(text, "link   100 Mbps inbound right now") {
		t.Errorf("%s", text)
	}
	// downloading/ is shared: with two games downloading it is attributed to neither.
	raw = app("5", "A", 1024, 0, 40*GB, 0, 0, 100*GB) + app("6", "B", 1024, 0, 10*GB, 0, 0, 100*GB) + "DL\t" + itoa(10*GB) + "\nRATE\t0\n"
	if text := Render(ParseBox(raw), nil); !strings.Contains(text, "40% of 100 GB") || strings.Contains(text, "min left") {
		t.Errorf("%s", text)
	}
}

func TestNothingAtAll(t *testing.T) {
	if got := Render(ParseBox(""), nil); got != "  no games installed, and nothing archived\n" {
		t.Errorf("%q", got)
	}
}

type volFake struct{ vols []ec2types.Volume }

func (f volFake) DescribeVolumes(context.Context, *ec2.DescribeVolumesInput, ...func(*ec2.Options)) (*ec2.DescribeVolumesOutput, error) {
	return &ec2.DescribeVolumesOutput{Volumes: f.vols}, nil
}

func fl(v float64) *float64 { return &v }

func TestTheLegacyVolume(t *testing.T) {
	if got := ShowVolume(nil, fl(0.0912), fl(100)); !strings.Contains(got, "no EBS game volume exists - nothing billing.") {
		t.Errorf("%s", got)
	}
	v, err := FindVolume(context.Background(), volFake{[]ec2types.Volume{{VolumeId: aws.String("vol-1"), AvailabilityZone: aws.String("ap-south-1a"), Size: aws.Int32(160), State: "available"}}}, "gamevps")
	if err != nil || v == nil || v.GB != 160 {
		t.Fatalf("%v %v", v, err)
	}
	text := ShowVolume(v, fl(0.0912), fl(100))
	for _, want := range []string{"  volume   vol-1  (available)", "  zone     ap-south-1a", "  size     160 GB", "  cost     $14.59/month (INR 1459) - billed whether or not the box exists",
		"cg games --volume --delete"} {
		if !strings.Contains(text, want) {
			t.Errorf("lacks %q:\n%s", want, text)
		}
	}
	if strings.Contains(text, "cg games --delete") {
		t.Error("the instruction must name a command that exists")
	}
	if text := ShowVolume(v, nil, nil); !strings.Contains(text, "cost     ? - the disk price could not be read from AWS") {
		t.Errorf("an unknown price is a question mark:\n%s", text)
	}
}
