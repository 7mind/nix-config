package main

import (
	"bytes"
	"context"
	"crypto/md5"
	"crypto/sha256"
	"encoding/xml"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/textproto"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

const (
	testRealm  = "example.test"
	testPass   = "example password"
	oldFile    = "65caabbccddff_0123456789abcdef0123.jpg"
	fakeOrigin = "https://files.example.test:8443"
	probe      = "/flexisip-http-file-transfer-server/hft.php"
	files      = "/flexisip-http-file-transfer-server/tmp/"
)

type endpoint struct {
	t     *testing.T
	h     *transferServer
	dir   string
	clock time.Time
	cn    int
}

func newEndpoint(t *testing.T, index attachmentIndex) *endpoint {
	ed := &endpoint{t: t, dir: t.TempDir(), clock: time.Unix(1_700_000_000, 0)}
	store, err := openStore(ed.dir, index, time.Hour, 1024)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(store.close)
	accounts := credentialFile{testRealm, map[string]ha1{"alice": hashPassword("alice", testRealm, []byte(testPass))}}
	ed.h = &transferServer{
		auth: newDigestAuth(accounts, ed.clock), store: store, origin: fakeOrigin,
		now: func() time.Time { return ed.clock }, maxBytes: 16,
		provisioning: []byte("<config/>"), conferencePath: "/linphone-conference-account-0.xml", conference: []byte("<conference/>"),
		uploads: make(chan struct{}, 8), downloads: make(chan struct{}, 32),
	}
	return ed
}

func (e *endpoint) response(req *http.Request, expected int) *httptest.ResponseRecorder {
	e.t.Helper()
	rec := httptest.NewRecorder()
	e.h.ServeHTTP(rec, req)
	if rec.Code != expected {
		e.t.Fatalf("%s %s: received HTTP %d, expected %d", req.Method, req.URL.Path, rec.Code, expected)
	}
	return rec
}

var challenge = regexp.MustCompile(`^Digest realm="example\.test",qop="auth",algorithm=(MD5|SHA-256),nonce="([^"]+)",opaque="([0-9a-f]{32})"(?:,stale=true)?$`)

// A separate Digest test client uses the raw challenge header and hashes both
// A1 and A2 independently of the server parser and stored HA1 computation.
func (e *endpoint) signature(method, route, algorithm, realm, password string, bare, omitAlgorithm bool) string {
	e.t.Helper()
	rec := e.response(httptest.NewRequest(method, route, nil), http.StatusUnauthorized)
	h := rec.Header().Values("WWW-Authenticate")
	if len(h) != 2 {
		e.t.Fatalf("challenge headers: %q", h)
	}
	for i, alg := range []string{"MD5", "SHA-256"} {
		parts := challenge.FindStringSubmatch(h[i])
		if len(parts) != 4 || parts[1] != alg {
			e.t.Fatalf("unexpected challenge: %q", h[i])
		}
		if alg != algorithm {
			continue
		}
		var digest func(string) string
		if alg == "MD5" {
			digest = func(s string) string { return fmt.Sprintf("%x", md5.Sum([]byte(s))) }
		} else {
			digest = func(s string) string { return fmt.Sprintf("%x", sha256.Sum256([]byte(s))) }
		}
		nonce, opaque := parts[2], parts[3]
		e.cn++
		cnonce := fmt.Sprintf("client-%d", e.cn)
		response := digest(digest("alice:"+realm+":"+password) + ":" + nonce + ":00000001:" + cnonce + ":auth:" + digest(method+":"+route))
		out := fmt.Sprintf(`username="alice",realm=%q,nonce=%q,nc=00000001,cnonce=%q,qop=auth,uri=%q,response=%q,opaque=%q`, realm, nonce, cnonce, route, response, opaque)
		if !omitAlgorithm {
			out += ",algorithm=" + alg
		}
		if !bare {
			out = "Digest " + out
		}
		return out
	}
	e.t.Fatalf("no challenge for %s", algorithm)
	return ""
}

func (e *endpoint) auth(req *http.Request) *http.Request {
	req.Header.Set("Authorization", e.signature(req.Method, req.RequestURI, "SHA-256", testRealm, testPass, false, false))
	return req
}

func makeMultipart(t *testing.T, field, name, data string, duplicate bool) *http.Request {
	t.Helper()
	b := new(bytes.Buffer)
	w := multipart.NewWriter(b)
	for {
		h := textproto.MIMEHeader{
			"Content-Disposition": {fmt.Sprintf(`form-data; name=%q; filename=%q`, field, name)},
			"Content-Type":        {"image/jpeg"},
		}
		p, err := w.CreatePart(h)
		if err != nil {
			t.Fatal(err)
		}
		_, _ = io.WriteString(p, data)
		if !duplicate {
			break
		}
		duplicate = false
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	r := httptest.NewRequest("POST", probe, b)
	r.Header.Set("Content-Type", w.FormDataContentType())
	return r
}

func checkDescriptor(t *testing.T, rec *httptest.ResponseRecorder, wantName string, size int, expiry time.Time) string {
	t.Helper()
	var x struct {
		XMLName xml.Name
		Info    struct {
			Type string `xml:"type,attr"`
			Size int    `xml:"file-size"`
			Name string `xml:"file-name"`
			MIME string `xml:"content-type"`
			Data struct {
				URL   string `xml:"url,attr"`
				Until string `xml:"until,attr"`
			} `xml:"data"`
		} `xml:"file-info"`
	}
	if err := xml.Unmarshal(rec.Body.Bytes(), &x); err != nil {
		t.Fatal(err)
	}
	if x.XMLName != (xml.Name{Space: "urn:gsma:params:xml:ns:rcs:rcs:fthttp", Local: "file"}) ||
		x.Info.Type != "file" || x.Info.Name != wantName || x.Info.Size != size || x.Info.MIME != "image/jpeg" ||
		x.Info.Data.Until != expiry.UTC().Format(time.RFC3339) || rec.Header().Get("Content-Type") != "application/vnd.gsma.rcs-ft-http+xml" {
		t.Fatalf("unexpected descriptor %s", rec.Body)
	}
	link, err := url.Parse(x.Info.Data.URL)
	if err != nil || !strings.HasPrefix(link.String(), fakeOrigin+files) ||
		!regexp.MustCompile(`^[0-9a-f]{13}_[0-9a-f]{20}\.bin$`).MatchString(filepath.Base(link.Path)) {
		t.Fatalf("unexpected download URL %s", x.Info.Data.URL)
	}
	return link.Path
}

func TestAttachmentWireAndExpiry(t *testing.T) {
	withIndexes(t, func(t *testing.T, index attachmentIndex) {
		e := newEndpoint(t, index)
		for route, content := range map[string]string{"/linphone-config.xml": "<config/>", "/linphone-conference-account-0.xml": "<conference/>"} {
			get := e.response(httptest.NewRequest("GET", route, nil), http.StatusOK)
			if get.Body.String() != content {
				t.Fatalf("unexpected provisioning %q", get.Body)
			}
			tagged := e.response(httptest.NewRequest("GET", route+"?tag=rev%202", nil), http.StatusOK)
			if tagged.Body.String() != content {
				t.Fatalf("unexpected tagged provisioning %q", tagged.Body)
			}
			head := e.response(httptest.NewRequest("HEAD", route+"?tag=rev%202", nil), http.StatusOK)
			if head.Body.Len() != 0 || head.Header().Get("Content-Length") != fmt.Sprint(len(content)) {
				t.Fatalf("unexpected provisioning HEAD: %v", head.Result())
			}
		}
		e.response(httptest.NewRequest("GET", "/%6Cinphone-config.xml?tag=rev%202", nil), http.StatusNotFound)
		e.response(httptest.NewRequest("POST", probe+"?tag=rev%202", nil), http.StatusNotFound)
		e.response(httptest.NewRequest("GET", probe, nil), http.StatusUnauthorized)
		getUpload := e.auth(httptest.NewRequest("GET", probe, nil))
		e.response(getUpload, http.StatusMethodNotAllowed)
		upload := makeMultipart(t, "File", "two & <three>.jpg", "0123456789abcdef", false)
		upload.Host = "untrusted-host.example.test"
		upload.Header.Set("X-Forwarded-Host", "also-untrusted.example.test")
		upload.Header.Set("From", "sip:other@example.test")
		upload.Header.Set("Auth-Digest", e.signature("POST", probe, "SHA-256", testRealm, testPass, true, false))
		rec := e.response(upload, http.StatusOK)
		route := checkDescriptor(t, rec, "two & <three>.jpg", 16, e.clock.Add(time.Hour))
		e.response(httptest.NewRequest("GET", route, nil), http.StatusUnauthorized)
		get := httptest.NewRequest("GET", route, nil)
		get.Header.Set("Authorization", e.signature("GET", route, "MD5", testRealm, testPass, false, true))
		rec = e.response(get, http.StatusOK)
		if rec.Body.String() != "0123456789abcdef" || rec.Header().Get("Content-Type") != "application/octet-stream" ||
			rec.Header().Get("Content-Length") != "16" || rec.Header().Get("Content-Disposition") != fmt.Sprintf(`attachment; filename="%s"`, filepath.Base(route)) {
			t.Fatalf("unexpected download: %v", rec.Result())
		}
		e.response(get.Clone(context.Background()), http.StatusUnauthorized)
		head := e.response(e.auth(httptest.NewRequest("HEAD", route, nil)), http.StatusOK)
		if head.Body.Len() != 0 || head.Header().Get("Content-Length") != "16" {
			t.Fatalf("unexpected download HEAD: %v", head.Result())
		}
		// Expiry must remain governed by the persisted descriptor, not mtime.
		path := filepath.Join(e.dir, filepath.Base(route))
		e.clock = e.clock.Add(time.Hour)
		if err := os.Chtimes(path, e.clock, e.clock); err != nil {
			t.Fatal(err)
		}
		e.response(e.auth(httptest.NewRequest("GET", route, nil)), http.StatusNotFound)
		if err := e.h.store.cleanup(context.Background(), e.clock); err != nil {
			t.Fatal(err)
		}
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Fatalf("expired file not removed: %v", err)
		}
	})
}

func TestDigestBindingAndNonceExpiry(t *testing.T) {
	withIndexes(t, func(t *testing.T, index attachmentIndex) {
		e := newEndpoint(t, index)
		route := files + oldFile
		signature := e.signature("GET", route, "SHA-256", testRealm, testPass, false, false)
		for _, tc := range []struct{ method, route, digest string }{
			{"HEAD", route, signature},
			{"GET", files + "65caabbccddff_0123456789abcdef0124.jpg", signature},
			{"GET", route, e.signature("GET", route, "MD5", "foreign.test", testPass, false, false)},
			{"GET", route, e.signature("GET", route, "MD5", testRealm, "wrong password", false, false)},
			{"GET", route, signature + `,algorithm=MD5`},
			{"GET", route, strings.Replace(signature, "qop=auth", "qop=auth-int", 1)},
		} {
			req := httptest.NewRequest(tc.method, tc.route, nil)
			req.Header.Set("Authorization", tc.digest)
			req.Header.Set("From", "sip:alice@example.test")
			e.response(req, http.StatusUnauthorized)
		}
		e.clock = e.clock.Add(2 * time.Minute)
		req := httptest.NewRequest("GET", route, nil)
		req.Header.Set("Authorization", signature)
		for _, h := range e.response(req, http.StatusUnauthorized).Header().Values("WWW-Authenticate") {
			if !strings.Contains(h, "stale=true") {
				t.Fatalf("expired nonce must be stale: %q", h)
			}
		}
	})
}

func TestUploadLimits(t *testing.T) {
	withIndexes(t, func(t *testing.T, index attachmentIndex) {
		e := newEndpoint(t, index)
		for _, tc := range []struct {
			field, body string
			multiple    bool
		}{
			{"Unknown", "no", false}, {"File", strings.Repeat("x", 17), false}, {"File", "dup", true},
		} {
			e.response(e.auth(makeMultipart(t, tc.field, "file.jpg", tc.body, tc.multiple)), http.StatusBadRequest)
		}
		e.response(e.auth(httptest.NewRequest("POST", probe, nil)), http.StatusBadRequest)
		oversize := makeMultipart(t, "File", "name.jpg", "ok", false)
		oversize.Body = io.NopCloser(io.MultiReader(oversize.Body, strings.NewReader(strings.Repeat("x", 1<<20))))
		oversize.ContentLength = -1 // Simulate unknown/chunked Content-Length.
		e.response(e.auth(oversize), http.StatusBadRequest)
		for i := 0; i < cap(e.h.uploads); i++ {
			e.h.uploads <- struct{}{}
		}
		e.response(e.auth(makeMultipart(t, "File", "file.jpg", "ok", false)), http.StatusServiceUnavailable)
		for i := 0; i < cap(e.h.uploads); i++ {
			<-e.h.uploads
		}
		e.h.store.quota = 2
		e.response(e.auth(makeMultipart(t, "File", "file.jpg", "too large for store", false)), http.StatusBadRequest)
		e.response(e.auth(makeMultipart(t, "File", "file.jpg", "quota", false)), http.StatusInsufficientStorage)
		if paths, err := os.ReadDir(e.dir); err != nil || len(paths) != 0 {
			t.Fatalf("rejected uploads left files behind: %v, %v", paths, err)
		}
		e.response(e.auth(makeMultipart(t, "File", "file.jpg", "ok", false)), http.StatusOK)
		e.response(e.auth(makeMultipart(t, "File", "file.jpg", "ok", false)), http.StatusInsufficientStorage)
	})
}

func TestLegacyAndRecovery(t *testing.T) {
	withIndexes(t, func(t *testing.T, index attachmentIndex) {
		e := newEndpoint(t, index)
		write := func(name, content string, age time.Duration) {
			t.Helper()
			path := filepath.Join(e.dir, name)
			if err := os.WriteFile(path, []byte(content), 0600); err != nil {
				t.Fatal(err)
			}
			stamp := e.clock.Add(-age)
			if err := os.Chtimes(path, stamp, stamp); err != nil {
				t.Fatal(err)
			}
		}
		write(oldFile, "legacy", time.Minute)
		stale := "65caabbccddff_0123456789abcdef0124.php.txt"
		write(stale, "old", time.Hour)
		write("server.log", "ordinary non-upload", time.Hour)
		symlink := "65caabbccddff_0123456789abcdef0125.jpg"
		if err := os.Symlink("server.log", filepath.Join(e.dir, symlink)); err != nil {
			t.Fatal(err)
		}
		hardlink := "65caabbccddff_0123456789abcdef0126.jpg"
		if err := os.Link(filepath.Join(e.dir, "server.log"), filepath.Join(e.dir, hardlink)); err != nil {
			t.Fatal(err)
		}
		orphan := "65caabbccddff_0123456789abcdef0127.bin"
		orphanStage := ".linphone-upload-" + orphan
		write(orphanStage, "preparing", 0)
		if ok, err := index.insert(attachment{ID: orphan, Size: 9, Expires: e.clock.Add(time.Hour).Unix()}, 100, 1000); !ok || err != nil {
			t.Fatalf("preparing interrupted publish fixture: %v, %v", ok, err)
		}
		active, f, err := e.h.store.prepare(e.clock)
		if err != nil {
			t.Fatal(err)
		}
		defer f.Close()
		defer e.h.store.abort(active)
		for _, route := range []string{files + "server.log", files + "legacy.jpg", files + orphanStage,
			files + "unexpected/path", files + "../" + oldFile, files + oldFile + "?target=example.test", files + "%36" + oldFile[1:]} {
			e.response(httptest.NewRequest("GET", route, nil), http.StatusNotFound)
		}
		for _, id := range []string{stale, symlink, hardlink, orphan} {
			e.response(e.auth(httptest.NewRequest("GET", files+id, nil)), http.StatusNotFound)
		}
		e.response(httptest.NewRequest("PUT", files+oldFile, nil), http.StatusMethodNotAllowed)
		rec := e.response(e.auth(httptest.NewRequest("GET", files+oldFile, nil)), http.StatusOK)
		if rec.Body.String() != "legacy" {
			t.Fatalf("legacy payload: %q", rec.Body)
		}
		if err := e.h.store.cleanup(context.Background(), e.clock); err != nil {
			t.Fatal(err)
		}
		for _, name := range []string{stale, orphanStage} {
			if _, err := os.Lstat(filepath.Join(e.dir, name)); !os.IsNotExist(err) {
				t.Fatalf("cleanup should remove %s: %v", name, err)
			}
		}
		for _, name := range []string{oldFile, symlink, "server.log", ".linphone-upload-" + active} {
			if _, err := os.Lstat(filepath.Join(e.dir, name)); err != nil {
				t.Fatalf("cleanup should retain %s: %v", name, err)
			}
		}
		if _, exists, err := index.lookup(orphan); exists || err != nil {
			t.Fatalf("interrupted publication quota was not released: %v, %v", exists, err)
		}
	})
}
