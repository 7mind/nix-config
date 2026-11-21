package main

import (
	"crypto/hmac"
	"crypto/md5" // RFC 7616 compatibility with older Linphone clients.
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"hash"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	nonceLifetime = int64(120)
	replayLimit   = 16384
	digestLimit   = 4096
)

type digestAuth struct {
	auth    credentialFile
	opaque  string
	key     [32]byte
	started time.Time

	mu        sync.Mutex
	replay    map[[32]byte]int64
	nextPrune int64
}

func newDigestAuth(credentials credentialFile, started time.Time) *digestAuth {
	a := &digestAuth{auth: credentials, started: started, opaque: digestHex(md5.New, credentials.Realm), replay: make(map[[32]byte]int64)}
	rand.Read(a.key[:])
	return a
}

// The monotonic component of the server clock prevents an expired nonce
// and its pruned replay keys from becoming valid after a wall-clock rewind.
func (a *digestAuth) seconds(now time.Time) int64 {
	return int64(now.Sub(a.started) / time.Second)
}

func (a *digestAuth) challenge(w http.ResponseWriter, now time.Time, stale bool) {
	var payload [24]byte
	binary.BigEndian.PutUint64(payload[:8], uint64(a.seconds(now)+nonceLifetime))
	rand.Read(payload[8:])
	mac := hmac.New(sha256.New, a.key[:])
	mac.Write(payload[:])
	nonce := base64.RawURLEncoding.EncodeToString(mac.Sum(payload[:]))
	for _, algorithm := range []string{"MD5", "SHA-256"} {
		header := `Digest realm=` + strconv.Quote(a.auth.Realm) + `,qop="auth",algorithm=` + algorithm +
			`,nonce="` + nonce + `",opaque="` + a.opaque + `"`
		if stale {
			header += `,stale=true`
		}
		w.Header().Add("WWW-Authenticate", header)
	}
	w.WriteHeader(http.StatusUnauthorized)
}

func (a *digestAuth) nonceExpiry(nonce string) (int64, bool) {
	if len(nonce) != base64.RawURLEncoding.EncodedLen(24+sha256.Size) {
		return 0, false
	}
	decoded, err := base64.RawURLEncoding.Strict().DecodeString(nonce)
	if err != nil || len(decoded) != 24+sha256.Size {
		return 0, false
	}
	mac := hmac.New(sha256.New, a.key[:])
	mac.Write(decoded[:24])
	return int64(binary.BigEndian.Uint64(decoded[:8])), hmac.Equal(decoded[24:], mac.Sum(nil))
}

func isToken(b byte) bool {
	return b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z' || b >= '0' && b <= '9' ||
		strings.IndexByte("!#$%&'*+-.^_`|~", b) >= 0
}

func parseDigest(s string, bareAllowed bool) map[string]string {
	if len(s) == 0 || len(s) > digestLimit {
		return nil
	}
	s = strings.Trim(s, " \t")
	if len(s) > 6 && strings.EqualFold(s[:6], "Digest") && (s[6] == ' ' || s[6] == '\t') {
		s = strings.TrimLeft(s[6:], " \t")
	} else if !bareAllowed {
		return nil
	}
	params := make(map[string]string, 10)
	for {
		end := 0
		for end < len(s) && isToken(s[end]) {
			end++
		}
		if end == 0 || len(params) == 20 {
			return nil
		}
		name := strings.ToLower(s[:end])
		if _, duplicate := params[name]; duplicate {
			return nil
		}
		s = strings.TrimLeft(s[end:], " \t")
		if len(s) == 0 || s[0] != '=' {
			return nil
		}
		s = strings.TrimLeft(s[1:], " \t")
		if len(s) > 0 && s[0] == '"' {
			var value strings.Builder
			pos := 1
			for pos < len(s) && s[pos] != '"' {
				if s[pos] == '\\' {
					pos++
				}
				if pos == len(s) || s[pos] < ' ' || s[pos] == 0x7f {
					return nil
				}
				value.WriteByte(s[pos])
				pos++
			}
			if pos == len(s) {
				return nil
			}
			params[name], s = value.String(), s[pos+1:]
		} else {
			end := 0
			for end < len(s) && isToken(s[end]) {
				end++
			}
			if end == 0 {
				return nil
			}
			params[name], s = s[:end], s[end:]
		}
		s = strings.TrimLeft(s, " \t")
		if len(s) == 0 {
			return params
		}
		if s[0] != ',' {
			return nil
		}
		s = strings.TrimLeft(s[1:], " \t")
	}
}

