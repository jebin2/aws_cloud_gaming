package hosts

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

func TestSetAndForget(t *testing.T) {
	dir := t.TempDir()
	s := Store{Path: filepath.Join(dir, "cg", "hosts.json")}
	if err := s.Set("pc", "ssh", "me@pc", "os", "Linux"); err != nil {
		t.Fatal(err)
	}
	if err := s.Set("pc", "ready", "yes"); err != nil {
		t.Fatal(err)
	}
	if r := s.Get("pc"); r.Field("ssh") != "me@pc" || r.Field("ready") != "yes" {
		t.Errorf("a second write keeps the first: %v", r)
	}
	st, _ := os.Stat(s.Path)
	if st.Mode().Perm() != 0o600 {
		t.Errorf("it holds a Sunshine login: %v", st.Mode())
	}
	if _, err := os.Stat(s.Path + ".lock"); err == nil {
		t.Error("the lock is released")
	}
	if err := s.Forget("pc"); err != nil || len(s.Names()) != 0 {
		t.Errorf("%v %v", err, s.Names())
	}
	if err := (Store{Path: filepath.Join(dir, "none.json")}).Forget("x"); err != nil {
		t.Error("forgetting from a file that is not there is nothing")
	}
}

func TestTwoWritersBothLand(t *testing.T) {
	s := Store{Path: filepath.Join(t.TempDir(), "hosts.json")}
	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			if err := s.Set("pc", fmt.Sprintf("k%d", i), "v"); err != nil {
				t.Error(err)
			}
		}(i)
	}
	wg.Wait()
	if n := len(s.Get("pc")); n != 20 {
		t.Errorf("lost writes: %d of 20 fields", n)
	}
}
