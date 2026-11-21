package main

import (
	"errors"
	"path/filepath"
	"reflect"
	"sort"
	"testing"
)

type memoryIndex map[string]attachment

func (m memoryIndex) insert(a attachment, maxCount int, maxBytes int64) (bool, error) {
	used := a.Size
	for _, row := range m {
		used += row.Size
	}
	if len(m) >= maxCount || used > maxBytes {
		return false, nil
	}
	if _, exists := m[a.ID]; exists {
		return false, errors.New("duplicate ID")
	}
	m[a.ID] = a
	return true, nil
}

func (m memoryIndex) lookup(id string) (attachment, bool, error) {
	a, found := m[id]
	return a, found, nil
}

func (m memoryIndex) expired(at int64) ([]string, error) {
	var ids []string
	for _, a := range m {
		if a.Expires <= at {
			ids = append(ids, a.ID)
		}
	}
	return ids, nil
}

func (m memoryIndex) remove(id string) error {
	delete(m, id)
	return nil
}

func withIndexes(t *testing.T, spec func(*testing.T, attachmentIndex)) {
	t.Helper()
	t.Run("memory", func(t *testing.T) { spec(t, make(memoryIndex)) })
	t.Run("sqlite", func(t *testing.T) {
		s, err := openIndex(filepath.Join(t.TempDir(), "store.sqlite"))
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(s.close)
		spec(t, s)
	})
}

// Shared metadata contract for both the memory dummy and real SQLite adapter.
func TestAttachmentIndex(t *testing.T) {
	withIndexes(t, func(t *testing.T, s attachmentIndex) {
		a := attachment{"one", "photo's & more.jpg", "image/jpeg", 7, 32}
		b := attachment{"two", "demo.txt", "text/plain", 9, 30}
		c := attachment{"three", "empty.txt", "text/plain", 0, 31}
		for _, tc := range []struct {
			value attachment
			quota int64
			pass  bool
		}{{a, 16, true}, {b, 15, false}, {b, 16, true}, {c, 16, false}} {
			ok, err := s.insert(tc.value, 2, tc.quota)
			if ok != tc.pass || err != nil {
				t.Fatalf("insert %+v: %v, %v", tc, ok, err)
			}
		}
		if got, found, err := s.lookup(a.ID); got != a || !found || err != nil {
			t.Fatalf("got %+v, exists=%v, error=%v", got, found, err)
		}
		if _, found, err := s.lookup(c.ID); found || err != nil {
			t.Fatalf("rejected record exists=%v, error=%v", found, err)
		}
		got, err := s.expired(31)
		if err != nil || !reflect.DeepEqual(got, []string{b.ID}) {
			t.Fatalf("at second 31: %v, %v", got, err)
		}
		got, err = s.expired(32)
		sort.Strings(got)
		if err != nil || !reflect.DeepEqual(got, []string{a.ID, b.ID}) {
			t.Fatalf("at second 32: %v, %v", got, err)
		}
		if err := s.remove(b.ID); err != nil {
			t.Fatal(err)
		}
		if ok, err := s.insert(c, 2, 16); !ok || err != nil {
			t.Fatalf("should fit after remove: %v, %v", ok, err)
		}
	})
}

func TestSQLitePersistence(t *testing.T) {
	path := filepath.Join(t.TempDir(), "store.sqlite")
	s, err := openIndex(path)
	if err != nil {
		t.Fatal(err)
	}
	a := attachment{"file", "café 🌍.bin", "application/octet-stream", 255, 1000}
	ok, err := s.insert(a, 1, 255)
	s.close()
	if !ok || err != nil {
		t.Fatalf("insert: %v, %v", ok, err)
	}
	s, err = openIndex(path)
	if err != nil {
		t.Fatal(err)
	}
	defer s.close()
	if got, found, err := s.lookup(a.ID); got != a || !found || err != nil {
		t.Fatalf("got %+v, exists=%v, error=%v", got, found, err)
	}
}
