package main

import (
	"context"
	"crypto/tls"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"math"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const provisioningLimit = 2 << 20

type accounts []string

func (*accounts) String() string { return "" }
func (a *accounts) Set(value string) error {
	*a = append(*a, value)
	return nil
}

func main() {
	syscall.Umask(0077)
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "linphone-file-transfer:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) == 0 || (args[0] != "serve" && args[0] != "credentials") {
		return errors.New("expected subcommand 'serve' or 'credentials'")
	}
	flags := flag.NewFlagSet(args[0], flag.ContinueOnError)
	// flag.Parse may quote user arguments on error. Never log those values.
	flags.SetOutput(io.Discard)
	realm := flags.String("realm", "", "Digest realm")
	if args[0] == "credentials" {
		output := flags.String("output", "", "credentials manifest to write")
		var accounts accounts
		flags.Var(&accounts, "account", "username=/path/to/password-file (repeatable)")
		if flags.Parse(args[1:]) != nil || flags.NArg() != 0 {
			return errors.New("invalid credentials arguments")
		}
		return writeCredentials(*realm, *output, accounts)
	}

	listen := flags.String("listen", "", "HTTPS listen address")
	certFile := flags.String("tls-cert", "", "PEM certificate chain")
	keyFile := flags.String("tls-key", "", "PEM private key")
	publicOrigin := flags.String("public-origin", "", "public HTTPS origin")
	credentials := flags.String("credentials", "", "HA1 credentials manifest")
	provisioning := flags.String("provisioning", "", "Linphone provisioning XML")
	conferenceProvisioning := flags.String("conference-provisioning", "", "optional conference provisioning XML")
	conferencePath := flags.String("conference-path", "", "optional conference provisioning HTTP path")
	uploads := flags.String("uploads", "", "attachment files directory")
	database := flags.String("database", "", "SQLite database path outside the uploads directory")
	maxBytes := flags.Int64("max-bytes", 0, "maximum bytes per file")
	retention := flags.Int64("retention-seconds", 0, "attachment retention period")
	if flags.Parse(args[1:]) != nil || flags.NArg() != 0 || *listen == "" || *certFile == "" ||
		*keyFile == "" || *credentials == "" || *provisioning == "" || *uploads == "" || *database == "" ||
		!validIdentity(*realm, true) || *maxBytes <= 0 || *maxBytes > math.MaxInt64/quotaMultiple ||
		*retention <= 0 || *retention > int64(math.MaxInt64/time.Second) {
		return errors.New("invalid or missing serve arguments")
	}
	origin, err := parseOrigin(*publicOrigin)
	if err != nil {
		return err
	}
	if (*conferencePath == "") != (*conferenceProvisioning == "") ||
		*conferencePath != "" && (!provisioningAlias.MatchString(*conferencePath) || *conferencePath == provisioningPath) {
		return errors.New("invalid conference provisioning options")
	}
	if err := checkDatabasePath(*uploads, *database); err != nil {
		return err
	}
	accounts, err := loadCredentials(*credentials, *realm)
	if err != nil {
		return err
	}
	cert, err := tls.LoadX509KeyPair(*certFile, *keyFile)
	if err != nil {
		return errors.New("could not load TLS certificate and key")
	}
	provisioningXML, err := readBounded(*provisioning, provisioningLimit)
	if err != nil {
		return errors.New("could not load provisioning XML")
	}
	var conferenceXML []byte
	if *conferenceProvisioning != "" {
		conferenceXML, err = readBounded(*conferenceProvisioning, provisioningLimit)
		if err != nil {
			return errors.New("could not load conference provisioning XML")
		}
	}

	index, err := openIndex(*database)
	if err != nil {
		return err
	}
	defer index.close()
	lifetime := time.Duration(*retention) * time.Second
	store, err := openStore(*uploads, index, lifetime, *maxBytes*quotaMultiple)
	if err != nil {
		return err
	}
	defer store.close()
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	if err := store.cleanup(ctx, time.Now()); err != nil {
		return errors.New("initial attachment cleanup failed")
	}

	handler := &transferServer{
		auth: newDigestAuth(accounts, time.Now()), store: store, now: time.Now,
		origin: origin, provisioning: provisioningXML, conferencePath: *conferencePath, conference: conferenceXML,
		maxBytes: *maxBytes, uploads: make(chan struct{}, uploadWorkers), downloads: make(chan struct{}, downloadWorkers),
	}
	return serve(ctx, stop, *listen, cert, handler)
}

var provisioningAlias = regexp.MustCompile(`^/[a-zA-Z0-9_-]{1,128}\.xml$`)

func parseOrigin(raw string) (string, error) {
	u, err := url.Parse(raw)
	bad := errors.New("expected an https public origin with no path, query, or credentials")
	if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.Fragment != "" ||
		u.ForceQuery || u.RawQuery != "" || u.RawPath != "" || u.Path != "" && u.Path != "/" ||
		strings.ContainsAny(raw, "#%") || strings.HasSuffix(u.Host, ":") {
		return "", bad
	}
	if port := u.Port(); port != "" {
		if n, err := strconv.ParseUint(port, 10, 16); err != nil || n == 0 {
			return "", bad
		}
	}
	u.Path = ""
	return u.String(), nil
}

func checkDatabasePath(uploads, database string) error {
	resolve := func(path string) (string, error) {
		absolute, err := filepath.Abs(path)
		if err != nil {
			return "", err
		}
		return filepath.EvalSymlinks(absolute)
	}
	bad := errors.New("database must be outside the uploads directory, and both parent directories must exist")
	up, err := resolve(uploads)
	if err != nil {
		return bad
	}
	dir, err := resolve(filepath.Dir(database))
	if err != nil {
		return bad
	}
	if rel, err := filepath.Rel(up, filepath.Join(dir, filepath.Base(database))); err != nil ||
		(rel != ".." && !strings.HasPrefix(rel, "../")) {
		return bad
	}
	return nil
}

func serve(ctx context.Context, stop context.CancelFunc, address string, cert tls.Certificate, handler *transferServer) error {
	srv := &http.Server{
		Addr: address, Handler: handler,
		TLSConfig: &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12},
		ErrorLog:  log.New(io.Discard, "", 0), MaxHeaderBytes: 16 << 10,
		ReadHeaderTimeout: 10 * time.Second, ReadTimeout: 5 * time.Minute,
		WriteTimeout: 5 * time.Minute, IdleTimeout: 45 * time.Second,
	}
	shutdown := make(chan struct{})
	go func() {
		defer close(shutdown)
		<-ctx.Done()
		deadline, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if srv.Shutdown(deadline) != nil {
			_ = srv.Close()
		}
	}()
	cleaned := make(chan struct{})
	go func() {
		defer close(cleaned)
		interval := max(time.Second, min(handler.store.retention/2, time.Minute))
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case now := <-ticker.C:
				if err := handler.store.cleanup(ctx, now); err != nil && ctx.Err() == nil {
					fmt.Fprintln(os.Stderr, "linphone-file-transfer: periodic attachment cleanup failed")
				}
			}
		}
	}()
	err := srv.ListenAndServeTLS("", "")
	stop()
	<-shutdown
	<-cleaned
	if !errors.Is(err, http.ErrServerClosed) {
		return errors.New("could not start or run HTTPS server")
	}
	return nil
}
