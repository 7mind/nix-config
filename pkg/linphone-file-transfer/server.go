package main

import (
	"encoding/xml"
	"errors"
	"io"
	"mime"
	"mime/multipart"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	provisioningPath = "/linphone-config.xml"
	transferPath     = "/flexisip-http-file-transfer-server/hft.php"
	downloadPrefix   = "/flexisip-http-file-transfer-server/tmp/"
	descriptorType   = "application/vnd.gsma.rcs-ft-http+xml"

	envelopeLimit   = 1 << 20 // Bounds multipart overhead independently of File.
	maxParts        = 16
	uploadWorkers   = 8
	downloadWorkers = 32
)

type transferServer struct {
	auth  *digestAuth
	store *attachmentStore
	now   func() time.Time

	origin, conferencePath   string
	provisioning, conference []byte
	maxBytes                 int64
	uploads, downloads       chan struct{}
}

func (s *transferServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "private, no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	path := r.URL.Path
	static := path == provisioningPath || (s.conferencePath != "" && path == s.conferencePath)
	// Ignore query strings only on the exact public provisioning routes,
	// preserving cache-busting provisioning URLs. Attachment endpoints avoid
	// path aliases and bind Digest to the exact canonical request target.
	if r.RequestURI != path && (!static || r.RequestURI != path+"?"+r.URL.RawQuery) {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	now := s.now()
	switch {
	case path == provisioningPath:
		serveProvisioning(w, r, s.provisioning)
	case s.conferencePath != "" && path == s.conferencePath:
		serveProvisioning(w, r, s.conference)
	case path == transferPath:
		// The previous endpoint also responded to an unauthenticated GET probe.
		if r.Method != http.MethodPost && r.Method != http.MethodGet && r.Method != http.MethodHead {
			methodNotAllowed(w, "POST")
			return
		}
		if !s.auth.require(w, r, now) {
			return
		}
		if r.Method != http.MethodPost {
			methodNotAllowed(w, "POST")
			return
		}
		s.upload(w, r)
	case strings.HasPrefix(path, downloadPrefix):
		id := path[len(downloadPrefix):]
		if !attachmentID.MatchString(id) {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			methodNotAllowed(w, "GET, HEAD")
			return
		}
		if s.auth.require(w, r, now) {
			s.download(w, r, id, now)
		}
	default:
		w.WriteHeader(http.StatusNotFound)
	}
}

func methodNotAllowed(w http.ResponseWriter, allow string) {
	w.Header().Set("Allow", allow)
	w.WriteHeader(http.StatusMethodNotAllowed)
}

func serveProvisioning(w http.ResponseWriter, r *http.Request, data []byte) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		methodNotAllowed(w, "GET, HEAD")
		return
	}
	w.Header().Set("Content-Type", "application/xml; charset=utf-8")
	w.Header().Set("Content-Length", strconv.Itoa(len(data)))
	if r.Method == http.MethodGet {
		_, _ = w.Write(data)
	} else {
		w.WriteHeader(http.StatusOK)
	}
}

func (s *transferServer) download(w http.ResponseWriter, r *http.Request, id string, now time.Time) {
	select {
	case s.downloads <- struct{}{}:
		defer func() { <-s.downloads }()
	default:
		w.Header().Set("Retry-After", "5")
		w.WriteHeader(http.StatusServiceUnavailable)
		return
	}
	f, info, err := s.store.download(id, now)
	if err != nil {
		status := http.StatusInternalServerError
		if errors.Is(err, os.ErrNotExist) {
			status = http.StatusNotFound
		}
		w.WriteHeader(status)
		return
	}
	defer f.Close()
	// Use the inert attachment wire behavior of PHP for both new and legacy
	// content, not a client-supplied media type or untrusted HTML filename.
	w.Header().Set("Content-Description", "File Transfer")
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Disposition", `attachment; filename="`+id+`"`)
	http.ServeContent(w, r, id, info.ModTime(), f)
}

