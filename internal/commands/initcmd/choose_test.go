package initcmd

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/jebin2/ayis/internal/ask"
	"github.com/jebin2/ayis/internal/bucket"
	"github.com/jebin2/ayis/internal/config"
	"github.com/jebin2/ayis/internal/library"
	"github.com/jebin2/ayis/internal/output"
)

const archive = `{"apps":[{"appid":1091500,"name":"Cyberpunk 2077","bytes":107374182400,"pushed":"2026-10-01T10:11:12Z"},{"appid":2,"name":"Diablo IV","bytes":53687091200,"pushed":"2026-10-02T10:11:12Z"},{"appid":3,"name":"Hades","bytes":8589934592}]}`

type chooseRig struct {
	c       Chooser
	prompts *bytes.Buffer
	env     *config.Env
	store   *library.MemStore
}

func newChoose(t *testing.T, input string, tty bool, dotenv string) *chooseRig {
	dir := t.TempDir()
	_ = os.WriteFile(filepath.Join(dir, ".env"), []byte(dotenv), 0o600)
	env := config.Load(func(string) (string, bool) { return "", false }, dir)
	s := library.NewMemStore()
	b := bucket.Name("123", "ayis", "ap-south-1")
	s.Add(b, "ap-south-1", "steam/index.json", 0)
	s.Objs[b]["steam/index.json"] = []byte(archive)
	var o, e, p bytes.Buffer
	out := &output.Out{Stdout: &o, Stderr: &e}
	a := &ask.Asker{Out: out, In: bufio.NewReader(strings.NewReader(input)), Prompts: &p, TTY: tty}
	avail := 150.0
	return &chooseRig{c: Chooser{Lib: library.Library{S3: s, Host: "ayis", Region: "ap-south-1", Account: "123"}, Env: env, Out: out, Ask: a, AvailGB: &avail, ReserveGB: 20},
		prompts: &p, env: env, store: s}
}

func TestAnArchiveThatWasNeverMadeRestoresAllOfNothing(t *testing.T) {
	r := newChoose(t, "", true, "")
	r.store.Objs = map[string]map[string][]byte{}
	r.store.Region = map[string]string{}
	if got := r.c.Choose(context.Background()); got != "all" || r.env.Get("GAME_APPS") != "all" {
		t.Errorf("%q", got)
	}
	r = newChoose(t, "", true, "")
	_ = r.store.Put(context.Background(), bucket.Name("123", "ayis", "ap-south-1"), "ap-south-1", "steam/index.json", []byte(`{"apps":[]}`))
	if r.c.Choose(context.Background()) != "all" {
		t.Error("an index with no apps is nothing to ask about")
	}
}

type noBucket struct{ *library.MemStore }

func (noBucket) Get(context.Context, string, string, string) ([]byte, error) {
	return nil, errors.New("NoSuchBucket: the specified bucket does not exist")
}

type brokenStore struct{ *library.MemStore }

func (brokenStore) Get(context.Context, string, string, string) ([]byte, error) {
	return nil, errors.New("boom: the network went away")
}

func TestAGuessedBucketThatIsNotThereIsNotAnEmptyArchive(t *testing.T) {
	r := newChoose(t, "", true, "")
	r.c.Lib.S3 = noBucket{r.store}
	if got := r.c.Choose(context.Background()); got != "none" {
		t.Errorf("a guess that found nothing is not evidence: %q", got)
	}
	if !strings.Contains(r.prompts.String(), "no archive found at the derived name - restoring none") {
		t.Error(r.prompts.String())
	}
	// A bucket .env names is believed: it really is there, and the index is not.
	r = newChoose(t, "", true, "")
	r.c.Lib.S3 = noBucket{r.store}
	r.c.Lib.Bucket = "named-bucket"
	if got := r.c.Choose(context.Background()); got != "all" {
		t.Errorf("%q", got)
	}
	// An account that cannot be asked: none, never all.
	r = newChoose(t, "", true, "")
	r.c.Lib.Account = ""
	if got := r.c.Choose(context.Background()); got != "none" || !strings.Contains(r.prompts.String(), "could not tell which game archive to read") {
		t.Errorf("%q", got)
	}
}

func TestWithoutATerminalEnvDecidesAndNothingBlocks(t *testing.T) {
	r := newChoose(t, "", false, "GAME_APPS=2,3\n")
	if got := r.c.Choose(context.Background()); got != "2,3" || r.prompts.Len() != 0 {
		t.Errorf("%q %q", got, r.prompts)
	}
	r = newChoose(t, "", false, "")
	if got := r.c.Choose(context.Background()); got != "all" {
		t.Errorf("a human already chose once, and it is in .env; with nothing there it is all: %q", got)
	}
}

