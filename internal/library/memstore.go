package library

import (
	"context"
	"errors"
	"sort"
	"strings"
	"time"
)

// MemStore is S3 in memory, for tests of everything that changes the archive:
// bucket -> key -> bytes, with a region per bucket.
type MemStore struct {
	Objs    map[string]map[string][]byte
	Region  map[string]string
	FailDel map[string]bool // prefixes whose delete is refused
	FailPut bool
	FailCp  string
	Deleted []string
}

func NewMemStore() *MemStore {
	return &MemStore{Objs: map[string]map[string][]byte{}, Region: map[string]string{}}
}

func (m *MemStore) Add(b, region, key string, size int) {
	if m.Objs[b] == nil {
		m.Objs[b] = map[string][]byte{}
	}
	m.Region[b] = region
	m.Objs[b][key] = make([]byte, size)
}

func (m *MemStore) Get(_ context.Context, b, _, key string) ([]byte, error) {
	if v, ok := m.Objs[b][key]; ok {
		return v, nil
	}
	return nil, ErrNotFound
}
func (m *MemStore) Head(_ context.Context, b, _, key string) (Head, error) {
	if v, ok := m.Objs[b][key]; ok {
		return Head{Size: int64(len(v))}, nil
	}
	return Head{}, ErrNotFound
}
func (m *MemStore) List(_ context.Context, b, _, prefix string) ([]Object, error) {
	var out []Object
	for k, v := range m.Objs[b] {
		if strings.HasPrefix(k, prefix) {
			out = append(out, Object{Key: k, Size: int64(len(v)), Modified: time.Unix(0, 0)})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Key < out[j].Key })
	return out, nil
}
func (m *MemStore) Location(_ context.Context, b string) (string, error) {
	if r, ok := m.Region[b]; ok {
		return r, nil
	}
	return "", errors.New("NoSuchBucket")
}
func (m *MemStore) Buckets(context.Context) ([]string, error) { return nil, nil }
func (m *MemStore) Put(_ context.Context, b, _, key string, body []byte) error {
	if m.FailPut {
		return errors.New("AccessDenied")
	}
	if m.Objs[b] == nil {
		m.Objs[b] = map[string][]byte{}
	}
	m.Objs[b][key] = body
	return nil
}
func (m *MemStore) Delete(_ context.Context, b, _, key string) error {
	for p := range m.FailDel {
		if strings.HasPrefix(key, p) {
			return errors.New("AccessDenied")
		}
	}
	delete(m.Objs[b], key)
	m.Deleted = append(m.Deleted, key)
	return nil
}
func (m *MemStore) DeletePrefix(_ context.Context, b, _, prefix string) error {
	for p := range m.FailDel {
		if strings.HasPrefix(prefix, p) {
			return errors.New("AccessDenied")
		}
	}
	for k := range m.Objs[b] {
		if strings.HasPrefix(k, prefix) {
			delete(m.Objs[b], k)
		}
	}
	m.Deleted = append(m.Deleted, prefix)
	return nil
}
func (m *MemStore) Copy(_ context.Context, sb, _, db, dr, key string, _ int64) error {
	if m.FailCp != "" && strings.Contains(key, m.FailCp) {
		return errors.New("boom")
	}
	m.Add(db, dr, key, len(m.Objs[sb][key]))
	return nil
}
func (m *MemStore) DeleteBucket(_ context.Context, b, _ string) error {
	delete(m.Objs, b)
	delete(m.Region, b)
	return nil
}