func (s *transferServer) upload(w http.ResponseWriter, r *http.Request) {
	select {
	case s.uploads <- struct{}{}:
		defer func() { <-s.uploads }()
	default:
		w.Header().Set("Retry-After", "5")
		w.WriteHeader(http.StatusServiceUnavailable)
		return
	}
	limit := s.maxBytes + envelopeLimit
	if r.ContentLength > limit || len(r.Header.Values("Content-Type")) != 1 {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, limit)
	defer r.Body.Close()
	parts, err := r.MultipartReader()
	if err != nil {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	// Request.MultipartReader also accepts multipart/mixed. The upload
	// endpoint needs form-data and exactly one named file part.
	if media, _, err := mime.ParseMediaType(r.Header.Get("Content-Type")); err != nil || media != "multipart/form-data" {
		w.WriteHeader(http.StatusBadRequest)
		return
	}

	var a attachment
	for i := 0; ; i++ {
		part, err := parts.NextRawPart()
		if err == io.EOF {
			break
		}
		if err != nil || i >= maxParts || part.FormName() == "" {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		if part.FormName() != "File" && part.FileName() == "" {
			if _, err := io.Copy(io.Discard, part); err != nil {
				w.WriteHeader(http.StatusBadRequest)
				return
			}
			continue
		}
		if a.ID != "" || part.FormName() != "File" || len(part.Header.Values("Content-Disposition")) != 1 ||
			len(part.Header.Values("Content-Type")) > 1 || part.Header.Get("Content-Transfer-Encoding") != "" {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		a.Name, a.ContentType, err = partMetadata(part)
		if err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		id, f, err := s.store.prepare(s.now())
		if err != nil {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		a.ID = id
		defer s.store.abort(a.ID)
		size, err := io.Copy(f, io.LimitReader(part, s.maxBytes+1))
		if err != nil || size > s.maxBytes {
			_ = f.Close()
			var pathErr *os.PathError
			if errors.As(err, &pathErr) {
				w.WriteHeader(http.StatusInternalServerError)
			} else {
				w.WriteHeader(http.StatusBadRequest)
			}
			return
		}
		syncErr := f.Sync()
		if f.Close() != nil || syncErr != nil {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		a.Size = size
	}
	if a.ID == "" {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	// Finish the bounded body as a whole, including a multipart epilogue.
	if _, err := io.Copy(io.Discard, r.Body); err != nil {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	a.Expires = s.now().Add(s.store.retention).Unix()
	descriptor, err := describe(a, s.origin)
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		return
	}
	if err := s.store.publish(a); err != nil {
		if errors.Is(err, errQuota) {
			w.WriteHeader(http.StatusInsufficientStorage)
		} else {
			w.WriteHeader(http.StatusInternalServerError)
		}
		return
	}
	w.Header().Set("Content-Type", descriptorType)
	_, _ = w.Write(descriptor)
}

func partMetadata(p *multipart.Part) (name, contentType string, err error) {
	name = p.FileName()
	if i := strings.LastIndexByte(name, '\\'); i >= 0 {
		name = name[i+1:] // Windows clients can send the full client path.
	}
	if name == "" || name == "." || name == ".." || len(name) > 512 || !isXMLText(name) {
		return "", "", errors.New("invalid filename")
	}
	contentType = p.Header.Get("Content-Type")
	if contentType == "" {
		contentType = "application/octet-stream"
	}
	mt, _, err := mime.ParseMediaType(contentType)
	if err != nil || !strings.Contains(mt, "/") || len(contentType) > 512 || !isXMLText(contentType) {
		return "", "", errors.New("invalid multipart media type")
	}
	return name, contentType, nil
}

func isXMLText(s string) bool {
	if !utf8.ValidString(s) {
		return false
	}
	for _, r := range s {
		if r < 0x20 || r == 0xfffe || r == 0xffff {
			return false
		}
	}
	return true
}

func describe(a attachment, origin string) ([]byte, error) {
	type data struct {
		URL   string `xml:"url,attr"`
		Until string `xml:"until,attr"`
	}
	type fileInfo struct {
		Type        string `xml:"type,attr"`
		Size        int64  `xml:"file-size"`
		Name        string `xml:"file-name"`
		ContentType string `xml:"content-type"`
		Data        data   `xml:"data"`
	}
	type descriptor struct {
		XMLName xml.Name `xml:"urn:gsma:params:xml:ns:rcs:rcs:fthttp file"`
		Info    fileInfo `xml:"file-info"`
	}
	d := descriptor{Info: fileInfo{
		Type: "file", Size: a.Size, Name: a.Name, ContentType: a.ContentType,
		Data: data{origin + downloadPrefix + a.ID, time.Unix(a.Expires, 0).UTC().Format(time.RFC3339)},
	}}
	body, err := xml.Marshal(d)
	return append([]byte(xml.Header), body...), err
}
