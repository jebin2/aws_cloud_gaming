package sweep

import (
	"encoding/json"
	"os"
	"path/filepath"
	"time"
)

// Store keeps the last sweep. The cache is a convenience only: every reader
// works when it is missing, and nothing waits on the write. The timestamp
// belongs IN the document, so a reader knows how old the answer is without
// asking the filesystem - the app shows it, and a stale score is worse than no
// score if nobody can tell.
type Store struct {
	Dir  string // XDG_CACHE_HOME/cg
	Name string // sweep.json
	Now  func() time.Time
}

func (s Store) path() string { return filepath.Join(s.Dir, s.Name) }

func (s Store) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

// Save stamps and remembers a fresh sweep. A fresh answer and a remembered one
// are the same shape - the app renders one function, not two. Silent on failure.
func (s Store) Save(r Result) Result {
	at := s.now().UTC().Format("2006-01-02T15:04:05Z")
	yes, zero := true, int64(0)
	r.ScannedAt, r.Cached, r.AgeSeconds = &at, &yes, &zero
	if b, err := json.Marshal(r); err == nil && os.MkdirAll(s.Dir, 0o755) == nil {
		tmp := s.path() + ".new"
		if os.WriteFile(tmp, append(b, '\n'), 0o644) == nil {
			_ = os.Rename(tmp, s.path())
		}
	}
	return r
}

// Cached is the last sweep with how old it is, or an empty answer saying there
// has not been one. It never scans: this is what an opening screen calls. A
// missing or unreadable cache is the empty answer with cached:false and no
// error; readable but invalid JSON is the empty answer with an error, not a hard
// failure; an old cache is not discarded - it is returned with its age and the
// app decides whether to rescan.
func (s Store) Cached() map[string]any {
	emptyAnswer := func(extra map[string]any) map[string]any {
		m := map[string]any{"cached": false, "regions": []any{}, "too_far": []any{}, "unreachable": []any{}}
		for k, v := range extra {
			m[k] = v
		}
		return m
	}
	b, err := os.ReadFile(s.path())
	if err != nil || len(b) == 0 {
		return emptyAnswer(map[string]any{"scanned_at": nil, "age_seconds": nil})
	}
	var d map[string]any
	if json.Unmarshal(b, &d) != nil {
		return emptyAnswer(map[string]any{"error": "the remembered scan could not be read"})
	}
	d["cached"] = true
	d["age_seconds"] = nil
	if st, err := os.Stat(s.path()); err == nil {
		d["age_seconds"] = int64(s.now().Sub(st.ModTime()).Seconds())
	}
	return d
}
