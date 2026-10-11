#!/usr/bin/env python3
"""
NordVPN WireGuard Configuration Extractor
Extracts WireGuard configuration files from NordVPN's API,
or lists peer endpoints for an existing peerEndpoint field.
Uses only Python standard library (no external dependencies).
"""

import argparse
import base64
import json
import os
import subprocess
import sys
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from ipaddress import IPv4Address
from pathlib import Path
from typing import Optional, Protocol
from urllib.request import Request, urlopen
from urllib.parse import urlencode
from urllib.error import URLError, HTTPError


@dataclass(frozen=True)
class WireGuardPeer:
    endpoint: str
    public_key: str


@dataclass(frozen=True)
class EndpointCandidate:
    hostname: str
    peer: WireGuardPeer


@dataclass(frozen=True)
class ConnectivityResult:
    reachable: bool
    detail: str


class ConnectivityChecker(Protocol):
    def check(self, peer: WireGuardPeer) -> ConnectivityResult:
        ...


class WireGuardConnectivityChecker:
    DEFAULT_TIMEOUT_SECONDS = 8
    DEFAULT_FWMARK = 51820
    PROBE_URL = "https://1.1.1.1/cdn-cgi/trace"
    CLIENT_ADDRESS = "10.5.0.2/32"
    COMMAND_TIMEOUT_SECONDS = 10

    def __init__(self, private_key_file: Path, timeout_seconds: int,
                 fwmark: int, probe_url: str):
        self.private_key_file = private_key_file
        self.timeout_seconds = timeout_seconds
        self.fwmark = fwmark
        self.probe_url = probe_url

    def _run(self, command: list[str]) -> str:
        return subprocess.run(
            command, check=True, capture_output=True, text=True,
            timeout=self.COMMAND_TIMEOUT_SECONDS,
        ).stdout

    def check(self, peer: WireGuardPeer) -> ConnectivityResult:
        identifier = uuid.uuid4().hex[:8]
        namespace = f"nordcheck-{identifier}"
        interface = f"nc{identifier}"
        namespace_created = False
        interface_created = False
        interface_moved = False
        try:
            self._run(["ip", "netns", "add", namespace])
            namespace_created = True
            self._run(["ip", "link", "add", interface, "type", "wireguard"])
            interface_created = True
            self._run([
                "wg", "set", interface, "private-key", str(self.private_key_file),
                "fwmark", str(self.fwmark), "peer", peer.public_key,
                "endpoint", peer.endpoint, "allowed-ips", "0.0.0.0/0",
            ])
            self._run(["ip", "link", "set", interface, "netns", namespace])
            interface_moved = True
            self._run(["ip", "-n", namespace, "link", "set", "lo", "up"])
            self._run([
                "ip", "-n", namespace, "address", "add", self.CLIENT_ADDRESS,
                "dev", interface,
            ])
            self._run(["ip", "-n", namespace, "link", "set", interface, "up"])
            self._run([
                "ip", "-n", namespace, "route", "add", "default", "dev", interface,
            ])
            probe = subprocess.run(
                [
                    "ip", "netns", "exec", namespace, "curl", "--noproxy", "*",
                    "-4", "--fail", "--silent", "--show-error",
                    "--connect-timeout", str(self.timeout_seconds),
                    "--max-time", str(self.timeout_seconds), self.probe_url,
                ],
                capture_output=True, text=True, timeout=self.timeout_seconds + 2,
            )
            handshakes = self._run([
                "ip", "netns", "exec", namespace, "wg", "show", interface,
                "latest-handshakes",
            ])
            public_key, timestamp = handshakes.strip().split()
            if public_key != peer.public_key:
                raise ValueError("Connectivity probe returned an unexpected WireGuard peer")
            if int(timestamp) == 0:
                return ConnectivityResult(False, "no WireGuard handshake")
            if probe.returncode != 0:
                return ConnectivityResult(False, f"tunnel request failed: {probe.stderr.strip()}")
            addresses = [
                line.removeprefix("ip=") for line in probe.stdout.splitlines()
                if line.startswith("ip=")
            ]
            if len(addresses) != 1:
                return ConnectivityResult(False, "tunnel response has no unique exit IP")
            exit_ip = IPv4Address(addresses[0])
            return ConnectivityResult(True, f"handshake and tunnel request passed; exit IP {exit_ip}")
        finally:
            try:
                if interface_created and not interface_moved:
                    self._run(["ip", "link", "del", interface])
            finally:
                if namespace_created:
                    self._run(["ip", "netns", "del", namespace])


