package games

import (
	"context"
	"encoding/json"
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

// Steam fetches Proton, its runtime and the redistributables beside every game,
// so several apps are "downloading" at once. downloading/ is one folder with a
// folder per app in it: each game is credited its own, not nothing because
// something else was downloading too.
func TestEachGetsItsOwnStagedBytesWhateverElseDownloads(t *testing.T) {
	line := func(id, name string, stage, staged int64) string {
		return strings.Join([]string{"APP", id, name, "1024", "0", "0", "0", "0", itoa(stage), itoa(staged)}, "\t") + "\n"
	}
	raw := line("1493710", "Proton Experimental", 1*GB, 1*GB) + line("228980", "Steamworks Common Redistributables", 100<<20, 50<<20) +
		line("632470", "Disco Elysium", 12*GB, 3*GB) + "DL\t" + itoa(4*GB+50<<20) + "\nRATE\t10000000\n"
	b := ParseBox(raw)
	rows := rowsOf(b, nil)
	got := map[string]float64{}
	for _, r := range rows {
		got[r.full] = r.pct
	}
	if got["Disco Elysium"] < 24.9 || got["Disco Elysium"] > 25.1 {
		t.Errorf("Disco Elysium has 3 of 12 GB staged: %v", got)
	}
	if got["Proton Experimental"] < 99.9 {
		t.Errorf("Proton has all of its 1 GB staged: %v", got)
	}
	if got["Steamworks Common Redistributables"] < 49 || got["Steamworks Common Redistributables"] > 51 {
		t.Errorf("the redistributables have half: %v", got)
	}
	// A box that cannot say per game (an older script) keeps the shared rule.
	old := app("632470", "Disco Elysium", 1024, 0, 0, 0, 0, 12*GB) + app("1493710", "Proton Experimental", 1024, 0, 0, 0, 0, 1*GB) + "DL\t" + itoa(3*GB) + "\n"
	for _, r := range rowsOf(ParseBox(old), nil) {
		if r.full == "Disco Elysium" && r.pct != 0 {
			t.Errorf("two download and nothing says whose it is: %v", r.pct)
		}
	}
}

// Measured on a live box: at one moment Steam's window said 61%, the space used
// on disk said 62%, the apparent size 69% (Steam reserves a file's whole size
// before it has the bytes) and Steam's manifest 50% (it is written in bursts and
// stood still for 40 s). The disk, as space used, is the progress; the manifest is
// only for a download with nothing staged.
func TestProgressIsTheSpaceUsedOnDiskNotSteamsLaggingManifest(t *testing.T) {
	line := func(want, got, stage, staged, done int64) string {
		return strings.Join([]string{"APP", "632470", "Disco Elysium", "1024", "0", itoa(done), itoa(want), "0", itoa(stage), itoa(staged), itoa(got)}, "\t") + "\n"
	}
	stage := int64(10287338728)
	want := int64(9342155632)
	b := ParseBox(line(want, 4665553296, stage, stage*62/100, 0) + "RATE\t10000000\n")
	rows := rowsOf(b, nil)
	if len(rows) != 1 || rows[0].pct < 61.9 || rows[0].pct > 62.1 {
		t.Fatalf("the disk's 62%%, not the manifest's 50%%: %+v", rows)
	}
	if rows[0].total != stage {
		t.Errorf("the whole is the install size: %+v", rows[0])
	}
	// The rate is in compressed bytes over the wire: the time left scales to them.
	left := float64(stage) * 0.38
	wire := left * float64(want) / float64(stage)
	wantMin := wire / 10000000 / 60
	if rows[0].eta < wantMin*0.99 || rows[0].eta > wantMin*1.01 {
		t.Errorf("time left %.1f min, want %.1f (wire bytes)", rows[0].eta, wantMin)
	}
	// Nothing staged to measure: Steam's own figures are used, clamped to the whole.
	if r := rowsOf(ParseBox(line(12*GB, 72*GB/100, 0, 0, 0)), nil); len(r) != 1 || r[0].pct < 5.9 || r[0].pct > 6.1 {
		t.Errorf("the manifest is the fallback: %+v", r)
	}
	if r := rowsOf(ParseBox(line(12*GB, 13*GB, 0, 0, 0)), nil); r[0].pct != 100 {
		t.Errorf("clamped: %v", r[0].pct)
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

func TestJSONHasTheSameGamesAndTheNumbersTheWordsAreMadeFrom(t *testing.T) {
	b := Box{Apps: []App{{ID: "1", Name: "Diablo IV", Flags: 1024, Size: 0, Done: 10 << 30, Stage: 40 << 30, Want: 40 << 30}, {ID: "2", Name: "Half", Flags: 4, Size: 100 << 30, Done: 10 << 30}},
		Rate: 10_000_000, HasDisk: true, Used: 5 << 30, Avail: 95 << 30}
	raw, err := JSON(b, []library.App{{AppID: "3", Name: "Archived", Bytes: 7 << 30}})
	if err != nil {
		t.Fatal(err)
	}
	var d struct {
		Games []struct {
			AppID, Name, State string
			Bytes              int64
			MinutesLeft        *float64 `json:"minutes_left"`
			Incomplete         bool
			TotalBytes         int64 `json:"total_bytes"`
			LeftBytes          int64 `json:"left_bytes"`
		}
		Disk map[string]int64
	}
	if err := json.Unmarshal(raw, &d); err != nil {
		t.Fatal(err)
	}
	// A download says its whole size and what is left of it (40 GB, 10 on disk), so
	// the app can say how much room it still needs; a game that is not downloading
	// says neither.
	if d.Games[0].TotalBytes != 40<<30 || d.Games[0].LeftBytes != 30<<30 || d.Games[1].TotalBytes != 0 || d.Games[1].LeftBytes != 0 {
		t.Errorf("total and left: %s", raw)
	}
	if len(d.Games) != 3 || d.Games[0].State != "downloading" || d.Games[0].MinutesLeft == nil || !d.Games[1].Incomplete || d.Games[2].State != "in S3 only" || d.Games[2].Bytes != 7<<30 || d.Disk["free_bytes"] != 95<<30 {
		t.Errorf("%s", raw)
	}
	// The table and the JSON are made from the same rows.
	if !strings.Contains(Render(b, nil), "downloading") {
		t.Error("table")
	}
}

func TestWhereEachGameIsInstalled(t *testing.T) {
	line := func(id, disk string) string {
		f := []string{"APP", id, "G" + id, "4", "100", "100", "0", "0", "0", "0", "0"}
		if disk != "" {
			f = append(f, disk)
		}
		return strings.Join(f, "\t") + "\n"
	}
	b := ParseBox(line("1", "nvme") + line("2", "extra") + line("3", "root") + line("4", ""))
	var got []string
	for _, a := range b.Apps {
		got = append(got, a.Disk)
	}
	if strings.Join(got, ",") != "nvme,extra,root," {
		t.Fatalf("disks %v", got)
	}
	out, err := JSON(b, nil)
	if err != nil {
		t.Fatal(err)
	}
	s := string(out)
	for _, w := range []string{`"disk":"nvme"`, `"disk":"extra"`, `"disk":"root"`} {
		if !strings.Contains(s, w) {
			t.Errorf("JSON lacks %s: %s", w, s)
		}
	}
	// An older box does not say: the field is left out, not guessed.
	if strings.Count(s, `"disk":"`) != 3 {
		t.Errorf("a game of unknown place got one: %s", s)
	}
}

// Steam's own tools are never saved, so they are named as tools; games are not.
func TestSteamToolsAreToldApart(t *testing.T) {
	for _, c := range []struct {
		id, name string
		want     bool
	}{
		{"1493710", "Proton Experimental", true},
		{"2348590", "Proton 9.0", true},
		{"1628350", "Steam Linux Runtime 3.0 (sniper)", true},
		{"228980", "Steamworks Common Redistributables", true},
		{"1826330", "Proton EasyAntiCheat Runtime", true},
		{"9", "ProtonHunter", false},
		{"2863680", "ZERO PARADES: Director's Cut", false},
	} {
		if got := IsSteamTool(c.id, c.name); got != c.want {
			t.Errorf("%s %q: %v", c.id, c.name, got)
		}
	}
}
