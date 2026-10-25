package hosts

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"time"
)

// Set puts fields on a machine, creating it if need be: read, change and replace
// under a lock, through a temp file of its own, mode 0600. Setup and a stream
// run beside other commands; two writers each reading the old file and
// replacing it lost one's change - a Sunshine password the machine had already
// been given, and every pairing after it failed.
func (s Store) Set(name string, kv ...string) error {
	return s.write(func(d map[string]Record) {
		r := d[name]
		if r == nil {
			r = Record{}
			d[name] = r
		}
		for i := 0; i+1 < len(kv); i += 2 {
			r[kv[i]] = kv[i+1]
		}
	})
}

// Forget takes a machine out of the file. A file that is not there stays not there.
func (s Store) Forget(name string) error {
	if _, err := os.Stat(s.Path); err != nil {
		return nil
	}
	return s.write(func(d map[string]Record) { delete(d, name) })
}

func (s Store) write(change func(map[string]Record)) error {
	dir := filepath.Dir(s.Path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	unlock, err := lock(s.Path + ".lock")
	if err != nil {
		return err
	}
	defer unlock()
	d := s.all()
	change(d)
	// Sorted keys and one-space indent, as the file has always been written.
	b, err := json.MarshalIndent(sortedMap(d), "", " ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".hosts.")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(b); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), s.Path)
}

// sortedMap marshals with sorted keys (encoding/json already sorts map keys).
func sortedMap(d map[string]Record) map[string]Record {
	for _, r := range d {
		keys := make([]string, 0, len(r))
		for k := range r {
			keys = append(keys, k)
		}
		sort.Strings(keys)
	}
	return d
}

// lock is an exclusive lock held by creating a file, which works wherever cg
// runs. One left behind by a crash is broken after half a minute.
func lock(path string) (func(), error) {
	deadline := time.Now().Add(10 * time.Second)
	for {
		f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
		if err == nil {
			f.Close()
			return func() { os.Remove(path) }, nil
		}
		if !errors.Is(err, os.ErrExist) {
			return nil, err
		}
		if st, err := os.Stat(path); err == nil && time.Since(st.ModTime()) > 30*time.Second {
			os.Remove(path)
			continue
		}
		if time.Now().After(deadline) {
			return nil, errors.New("hosts.json is locked by another cg")
		}
		time.Sleep(20 * time.Millisecond)
	}
}