class NordVPNConfigExtractor:
    """Handles extraction of NordVPN WireGuard configurations."""

    CREDENTIALS_URL = "https://api.nordvpn.com/v1/users/services/credentials"
    SERVER_RECOMMENDATIONS_URL = "https://api.nordvpn.com/v1/servers/recommendations"
    SERVER_CATALOGUE_URL = "https://api.nordvpn.com/v1/servers"
    COUNTRIES_URL = "https://api.nordvpn.com/v1/servers/countries"
    DEFAULT_DNS = "194.242.2.4, 94.140.14.14"
    WG_PORT = 51820
    SERVER_PAGE_SIZE = 1000

    def __init__(self, access_token: str = ""):
        """Initialize with access token (required only for full config extraction)."""
        self.access_token = access_token
        self._country_map = None

    def _make_request(self, url: str, auth: bool = False) -> dict:
        """
        Make HTTP GET request using urllib.

        Args:
            url: URL to request
            auth: Whether to include basic authentication

        Returns:
            Parsed JSON response
        """
        try:
            request = Request(url)
            if auth:
                credentials = base64.b64encode(
                    f"token:{self.access_token}".encode()
                ).decode()
                request.add_header("Authorization", f"Basic {credentials}")

            with urlopen(request) as response:
                data = response.read().decode('utf-8')
                return json.loads(data)
        except HTTPError as e:
            print(f"HTTP Error {e.code}: {e.reason}", file=sys.stderr)
            sys.exit(1)
        except URLError as e:
            print(f"URL Error: {e.reason}", file=sys.stderr)
            sys.exit(1)
        except json.JSONDecodeError as e:
            print(f"JSON decode error: {e}", file=sys.stderr)
            sys.exit(1)

    def get_private_key(self) -> str:
        """Retrieve NordLynx private key from API."""
        try:
            data = self._make_request(self.CREDENTIALS_URL, auth=True)
            return data["nordlynx_private_key"]
        except KeyError:
            print("Error: Could not find nordlynx_private_key in response", file=sys.stderr)
            sys.exit(1)

    def _get_country_id(self, country_code: str) -> Optional[int]:
        """
        Get numeric country ID from country code.

        Args:
            country_code: 2-letter country code (e.g., 'us', 'nl', 'uk')

        Returns:
            Numeric country ID or None if not found
        """
        if self._country_map is None:
            try:
                countries = self._make_request(self.COUNTRIES_URL, auth=False)
                self._country_map = {
                    country["code"].lower(): country["id"] for country in countries
                }
            except Exception as e:
                print(f"Error fetching country list: {e}", file=sys.stderr)
                return None
        return self._country_map.get(country_code.lower())

    def get_server_recommendations(
        self,
        limit: int,
        country: Optional[str] = None
    ) -> list:
        """
        Get server recommendations from NordVPN API.

        Args:
            limit: Number of servers to retrieve
            country: Optional country code to filter by (e.g., 'us', 'uk', 'de')
        """
        params = {
            "filters[servers_technologies][identifier]": "wireguard_udp",
            "limit": str(limit)
        }
        if country:
            country_id = self._get_country_id(country)
            if country_id is None:
                print(f"Warning: Country code '{country}' not found. Getting recommendations without country filter.", file=sys.stderr)
            else:
                params["filters[country_id]"] = str(country_id)

        url = f"{self.SERVER_RECOMMENDATIONS_URL}?{urlencode(params)}"
        return self._make_request(url, auth=False)

    def get_servers(self, country: Optional[str]) -> list:
        params = {
            "filters[servers_technologies][identifier]": "wireguard_udp",
            "limit": str(self.SERVER_PAGE_SIZE),
        }
        if country:
            country_id = self._get_country_id(country)
            if country_id is None:
                raise ValueError(f"Country code '{country}' not found")
            params["filters[country_id]"] = str(country_id)
        servers = []
        while True:
            params["offset"] = str(len(servers))
            page = self._make_request(f"{self.SERVER_CATALOGUE_URL}?{urlencode(params)}", auth=False)
            servers.extend(page)
            if len(page) < self.SERVER_PAGE_SIZE:
                return sorted(servers, key=lambda server: server["load"])

    def create_config(
        self,
        server: dict,
        private_key: str,
        dns: str = DEFAULT_DNS
    ) -> tuple[str, str]:
        """
        Create WireGuard configuration from server data.

        Returns:
            Tuple of (filename, config_content)
        """
        country_name = server["locations"][0]["country"]["name"]
        city_name = server["locations"][0]["country"]["city"]["name"]
        hostname = server["hostname"]
        endpoint = self.peer_endpoint(server)

        public_key = self.peer_public_key(server)

        filename = f"{country_name} - {city_name} - {hostname}.conf"

        config = f"""# {filename}
[Interface]
PrivateKey = {private_key}
Address = 10.5.0.2/32
DNS = {dns}

[Peer]
PublicKey = {public_key}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = {endpoint}
"""
        return filename, config

    @classmethod
    def peer_endpoint(cls, server: dict) -> str:
        """Return host:port suitable for a WireGuard peerEndpoint field."""
        return f"{server['station']}:{cls.WG_PORT}"

    @staticmethod
    def peer_public_key(server: dict) -> str:
        for technology in server["technologies"]:
            if technology["identifier"] == "wireguard_udp":
                for metadata in technology["metadata"]:
                    if metadata["name"] == "public_key" and metadata["value"]:
                        return metadata["value"]
        raise ValueError(f"No WireGuard public key found for {server['hostname']}")

    def list_countries(self):
        """List all available countries with their codes."""
        try:
            countries = self._make_request(self.COUNTRIES_URL, auth=False)
            print("Available countries:")
            print("-" * 40)
            sorted_countries = sorted(countries, key=lambda x: x["name"])
            for country in sorted_countries:
                print(f"{country['code']:3s} - {country['name']}")
        except Exception as e:
            print(f"Error fetching country list: {e}", file=sys.stderr)
            sys.exit(1)

    def extract_configs(
        self,
        total_configs: int = 3,
        country: Optional[str] = None,
        dns: str = DEFAULT_DNS,
        output_dir: str = "."
    ):
        """
        Extract WireGuard configurations and save to files.

        Args:
            total_configs: Number of configurations to extract
            country: Optional country code to filter by
            dns: DNS servers to use
            output_dir: Directory to save configuration files
        """
        print(f"Fetching private key...", file=sys.stderr)
        private_key = self.get_private_key()

        print(
            f"Fetching server recommendations (limit: {total_configs}"
            + (f", country: {country.upper()}" if country else "")
            + ")...",
            file=sys.stderr,
        )
        servers = self.get_server_recommendations(total_configs, country)

        if not servers:
            print("No servers found matching criteria", file=sys.stderr)
            return

        print(f"Found {len(servers)} server(s)", file=sys.stderr)

        os.makedirs(output_dir, exist_ok=True)

        for i, server in enumerate(servers, 1):
            try:
                filename, config = self.create_config(server, private_key, dns)
                filepath = os.path.join(output_dir, filename)
                with open(filepath, "w") as f:
                    f.write(config)
                print(f"[{i}/{len(servers)}] Created: {filename}", file=sys.stderr)
            except Exception as e:
                print(f"Error creating config for server: {e}", file=sys.stderr)
                continue

    def list_endpoints(
        self,
        total: int,
        country: Optional[str],
        checker: Optional[ConnectivityChecker],
        jobs: int,
    ):
        """
        Print recommended peer endpoints (host:port), one per line on stdout.

        Intended for pasting into an existing WireGuard peerEndpoint field
        without rewriting full config files. Progress goes to stderr so the
        stdout stream stays machine-readable.
        """
        if total <= 0:
            raise ValueError("Endpoint count must be positive")
        if jobs <= 0:
            raise ValueError("Connectivity check jobs must be positive")
        if checker is None:
            servers = self.get_server_recommendations(total, country)
            if not servers:
                raise ValueError("No servers found matching criteria")
            print("\n".join(self.peer_endpoint(server) for server in servers[:total]))
            return
        print(
            "Fetching full WireGuard server catalogue"
            + (f" (country: {country.upper()})" if country else "")
            + "...", file=sys.stderr,
        )
        servers = self.get_servers(country)
        print(f"Found {len(servers)} candidate server(s)", file=sys.stderr)
        checked: set[str] = set()
        accepted: list[str] = []
        candidates: list[EndpointCandidate] = []
        seen: set[str] = set()
        for server in servers:
            endpoint = self.peer_endpoint(server)
            if endpoint in seen:
                continue
            seen.add(endpoint)
            candidates.append(EndpointCandidate(
                server["hostname"], WireGuardPeer(endpoint, self.peer_public_key(server)),
            ))
        with ThreadPoolExecutor(max_workers=jobs) as executor:
            for offset in range(0, len(candidates), jobs):
                batch = candidates[offset:offset + jobs]
                checked.update(candidate.peer.endpoint for candidate in batch)
                results = executor.map(checker.check, (candidate.peer for candidate in batch))
                for candidate, result in zip(batch, results):
                    endpoint = candidate.peer.endpoint
                    status = "PASS" if result.reachable else "FAIL"
                    print(f"{candidate.hostname} {endpoint}: {status} ({result.detail})", file=sys.stderr)
                    if result.reachable and len(accepted) < total:
                        accepted.append(endpoint)
                if len(accepted) == total:
                    break
        if not accepted:
            raise ValueError("No reachable WireGuard endpoints found")
        if len(accepted) < total:
            print(
                f"Warning: Only {len(accepted)} of {total} requested endpoints passed connectivity checks "
                f"after testing all {len(checked)} distinct candidates; writing the smaller list",
                file=sys.stderr,
            )
        print("\n".join(accepted))
        print(f"Confirmed {len(accepted)} endpoints after testing {len(checked)} candidates", file=sys.stderr)


