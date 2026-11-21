package main

/*
#cgo pkg-config: sqlite3
#include <stdlib.h>
#include <sqlite3.h>

static int bind_text(sqlite3_stmt *s, int col, const char *text, int bytes) {
	return sqlite3_bind_text(s, col, text, bytes, SQLITE_TRANSIENT);
}
*/
import "C"

import (
	"errors"
	"sync"
	"unsafe"
)

type attachment struct {
	ID, Name, ContentType string
	Size, Expires         int64
}

// All filenames returned by the metadata store still need validation before
// use. An expired record remains until its file is confirmed absent.
type attachmentIndex interface {
	insert(attachment, int, int64) (bool, error)
	lookup(id string) (attachment, bool, error)
	expired(unixTime int64) ([]string, error)
	remove(id string) error
}

type sqliteIndex struct {
	mu sync.Mutex
	db *C.sqlite3
}

// Use fixed SQL and bound values on a single local connection. Driver errors
// intentionally omit SQLite messages, which can include input values or paths.
var errIndex = errors.New("attachment database operation failed")

func openIndex(path string) (*sqliteIndex, error) {
	p := C.CString(path)
	defer C.free(unsafe.Pointer(p))
	s := new(sqliteIndex)
	res := C.sqlite3_open_v2(p, &s.db, C.SQLITE_OPEN_READWRITE|C.SQLITE_OPEN_CREATE|C.SQLITE_OPEN_NOFOLLOW, nil)
	if res != C.SQLITE_OK {
		s.close()
		return nil, errIndex
	}
	C.sqlite3_busy_timeout(s.db, 3000)
	const schema = `
		PRAGMA trusted_schema = OFF;
		PRAGMA synchronous = FULL;
		CREATE TABLE IF NOT EXISTS attachments (
		  id TEXT PRIMARY KEY NOT NULL,
		  name TEXT NOT NULL,
		  content_type TEXT NOT NULL,
		  size INTEGER NOT NULL CHECK (size >= 0),
		  expires INTEGER NOT NULL
		) WITHOUT ROWID;
		CREATE INDEX IF NOT EXISTS attachments_expiry ON attachments(expires);`
	sql := C.CString(schema)
	defer C.free(unsafe.Pointer(sql))
	if C.sqlite3_exec(s.db, sql, nil, nil, nil) != C.SQLITE_OK {
		s.close()
		return nil, errIndex
	}
	return s, nil
}

func (s *sqliteIndex) close() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.db != nil {
		C.sqlite3_close(s.db)
		s.db = nil
	}
}

// query serializes complete SQLite operations, including steps/column access.
func (s *sqliteIndex) query(query string, f func(*C.sqlite3_stmt) error) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.db == nil {
		return errIndex
	}
	p := C.CString(query)
	defer C.free(unsafe.Pointer(p))
	var stmt *C.sqlite3_stmt
	if C.sqlite3_prepare_v2(s.db, p, -1, &stmt, nil) != C.SQLITE_OK {
		return errIndex
	}
	defer C.sqlite3_finalize(stmt)
	return f(stmt)
}

func bindText(stmt *C.sqlite3_stmt, col C.int, value string) bool {
	p := C.CString(value)
	defer C.free(unsafe.Pointer(p))
	return C.bind_text(stmt, col, p, C.int(len(value))) == C.SQLITE_OK
}

func bindInt(stmt *C.sqlite3_stmt, col C.int, value int64) bool {
	return C.sqlite3_bind_int64(stmt, col, C.sqlite3_int64(value)) == C.SQLITE_OK
}

func columnText(stmt *C.sqlite3_stmt, col C.int) string {
	p := C.sqlite3_column_text(stmt, col)
	return C.GoStringN((*C.char)(unsafe.Pointer(p)), C.sqlite3_column_bytes(stmt, col))
}

func (s *sqliteIndex) insert(a attachment, maxCount int, maxBytes int64) (bool, error) {
	var inserted bool
	err := s.query(`INSERT INTO attachments(id, name, content_type, size, expires)
		SELECT ?1, ?2, ?3, ?4, ?5
		FROM (SELECT COUNT(*) AS n, COALESCE(SUM(size), 0) AS bytes FROM attachments)
		WHERE n < ?6 AND bytes <= ?7`, func(stmt *C.sqlite3_stmt) error {
		if !bindText(stmt, 1, a.ID) || !bindText(stmt, 2, a.Name) || !bindText(stmt, 3, a.ContentType) ||
			!bindInt(stmt, 4, a.Size) || !bindInt(stmt, 5, a.Expires) || !bindInt(stmt, 6, int64(maxCount)) ||
			!bindInt(stmt, 7, maxBytes-a.Size) || C.sqlite3_step(stmt) != C.SQLITE_DONE {
			return errIndex
		}
		inserted = C.sqlite3_changes(s.db) == 1
		return nil
	})
	return inserted, err
}

func (s *sqliteIndex) lookup(id string) (attachment, bool, error) {
	var a attachment
	var exists bool
	err := s.query(`SELECT name, content_type, size, expires FROM attachments WHERE id = ?`, func(stmt *C.sqlite3_stmt) error {
		if !bindText(stmt, 1, id) {
			return errIndex
		}
		switch C.sqlite3_step(stmt) {
		case C.SQLITE_ROW:
			a = attachment{id, columnText(stmt, 0), columnText(stmt, 1),
				int64(C.sqlite3_column_int64(stmt, 2)), int64(C.sqlite3_column_int64(stmt, 3))}
			exists = true
		case C.SQLITE_DONE:
		default:
			return errIndex
		}
		return nil
	})
	return a, exists, err
}

func (s *sqliteIndex) expired(at int64) ([]string, error) {
	var ids []string
	err := s.query(`SELECT id FROM attachments WHERE expires <= ?`, func(stmt *C.sqlite3_stmt) error {
		if !bindInt(stmt, 1, at) {
			return errIndex
		}
		for {
			switch C.sqlite3_step(stmt) {
			case C.SQLITE_ROW:
				ids = append(ids, columnText(stmt, 0))
			case C.SQLITE_DONE:
				return nil
			default:
				return errIndex
			}
		}
	})
	return ids, err
}

func (s *sqliteIndex) remove(id string) error {
	return s.query(`DELETE FROM attachments WHERE id = ?`, func(stmt *C.sqlite3_stmt) error {
		if !bindText(stmt, 1, id) || C.sqlite3_step(stmt) != C.SQLITE_DONE {
			return errIndex
		}
		return nil
	})
}
