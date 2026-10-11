# NordVPN WireGuard Extractor

Extract NordVPN WireGuard configurations, or list recommended peer endpoints.

```bash
# Full .conf files (requires access token)
export NORDVPN_ACCESS_TOKEN="..."
nordvpn-wireguard-extractor --country nl --count 5 --output ./configs

# Peer endpoints only (no token, no files) — paste into peerEndpoint
nordvpn-wireguard-extractor --endpoints --country nl --count 10
```

To print only endpoints that complete a WireGuard handshake and an HTTP request
through the tunnel, use Linux with root privileges and your existing NordLynx
private-key file:

```bash
sudo nordvpn-wireguard-extractor --endpoints --country ie --count 20 \
  --check --private-key-file /run/agenix/nordvpn-privkey
```

Each candidate uses a temporary interface and network namespace. Host routes and
existing interfaces stay unchanged, and temporary resources are removed after
each probe, including failed probes. Private keys are never printed. The HTTP
probe uses a literal IP address, so it does not depend on host DNS. A probe can
temporarily disrupt an existing connection to the same server using the same key.

With `--check`, `--count 20` targets 20 distinct passing endpoints. The extractor
loads the full WireGuard server catalogue, including all pages, and preserves the
country filter. It checks lower-load servers first, skips duplicate endpoints,
and checks candidates in batches of up to `--jobs` simultaneous probes. The default
is the number of CPUs available to the process (respecting CPU affinity on Linux).
Use `--jobs 1` for serial checking, or change the worker limit explicitly:

```bash
sudo nordvpn-wireguard-extractor --endpoints --country ie --count 20 \
  --check --jobs 4 --private-key-file /run/agenix/nordvpn-privkey
```

The extractor starts no further batches once the requested count passes. Probes
already in progress finish and remove their temporary resources before the command
returns, including when a setup failure aborts the batch. An endpoint passes only after a fresh
WireGuard handshake and a successful HTTP request through that tunnel during this run.

Failed candidates are omitted; per-server results go to stderr. The collected list
is printed to stdout after checking finishes. If every matching candidate has been
tested and fewer than requested pass, the extractor prints the smaller list,
warns on stderr, and exits successfully. If none pass, it exits with status 1 and
leaves stdout empty. Without `--check`, `--count` limits the recommendations.
To save a regenerated list, redirect stdout to a file:

```bash
sudo nordvpn-wireguard-extractor --endpoints --country ie --count 20 \
  --check --private-key-file /run/agenix/nordvpn-privkey > nordvpn-endpoints.txt
```

Setup failures abort the command. `--check-timeout` sets the
request timeout per candidate (default: 8 seconds). `--fwmark` defaults to 51820;
when a host VPN policy is active, use its WireGuard socket mark so probe transport
packets can bypass the tunnel and pass its killswitch.

Run the filtering and CLI tests with:

```bash
cd pkg/nordvpn-wireguard-extractor
python3 -m unittest discover -s tests -v
sudo env NORDVPN_TEST_KERNEL=1 python3 -m unittest discover -s tests -v
```

The root test run repeats the filtering contract against a local WireGuard peer
and HTTP server, and checks overlap and cleanup of parallel probes and setup failures.
The twenty-endpoint fixture uses aliases of one server serially, since simultaneous
connections with the same client key to one WireGuard peer would interfere with each other.
It does not contact NordVPN. Kernel tests are explicitly skipped in the ordinary
test run.
