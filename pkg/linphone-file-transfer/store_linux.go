package main

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	maxAttachments = 4096
	quotaMultiple  = 128
	stagingPrefix  = ".linphone-upload-"
)

// PHP used uniqid (13 hex digits), an underscore, 10 random bytes in hex,
// and a lowercased extension (possibly empty, or with a safety .txt suffix).
var attachmentID = regexp.MustCompile(`^[0-9a-f]{13}_[0-9a-f]{20}\.(?:[a-z0-9_-]{1,32}(?:\.txt)?)?$`)
var errQuota = errors.New("attachment storage full")
var errStorage = errors.New("attachment storage operation failed")

type attachmentStore struct {
	root      *os.Root
	dir       *os.File // Also holds this daemon's exclusive flock.
	index     attachmentIndex
	retention time.Duration
	quota     int64

	// Publishing and cleanup touch both the index and the filesystem. Keep
	// such operations serialized with opens, but not with file/body streaming.
	mu     sync.Mutex
	active map[string]struct{}
}

func openStore(path string, index attachmentIndex, retention time.Duration, quota int64) (*attachmentStore, error) {
	root, err := os.OpenRoot(path)
	if err != nil {
		return nil, errStorage
	}
	dir, err := root.Open(".")
	if err != nil {
		root.Close()
		return nil, errStorage
	}
	if syscall.Flock(int(dir.Fd()), syscall.LOCK_EX|syscall.LOCK_NB) != nil {
		dir.Close()
		root.Close()
		return nil, errors.New("could not lock attachment storage; another server may be using it")
	}
	return &attachmentStore{root: root, dir: dir, index: index, retention: retention, quota: quota, active: make(map[string]struct{})}, nil
}

func (s *attachmentStore) close() {
	s.root.Close()
	s.dir.Close()
}

func (s *attachmentStore) prepare(now time.Time) (string, *os.File, error) {
	var random [10]byte
	rand.Read(random[:])
	// Always use an inert extension for legacy PHP rollback. The descriptor
	// carries the actual client-facing filename and media type.
	id := fmt.Sprintf("%013x_%x.bin", uint64(now.UnixMicro())&((1<<52)-1), random)
	s.mu.Lock()
	defer s.mu.Unlock()
	f, err := s.root.OpenFile(stagingPrefix+id, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err == nil {
		s.active[id] = struct{}{}
	}
	return id, f, err
}

func (s *attachmentStore) abort(id string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	_ = s.root.Remove(stagingPrefix + id)
	delete(s.active, id)
}

func (s *attachmentStore) publish(a attachment) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	// Keep the prepared directory entry durable before recording metadata,
	// so startup can reconcile it if publication is interrupted.
	if s.dir.Sync() != nil {
		return errStorage
	}
	inserted, err := s.index.insert(a, maxAttachments, s.quota)
	if err != nil {
		return err
	}
	if !inserted {
		return errQuota
	}
	// Persist metadata before exposing the final basename: a crash before
	// publication must not accidentally turn an incomplete file into legacy
	// content. Link is atomic and never replaces an existing file.
	if err := s.root.Link(stagingPrefix+a.ID, a.ID); err != nil {
		_ = s.index.remove(a.ID)
		return errStorage
	}
	if err := s.root.Remove(stagingPrefix + a.ID); err != nil || s.dir.Sync() != nil {
		if s.root.Remove(a.ID) == nil && s.dir.Sync() == nil {
			_ = s.index.remove(a.ID)
		}
		return errStorage
	}
	return nil
}