func TestEnterIsNoneAndNumbersOrAppidsPick(t *testing.T) {
	r := newChoose(t, "\n", true, "GAME_APPS=2\n")
	if got := r.c.Choose(context.Background()); got != "none" || r.env.Get("GAME_APPS") != "none" {
		t.Errorf("Enter must not start a 158 GB transfer: %q", got)
	}
	r = newChoose(t, "2, 3,2\n", true, "")
	if got := r.c.Choose(context.Background()); got != "2,3" {
		t.Errorf("numbers, deduplicated: %q", got)
	}
	r = newChoose(t, "1091500,3\n", true, "")
	if got := r.c.Choose(context.Background()); got != "1091500,3" || !strings.Contains(r.prompts.String(), "108 GB selected, 42 GB spare. Restoring: Cyberpunk 2077, Hades") {
		t.Errorf("%q\n%s", got, r.prompts)
	}
	r = newChoose(t, "ALL\n", true, "")
	if got := r.c.Choose(context.Background()); got != "1091500,2,3" {
		// all of it is 160 GB on a 150 GB disk: refused, then EOF falls back to what .env said.
		_ = got
	}
}

func TestMoreThanFitsAddsADiskAndSaysWhatItCosts(t *testing.T) {
	r := newChoose(t, "all\n", true, "")
	r.c.INRPerGBHour = 0.012
	if got := r.c.Choose(context.Background()); got != "1091500,2,3" {
		t.Fatalf("all of it is 158 GB on a 170 GB drive with 20 GB kept free: it is chosen, not refused: %q\n%s", got, r.prompts)
	}
	p := r.prompts.String()
	for _, want := range []string{"158 GB selected; 8 GB of it does not fit this machine's own drive (170 GB).", "A 30 GB disk will be added for those games (about Rs 0.4 an hour more)."} {
		if !strings.Contains(p, want) {
			t.Errorf("lacks %q in:\n%s", want, p)
		}
	}
	// The price is left out, not guessed, when the rates could not be read.
	r = newChoose(t, "all\n", true, "")
	r.c.Choose(context.Background())
	if strings.Contains(r.prompts.String(), "an hour more") {
		t.Errorf("no rate, no price: %s", r.prompts)
	}
	// A disk that could not be read refuses nothing: the box enforces the real limit.
	r = newChoose(t, "all\n", true, "")
	r.c.AvailGB = nil
	if got := r.c.Choose(context.Background()); got != "1091500,2,3" || !strings.Contains(r.prompts.String(), "the machine's space could not be read") {
		t.Errorf("%q", got)
	}
}

func TestMoreThanAGamePCCanHoldIsRefused(t *testing.T) {
	r := newChoose(t, "all\n3\n", true, "")
	small := 1.0 // 158 GB plus the reserve is over the ceiling; Hades alone is not
	r.c.AvailGB, r.c.ReserveGB = &small, 900
	if got := r.c.Choose(context.Background()); got != "3" {
		t.Fatalf("%q\n%s", got, r.prompts)
	}
	if !strings.Contains(r.prompts.String(), "more than a game PC here can hold (1000 GB)") {
		t.Errorf("%s", r.prompts)
	}
}

func TestNeedIsWhatTheChosenGamesTake(t *testing.T) {
	r := newChoose(t, "", true, "")
	for sel, want := range map[string]float64{"all": 158, "none": 0, "3": 8, "2,3": 58, "1091500, 2": 150, "999": 0} {
		if got, ok := r.c.Need(context.Background(), sel); !ok || got != want {
			t.Errorf("%q: %.0f ok=%v, want %.0f", sel, got, ok, want)
		}
	}
	r.c.Lib.S3 = brokenStore{r.store}
	if _, ok := r.c.Need(context.Background(), "all"); ok {
		t.Error("an archive that cannot be read is not sized on a guess")
	}
}

func TestAWrongWordIsSaidAndAskedAgainAndNoAnswerKeepsWhatWasThere(t *testing.T) {
	r := newChoose(t, "9\n,\nhades\n", true, "GAME_APPS=2\n")
	// Three tries, none good; the input ends: the previous choice stands, never "all".
	if got := r.c.Choose(context.Background()); got != "2" {
		t.Errorf("%q", got)
	}
	p := r.prompts.String()
	for _, want := range []string{"'9' is not one of the numbers or appids above", "nothing selected - type numbers, 'all', or 'none'", "'hades' is not one of the numbers or appids above", "no answer (input ended) - not guessing which games to restore"} {
		if !strings.Contains(p, want) {
			t.Errorf("lacks %q in:\n%s", want, p)
		}
	}
	// With nothing before it, no answer is none.
	r = newChoose(t, "", true, "")
	if got := r.c.Choose(context.Background()); got != "none" {
		t.Errorf("%q", got)
	}
}