def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description="Extract NordVPN WireGuard configurations or peer endpoints",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # List available countries
  %(prog)s --list-countries

  # List peer endpoints only (no token, no files) — paste into peerEndpoint
  %(prog)s --endpoints
  %(prog)s --endpoints --country nl --count 10

  # Set access token as environment variable
  export NORDVPN_ACCESS_TOKEN="your_token_here"

  # Extract 3 configs from any country
  %(prog)s

  # Extract 5 configs from United States
  %(prog)s --country us --count 5

  # Extract configs to specific directory
  %(prog)s --country uk --output ./configs

Common country codes: us, uk, de, fr, nl, ca, au, jp, etc.
"""
    )
    parser.add_argument(
        "--list-countries",
        action="store_true",
        help="List all available country codes and exit"
    )
    parser.add_argument(
        "--endpoints",
        action="store_true",
        help=(
            "Print recommended peer endpoints (host:port) to stdout instead of "
            "writing config files; does not require an access token"
        ),
    )
    parser.add_argument(
        "--token",
        help="NordVPN access token (or set NORDVPN_ACCESS_TOKEN env variable)",
        default=os.environ.get("NORDVPN_ACCESS_TOKEN")
    )
    parser.add_argument(
        "--check", action="store_true",
        help="Check --endpoints with an isolated WireGuard tunnel; requires Linux and root",
    )
    parser.add_argument(
        "--private-key-file", type=Path,
        help="NordLynx private-key file for --check (never printed)",
    )
    parser.add_argument(
        "--check-timeout", type=int,
        default=WireGuardConnectivityChecker.DEFAULT_TIMEOUT_SECONDS,
        help="Seconds allowed for each tunnel request (default: 8)",
    )
    parser.add_argument(
        "--fwmark", type=lambda value: int(value, 0),
        default=WireGuardConnectivityChecker.DEFAULT_FWMARK,
        help="Probe UDP socket mark; match the host VPN mark if active (default: 51820)",
    )
    available_cpus = len(os.sched_getaffinity(0)) if sys.platform == "linux" else (os.cpu_count() or 1)
    parser.add_argument(
        "--jobs", type=int, default=available_cpus,
        help="Maximum concurrent connectivity checks (default: available CPUs (%(default)s)); use 1 for serial checks",
    )
    parser.add_argument(
        "--country", "-c",
        help="Filter by country code (e.g., us, uk, de)",
        type=str
    )
    parser.add_argument(
        "--count", "-n",
        help="Number of configurations/endpoints to extract; with --check, target passing count (default: 3)",
        type=int,
        default=3
    )
    parser.add_argument(
        "--dns",
        help=f"DNS servers (default: {NordVPNConfigExtractor.DEFAULT_DNS})",
        default=NordVPNConfigExtractor.DEFAULT_DNS
    )
    parser.add_argument(
        "--output", "-o",
        help="Output directory for config files (default: current directory)",
        default="."
    )
    args = parser.parse_args()

    if args.jobs <= 0:
        parser.error("--jobs must be positive")
    if args.check:
        if not args.endpoints or args.list_countries:
            parser.error("--check requires --endpoints and cannot be used with --list-countries")
        if args.private_key_file is None:
            parser.error("--check requires --private-key-file")
        if sys.platform != "linux" or os.geteuid() != 0:
            parser.error("--check requires Linux and root privileges; run with sudo")
        if not args.private_key_file.is_file():
            parser.error("--private-key-file must name an existing file")
        if args.check_timeout <= 0:
            parser.error("--check-timeout must be positive")
        if not 0 <= args.fwmark <= 0xFFFFFFFF:
            parser.error("--fwmark must be an unsigned 32-bit value")
    elif args.private_key_file is not None:
        parser.error("--private-key-file requires --check")

    if args.list_countries:
        extractor = NordVPNConfigExtractor()
        extractor.list_countries()
        sys.exit(0)

    if args.endpoints:
        extractor = NordVPNConfigExtractor()
        checker = None
        if args.check:
            checker = WireGuardConnectivityChecker(
                args.private_key_file.resolve(), args.check_timeout,
                args.fwmark, WireGuardConnectivityChecker.PROBE_URL,
            )
        try:
            extractor.list_endpoints(total=args.count, country=args.country, checker=checker, jobs=args.jobs)
        except (ValueError, OSError, subprocess.SubprocessError) as error:
            if isinstance(error, subprocess.CalledProcessError):
                if "private-key" in error.cmd:
                    detail = "WireGuard configuration failed; check the private-key file and peer metadata"
                else:
                    detail = error.stderr.strip()
            else:
                detail = str(error)
            print(f"Error: {detail}", file=sys.stderr)
            sys.exit(1)
        except KeyboardInterrupt:
            print("Connectivity check interrupted", file=sys.stderr)
            sys.exit(130)
        sys.exit(0)

    if not args.token:
        print(
            "Error: Access token required. Provide via --token or "
            "NORDVPN_ACCESS_TOKEN environment variable",
            file=sys.stderr,
        )
        sys.exit(1)

    extractor = NordVPNConfigExtractor(args.token)
    extractor.extract_configs(
        total_configs=args.count,
        country=args.country,
        dns=args.dns,
        output_dir=args.output
    )
    print("\nDone!", file=sys.stderr)


if __name__ == "__main__":
    main()
