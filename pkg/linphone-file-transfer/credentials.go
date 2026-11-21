package main

import (
	"bytes"
	"crypto/md5" // RFC 7616 compatibility with older Linphone clients.
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

const (
	credentialLimit = 4 << 20
	passwordLimit   = 64 << 10
	maxAccounts     = 4096
)

type ha1 struct {
	MD5    string `json:"md5"`
	SHA256 string `json:"sha256"`
}

type credentialFile struct {
	Realm    string         `json:"realm"`
	Accounts map[string]ha1 `json:"accounts"`
}

// A colon cannot be represented unambiguously in an RFC 7616 user or realm.
// Keep realm ASCII for older clients and disallow controls in either field.
func validIdentity(s string, realm bool) bool {
	if s == "" || len(s) > 255 {
		return false
	}
	for _, b := range []byte(s) {
		if b < 0x20 || realm && b == 0x20 || b > 0x7e || b == ':' {
			return false
		}
	}
	return true
}

func readBounded(path string, limit int64) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > limit {
		return nil, errors.New("invalid input file")
	}
	b, err := io.ReadAll(io.LimitReader(f, limit+1))
	if err != nil || int64(len(b)) > limit {
		return nil, errors.New("could not read input file")
	}
	return b, nil
}

func hashPassword(account, realm string, secret []byte) ha1 {
	// The Flexisip account loader removes CR and LF, including an ending newline.
	n := 0
	for _, b := range secret {
		if b != '\r' && b != '\n' {
			secret[n] = b
			n++
		}
	}
	prefix := []byte(account + ":" + realm + ":")
	a, b := md5.New(), sha256.New()
	_, _ = a.Write(prefix)
	_, _ = b.Write(prefix)
	_, _ = a.Write(secret[:n])
	_, _ = b.Write(secret[:n])
	return ha1{hex.EncodeToString(a.Sum(nil)), hex.EncodeToString(b.Sum(nil))}
}

func writeCredentials(realm, output string, specs []string) error {
	if !validIdentity(realm, true) || output == "" || len(specs) > maxAccounts {
		return errors.New("invalid credentials options")
	}
	manifest := credentialFile{realm, make(map[string]ha1, len(specs))}
	for i, spec := range specs {
		account, path, ok := strings.Cut(spec, "=")
		if !ok || !validIdentity(account, false) || path == "" {
			return fmt.Errorf("invalid account argument %d", i+1)
		}
		if _, duplicate := manifest.Accounts[account]; duplicate {
			return fmt.Errorf("duplicate account argument %d", i+1)
		}
		secret, err := readBounded(path, passwordLimit)
		if err != nil {
			return fmt.Errorf("could not read password for account argument %d", i+1)
		}
		if len(bytes.Trim(secret, "\r\n")) == 0 {
			return fmt.Errorf("empty password for account argument %d", i+1)
		}
		manifest.Accounts[account] = hashPassword(account, realm, secret)
		clear(secret)
	}
	return replaceCredentials(output, manifest)
}

func replaceCredentials(output string, manifest credentialFile) error {
	// A failed write leaves the old manifest intact. Rename does not follow
	// an existing output symlink. The caller sets the final group if needed.
	dir, err := os.Open(filepath.Dir(output))
	if err != nil {
		return errors.New("could not open credentials output directory")
	}
	defer dir.Close()
	f, err := os.CreateTemp(filepath.Dir(output), ".accounts-*")
	if err != nil {
		return errors.New("could not create credentials output")
	}
	defer f.Close()
	defer os.Remove(f.Name())
	if err := json.NewEncoder(f).Encode(manifest); err != nil {
		return errors.New("could not write credentials output")
	}
	if f.Chmod(0640) != nil || f.Sync() != nil || f.Close() != nil || os.Rename(f.Name(), output) != nil {
		return errors.New("could not replace credentials output")
	}
	if dir.Sync() != nil {
		return errors.New("credentials replaced, but directory sync failed")
	}
	return nil
}

func loadCredentials(path, realm string) (credentialFile, error) {
	var c credentialFile
	fail := errors.New("could not load credentials for configured realm")
	b, err := readBounded(path, credentialLimit)
	if err != nil {
		return c, fail
	}
	d := json.NewDecoder(bytes.NewReader(b))
	d.DisallowUnknownFields()
	if err = d.Decode(&c); err != nil || d.Decode(new(any)) != io.EOF ||
		c.Realm != realm || c.Accounts == nil || len(c.Accounts) > maxAccounts {
		return c, fail
	}
	for account, hashes := range c.Accounts {
		if !validIdentity(account, false) || !validLowerHex(hashes.MD5, md5.Size) || !validLowerHex(hashes.SHA256, sha256.Size) {
			return c, fail
		}
	}
	return c, nil
}

func validLowerHex(s string, bytes int) bool {
	if len(s) != bytes*2 {
		return false
	}
	for _, b := range []byte(s) {
		if !(b >= '0' && b <= '9' || b >= 'a' && b <= 'f') {
			return false
		}
	}
	return true
}
