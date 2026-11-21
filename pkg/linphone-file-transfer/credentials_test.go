package main

import (
	"bytes"
	"crypto/md5"
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func TestCredentialsCommand(t *testing.T) {
	dir := t.TempDir()
	pw := filepath.Join(dir, "secret")
	output := filepath.Join(dir, "accounts.json")
	if err := os.WriteFile(pw, []byte(" example\r\n test \n"), 0600); err != nil {
		t.Fatal(err)
	}
	args := []string{"credentials", "--realm", "example.test", "--output", output,
		"--account", "alice=" + pw, "--account", "bob=" + pw}
	if err := run(args); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(output)
	if err != nil || info.Mode().Perm() != 0640 {
		t.Fatalf("credentials require mode 0640, got %v, %v", info, err)
	}
	data, err := os.ReadFile(output)
	if err != nil || bytes.Contains(data, []byte(" example test ")) || bytes.Contains(data, []byte(pw)) {
		t.Fatalf("manifest could not be read or contained plaintext")
	}
	stored, err := loadCredentials(output, "example.test")
	if err != nil || len(stored.Accounts) != 2 {
		t.Fatalf("could not read generated credentials: %v", err)
	}
	for _, user := range []string{"alice", "bob"} {
		a1 := []byte(user + ":example.test: example test ")
		if a := stored.Accounts[user]; a.MD5 != fmt.Sprintf("%x", md5.Sum(a1)) || a.SHA256 != fmt.Sprintf("%x", sha256.Sum256(a1)) {
			t.Fatal("wrong HA1")
		}
	}
	if _, err := loadCredentials(output, "another.example.test"); err == nil {
		t.Fatal("wrong realm accepted")
	}
	if err := run(append(args, "--account", "alice="+pw)); err == nil {
		t.Fatal("duplicate account accepted")
	}
	if got, err := os.ReadFile(output); err != nil || !bytes.Equal(data, got) {
		t.Fatal("failing credentials run changed old manifest")
	}
}

func TestPublicOrigin(t *testing.T) {
	for _, good := range []string{"https://example.test", "https://example.test:8443", "https://[::1]:8443", "https://example.test/"} {
		if _, err := parseOrigin(good); err != nil {
			t.Errorf("rejecting %q: %v", good, err)
		}
	}
	for _, bad := range []string{"http://example.test", "https://example.test:0", "https://example.test:65536",
		"https://name@example.test", "https://example.test/file", "https://example.test?p=1", "https://example.test#"} {
		if _, err := parseOrigin(bad); err == nil {
			t.Errorf("accepting %q", bad)
		}
	}
}