func (s *attachmentStore) download(id string, now time.Time) (*os.File, os.FileInfo, error) {
	if !attachmentID.MatchString(id) {
		return nil, nil, os.ErrNotExist
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	a, tracked, err := s.index.lookup(id)
	if err != nil {
		return nil, nil, err
	}
	if tracked && now.Unix() >= a.Expires {
		return nil, nil, os.ErrNotExist
	}
	f, info, err := s.openRegular(id)
	if err != nil {
		return nil, nil, err
	}
	if tracked && a.Size != info.Size() || !tracked && !now.Before(info.ModTime().Add(s.retention)) {
		f.Close()
		return nil, nil, os.ErrNotExist
	}
	return f, info, nil
}

func (s *attachmentStore) openRegular(id string) (*os.File, os.FileInfo, error) {
	// os.Root confines name resolution; O_NOFOLLOW excludes even symlinks
	// that stay inside the directory. O_NONBLOCK avoids blocking on FIFOs.
	f, err := s.root.OpenFile(id, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) || errors.Is(err, syscall.ELOOP) || errors.Is(err, syscall.ENXIO) {
			return nil, nil, os.ErrNotExist
		}
		return nil, nil, errStorage
	}
	info, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, nil, errStorage
	}
	if !info.Mode().IsRegular() || info.Sys().(*syscall.Stat_t).Nlink != 1 {
		f.Close()
		return nil, nil, os.ErrNotExist
	}
	return f, info, nil
}

func (s *attachmentStore) pruneTracked(id string) error {
	if !attachmentID.MatchString(id) {
		return errStorage
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	info, err := s.root.Lstat(id)
	if err == nil {
		if !info.Mode().IsRegular() {
			return errStorage
		}
		err = s.root.Remove(id)
	}
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return errStorage
	}
	// Never drop metadata before removal is durable: after a crash the
	// expired file could otherwise reappear and be served as a legacy file.
	if s.dir.Sync() != nil {
		return errStorage
	}
	return s.index.remove(id)
}

func (s *attachmentStore) pruneLegacy(id string, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, tracked, err := s.index.lookup(id)
	if err != nil || tracked {
		return err
	}
	info, err := s.root.Lstat(id)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return errStorage
	}
	if info.Mode().IsRegular() && !now.Before(info.ModTime().Add(s.retention)) {
		if err := s.root.Remove(id); err != nil && !errors.Is(err, os.ErrNotExist) {
			return errStorage
		}
	}
	return nil
}

func (s *attachmentStore) prunePrepared(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, active := s.active[id]; active {
		return nil
	}
	// When the stage exists but the final file is absent, publication did
	// not happen. Release its quota reservation; do not delete metadata for
	// a committed file that only needs its temporary hardlink removed.
	_, err := s.root.Lstat(id)
	if errors.Is(err, os.ErrNotExist) {
		if s.dir.Sync() != nil || s.index.remove(id) != nil {
			return errStorage
		}
	} else if err != nil {
		return errStorage
	}
	if err := s.root.Remove(stagingPrefix + id); err != nil && !errors.Is(err, os.ErrNotExist) {
		return errStorage
	}
	return nil
}

func (s *attachmentStore) cleanup(ctx context.Context, now time.Time) error {
	ids, err := s.index.expired(now.Unix())
	if err != nil {
		return err
	}
	var failed error
	for _, id := range ids {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if s.pruneTracked(id) != nil {
			failed = errStorage
		}
	}
	// Use a new directory descriptor and bounded batches: dir itself is used
	// for flock/fsync and provider state may include many old PHP uploads.
	dir, err := s.root.Open(".")
	if err != nil {
		return errStorage
	}
	defer dir.Close()
	for {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		entries, err := dir.ReadDir(128)
		for _, entry := range entries {
			if !entry.Type().IsRegular() {
				continue
			}
			id := entry.Name()
			if attachmentID.MatchString(id) {
				if s.pruneLegacy(id, now) != nil {
					failed = errStorage
				}
			} else if finalName, staging := strings.CutPrefix(id, stagingPrefix); staging && attachmentID.MatchString(finalName) {
				if s.prunePrepared(finalName) != nil {
					failed = errStorage
				}
			}
		}
		if err == io.EOF {
			return failed
		}
		if err != nil {
			return errStorage
		}
	}
}