func digestHex(algo func() hash.Hash, text string) string {
	h := algo()
	h.Write([]byte(text))
	return hex.EncodeToString(h.Sum(nil))
}

func (a *digestAuth) require(w http.ResponseWriter, r *http.Request, now time.Time) bool {
	headers := r.Header.Values("Auth-Digest")
	bare := len(headers) != 0
	if !bare {
		headers = r.Header.Values("Authorization")
	}
	if len(headers) != 1 {
		a.challenge(w, now, false)
		return false
	}
	status, stale := a.verify(parseDigest(headers[0], bare), r, a.seconds(now))
	switch status {
	case http.StatusOK:
		return true
	case http.StatusServiceUnavailable:
		w.Header().Set("Retry-After", strconv.FormatInt(nonceLifetime, 10))
		w.WriteHeader(status)
	default:
		a.challenge(w, now, stale)
	}
	return false
}

func (a *digestAuth) verify(p map[string]string, r *http.Request, now int64) (int, bool) {
	deny := http.StatusUnauthorized
	if p["realm"] != a.auth.Realm || p["uri"] != r.RequestURI || p["qop"] != "auth" ||
		p["opaque"] != a.opaque || len(p["nc"]) != 8 || len(p["cnonce"]) == 0 || len(p["cnonce"]) > 256 {
		return deny, false
	}
	nc, err := strconv.ParseUint(p["nc"], 16, 32)
	if err != nil || nc == 0 {
		return deny, false
	}
	expires, ok := a.nonceExpiry(p["nonce"])
	if !ok || expires > now+nonceLifetime {
		return deny, false
	}
	account, found := a.auth.Accounts[p["username"]]
	algo, ha1 := md5.New, account.MD5
	algorithm := p["algorithm"]
	if strings.EqualFold(algorithm, "SHA-256") {
		algo, ha1 = sha256.New, account.SHA256
	} else if algorithm != "" && !strings.EqualFold(algorithm, "MD5") {
		return deny, false
	}
	if !found {
		// Keep comparison work independent of whether the account exists.
		ha1 = strings.Repeat("0", algo().Size()*2)
	}
	a2 := digestHex(algo, r.Method+":"+p["uri"])
	h := algo()
	h.Write([]byte(strings.Join([]string{ha1, p["nonce"], p["nc"], p["cnonce"], "auth", a2}, ":")))
	response, err := hex.DecodeString(p["response"])
	if err != nil || subtle.ConstantTimeCompare(h.Sum(nil), response) != 1 || !found {
		return deny, false
	}
	if now >= expires {
		return deny, true
	}

	// Allow parallel requests with distinct counts. An accepted (account,
	// nonce, cnonce, count) is not evicted until the nonce has expired.
	var n [4]byte
	binary.BigEndian.PutUint32(n[:], uint32(nc))
	replayKey := sha256.Sum256([]byte(p["username"] + "\x00" + p["nonce"] + "\x00" + p["cnonce"] + "\x00" + string(n[:])))
	a.mu.Lock()
	defer a.mu.Unlock()
	if now >= a.nextPrune {
		for key, expiry := range a.replay {
			if now >= expiry {
				delete(a.replay, key)
			}
		}
		a.nextPrune = now + 1
	}
	if _, reused := a.replay[replayKey]; reused {
		return deny, false
	}
	if len(a.replay) >= replayLimit {
		return http.StatusServiceUnavailable, false
	}
	a.replay[replayKey] = expires
	return http.StatusOK, false
}
