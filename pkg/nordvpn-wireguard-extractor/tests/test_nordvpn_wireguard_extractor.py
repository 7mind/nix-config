import contextlib
import io
import json
import os
import select
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
import uuid
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Optional
from urllib.parse import parse_qs, urlsplit

from nordvpn_wireguard_extractor import (
    ConnectivityChecker,
    ConnectivityResult,
    NordVPNConfigExtractor,
    WireGuardConnectivityChecker,
    WireGuardPeer,
)


class DummyChecker:
    def __init__(self, reachable: list[WireGuardPeer]):
        self.reachable = reachable

    def check(self, peer: WireGuardPeer) -> ConnectivityResult:
        return ConnectivityResult(peer in self.reachable, "dummy connectivity result")


class OverlappingChecker:
    OVERLAP_TIMEOUT_SECONDS = 2

    def __init__(self, checker: ConnectivityChecker):
        self.checker = checker
        self.barrier = threading.Barrier(2)

    def check(self, peer: WireGuardPeer) -> ConnectivityResult:
        try:
            self.barrier.wait(timeout=self.OVERLAP_TIMEOUT_SECONDS)
        except threading.BrokenBarrierError as error:
            raise RuntimeError("Connectivity checks did not overlap") from error
        return self.checker.check(peer)


@dataclass(frozen=True)
class CheckerFixture:
    checker: ConnectivityChecker
    reachable: list[WireGuardPeer]
    unreachable: WireGuardPeer
    jobs: int


class FixtureExtractor(NordVPNConfigExtractor):
    def __init__(self, peers: list[WireGuardPeer]):
        super().__init__()
        self.peers = peers

    def get_server_recommendations(self, limit: int, country: Optional[str]) -> list:
        return self.get_servers(country)[:limit]

    def get_servers(self, country: Optional[str]) -> list:
        return [
            {
                "hostname": f"server-{index}",
                "endpoint": peer.endpoint,
                "technologies": [{
                    "identifier": "wireguard_udp",
                    "metadata": [
                        {"name": "unrelated", "value": "not-a-public-key"},
                        {"name": "public_key", "value": peer.public_key},
                    ],
                }],
            }
            for index, peer in enumerate(self.peers)
        ]

    @classmethod
    def peer_endpoint(cls, server: dict) -> str:
        return server["endpoint"]


class LimitedRecommendationsExtractor(FixtureExtractor):
    def get_server_recommendations(self, limit: int, country: Optional[str]) -> list:
        return super().get_server_recommendations(1, country)


class CatalogueFixture:
    def __init__(self, servers: list[dict]):
        self.servers = servers

    def response(self, url: str) -> list:
        parsed = urlsplit(url)
        if parsed.path.endswith("/countries"):
            return [{"id": 104, "code": "IE"}, {"id": 228, "code": "US"}]
        params = parse_qs(parsed.query)
        technology = params["filters[servers_technologies][identifier]"][0]
        servers = [
            server for server in self.servers
            if any(item["identifier"] == technology for item in server["technologies"])
        ]
        if "filters[country_id]" in params:
            country_id = int(params["filters[country_id]"][0])
            servers = [
                server for server in servers
                if any(location["country"]["id"] == country_id for location in server["locations"])
            ]
        offset = int(params["offset"][0])
        limit = int(params["limit"][0])
        return servers[offset:offset + limit]


class DummyCatalogueExtractor(NordVPNConfigExtractor):
    def __init__(self, catalogue: CatalogueFixture):
        super().__init__()
        self.catalogue = catalogue

    def _make_request(self, url: str, auth: bool) -> list:
        return self.catalogue.response(url)


class CatalogueContract:
    def extractor(self, servers: list[dict]) -> NordVPNConfigExtractor:
        raise NotImplementedError

    @staticmethod
    def server(identifier: int, country_id: int, technology: str) -> dict:
        return {
            "id": identifier, "load": identifier % 100,
            "locations": [{"country": {"id": country_id}}],
            "technologies": [{"identifier": technology}],
        }

    def test_reads_all_pages(self):
        servers = [
            self.server(index, 104, "wireguard_udp")
            for index in range(NordVPNConfigExtractor.SERVER_PAGE_SIZE + 1)
        ]
        result = self.extractor(servers).get_servers("ie")
        self.assertEqual(len(result), len(servers))
        self.assertEqual({server["id"] for server in result}, {server["id"] for server in servers})
        self.assertEqual([server["load"] for server in result], sorted(server["load"] for server in servers))

    def test_preserves_country_and_wireguard_filters(self):
        servers = [
            self.server(1, 104, "wireguard_udp"),
            self.server(2, 228, "wireguard_udp"),
            self.server(3, 104, "openvpn_udp"),
        ]
        result = self.extractor(servers).get_servers("ie")
        self.assertEqual([server["id"] for server in result], [1])

    def test_unknown_country_is_an_error(self):
        extractor = self.extractor([self.server(1, 104, "wireguard_udp")])
        with self.assertRaisesRegex(ValueError, "Country code 'zz' not found"):
            extractor.get_servers("zz")


class DummyCatalogueTests(CatalogueContract, unittest.TestCase):
    def extractor(self, servers: list[dict]) -> NordVPNConfigExtractor:
        return DummyCatalogueExtractor(CatalogueFixture(servers))


class HttpCatalogueTests(CatalogueContract, unittest.TestCase):
    def extractor(self, servers: list[dict]) -> NordVPNConfigExtractor:
        catalogue = CatalogueFixture(servers)

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                body = json.dumps(catalogue.response(self.path)).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, format: str, *args):
                pass

        server = HTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(thread.join)
        self.addCleanup(server.shutdown)
        extractor = NordVPNConfigExtractor()
        base_url = f"http://127.0.0.1:{server.server_port}"
        extractor.SERVER_CATALOGUE_URL = f"{base_url}/servers"
        extractor.COUNTRIES_URL = f"{base_url}/countries"
        return extractor


class EndpointListingContract:
    def fixture(self) -> CheckerFixture:
        raise NotImplementedError

    def test_collects_twenty_endpoints_after_failed_candidates(self):
        fixture = self.fixture()
        extractor = FixtureExtractor([fixture.unreachable, *fixture.reachable])
        output = io.StringIO()
        progress = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(progress):
            extractor.list_endpoints(20, "ie", fixture.checker, fixture.jobs)
        self.assertEqual(output.getvalue().splitlines(), [peer.endpoint for peer in fixture.reachable])
        self.assertIn("FAIL", progress.getvalue())
        self.assertIn("PASS", progress.getvalue())

    def test_checks_catalogue_beyond_recommendations(self):
        fixture = self.fixture()
        extractor = LimitedRecommendationsExtractor([fixture.unreachable, *fixture.reachable])
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
            extractor.list_endpoints(20, "ie", fixture.checker, fixture.jobs)
        self.assertEqual(output.getvalue().splitlines(), [peer.endpoint for peer in fixture.reachable])

    def test_insufficient_distinct_endpoints_returns_smaller_list_with_warning(self):
        fixture = self.fixture()
        extractor = FixtureExtractor([
            fixture.reachable[0], fixture.reachable[0], fixture.unreachable,
        ])
        output = io.StringIO()
        progress = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(progress):
            extractor.list_endpoints(2, "ie", fixture.checker, fixture.jobs)
        self.assertEqual(output.getvalue(), fixture.reachable[0].endpoint + "\n")
        self.assertIn("Warning: Only 1 of 2 requested endpoints", progress.getvalue())

    def test_all_unreachable_is_an_error_with_empty_stdout(self):
        fixture = self.fixture()
        extractor = FixtureExtractor([fixture.unreachable])
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaisesRegex(ValueError, "No reachable WireGuard endpoints"):
                extractor.list_endpoints(1, "ie", fixture.checker, fixture.jobs)
        self.assertEqual(output.getvalue(), "")

    def test_parallel_checks_overlap(self):
        fixture = self.fixture()
        extractor = FixtureExtractor([fixture.unreachable, fixture.reachable[0]])
        output = io.StringIO()
        checker = OverlappingChecker(fixture.checker)
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
            extractor.list_endpoints(1, "ie", checker, 2)
        self.assertEqual(output.getvalue(), fixture.reachable[0].endpoint + "\n")

    def test_listing_without_checks_keeps_all_candidates(self):
        fixture = self.fixture()
        extractor = FixtureExtractor([fixture.unreachable, fixture.reachable[0]])
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
            extractor.list_endpoints(2, "ie", None, fixture.jobs)
        self.assertEqual(output.getvalue().splitlines(), [
            fixture.unreachable.endpoint, fixture.reachable[0].endpoint,
        ])


class DummyEndpointListingTests(EndpointListingContract, unittest.TestCase):
    def fixture(self) -> CheckerFixture:
        reachable = [
            WireGuardPeer(f"127.0.0.{index}:51820", "working-key")
            for index in range(1, 21)
        ]
        unreachable = WireGuardPeer("149.34.243.41:51820", "unreachable-key")
        return CheckerFixture(DummyChecker(reachable), reachable, unreachable, 4)


class ProbeHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"ip=10.5.0.2\n"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

class KernelEndpointListingTests(EndpointListingContract, unittest.TestCase):
    @classmethod
    def run_command(cls, command: list[str], input_text: str) -> str:
        return subprocess.run(
            command, input=input_text, text=True, capture_output=True,
            check=True, timeout=10,
        ).stdout.strip()

    @classmethod
    def setUpClass(cls):
        if os.environ.get("NORDVPN_TEST_KERNEL") != "1":
            raise unittest.SkipTest("set NORDVPN_TEST_KERNEL=1 to run real WireGuard tests as root")
        if sys.platform != "linux" or os.geteuid() != 0:
            raise RuntimeError("NORDVPN_TEST_KERNEL=1 requires Linux and root")
        cls.directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.directory.cleanup)
        cls.private_key_file = Path(cls.directory.name) / "client.key"
        cls.private_key_file.write_text(cls.run_command(["wg", "genkey"], ""))
        client_public_key = cls.run_command(["wg", "pubkey"], cls.private_key_file.read_text())
        server_key_file = Path(cls.directory.name) / "server.key"
        server_key_file.write_text(cls.run_command(["wg", "genkey"], ""))
        cls.public_key = cls.run_command(["wg", "pubkey"], server_key_file.read_text())
        identifier = uuid.uuid4().hex[:8]
        cls.namespace = f"nordtest-{identifier}"
        cls.interface = f"nt{identifier}"
        cls.interface_created = False
        cls.interface_moved = False
        cls.run_command(["ip", "netns", "add", cls.namespace], "")
        cls.addClassCleanup(cls.cleanup_network)
        cls.run_command(["ip", "link", "add", cls.interface, "type", "wireguard"], "")
        cls.interface_created = True
        cls.run_command([
            "wg", "set", cls.interface, "private-key", str(server_key_file),
            "listen-port", "0", "peer", client_public_key, "allowed-ips", "10.5.0.2/32",
        ], "")
        cls.run_command(["ip", "link", "set", cls.interface, "netns", cls.namespace], "")
        cls.interface_moved = True
        cls.run_command(["ip", "-n", cls.namespace, "link", "set", "lo", "up"], "")
        cls.run_command([
            "ip", "-n", cls.namespace, "address", "add", "10.5.0.1/24", "dev", cls.interface,
        ], "")
        cls.run_command(["ip", "-n", cls.namespace, "link", "set", cls.interface, "up"], "")
        port = cls.run_command([
            "ip", "netns", "exec", cls.namespace, "wg", "show", cls.interface, "listen-port",
        ], "")
        if int(port) == 0:
            raise RuntimeError("Local WireGuard server has no listening port after startup")
        cls.reachable = [
            WireGuardPeer(f"127.0.0.{index}:{port}", cls.public_key)
            for index in range(1, 21)
        ]
        cls.server = subprocess.Popen(
            ["ip", "netns", "exec", cls.namespace, sys.executable, str(Path(__file__).resolve()), "--serve-probe"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            env={**os.environ, "PYTHONPATH": str(Path(__file__).resolve().parents[1])},
        )
        cls.addClassCleanup(cls.cleanup_server)
        ready, _, _ = select.select([cls.server.stdout], [], [], 10)
        if not ready:
            raise RuntimeError("Local tunnel HTTP server did not start")
        startup_port = cls.server.stdout.readline()
        if not startup_port:
            _, error = cls.server.communicate(timeout=5)
            raise RuntimeError(f"Local tunnel HTTP server exited before startup: {error.strip()}")
        http_port = int(startup_port)
        cls.probe_url = f"http://10.5.0.1:{http_port}/"
        cls.unresponsive_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        cls.addClassCleanup(cls.unresponsive_socket.close)
        cls.unresponsive_socket.bind(("127.0.0.1", 0))
        cls.unreachable = WireGuardPeer(
            f"127.0.0.1:{cls.unresponsive_socket.getsockname()[1]}", cls.public_key,
        )

    @classmethod
    def cleanup_server(cls):
        cls.server.terminate()
        try:
            cls.server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            cls.server.kill()
            cls.server.wait(timeout=5)
        cls.server.stdout.close()
        cls.server.stderr.close()

    @classmethod
    def cleanup_network(cls):
        try:
            if cls.interface_created and not cls.interface_moved:
                cls.run_command(["ip", "link", "del", cls.interface], "")
        finally:
            cls.run_command(["ip", "netns", "del", cls.namespace], "")

    def fixture(self) -> CheckerFixture:
        checker = WireGuardConnectivityChecker(self.private_key_file, 2, 51820, self.probe_url)
        return CheckerFixture(checker, self.reachable, self.unreachable, 1)

    def test_parallel_checks_overlap(self):
        before = self.run_command(["ip", "netns", "list"], "")
        super().test_parallel_checks_overlap()
        self.assertEqual(self.run_command(["ip", "netns", "list"], ""), before)

    def test_failed_setup_removes_temporary_network(self):
        before = self.run_command(["ip", "netns", "list"], "")
        invalid_key = Path(self.directory.name) / "invalid.key"
        invalid_key.write_text("invalid-key")
        checker = WireGuardConnectivityChecker(invalid_key, 2, 51820, self.probe_url)
        with self.assertRaises(subprocess.CalledProcessError):
            checker.check(self.reachable[0])
        self.assertEqual(self.run_command(["ip", "netns", "list"], ""), before)

    def test_parallel_failed_setup_removes_temporary_network(self):
        before_namespaces = self.run_command(["ip", "netns", "list"], "")
        before_interfaces = self.run_command(["ip", "-o", "link", "show", "type", "wireguard"], "")
        invalid_key = Path(self.directory.name) / "invalid-parallel.key"
        invalid_key.write_text("invalid-key")
        checker = WireGuardConnectivityChecker(invalid_key, 2, 51820, self.probe_url)
        extractor = FixtureExtractor([self.unreachable, self.reachable[0]])
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(subprocess.CalledProcessError):
                extractor.list_endpoints(1, "ie", checker, 2)
        self.assertEqual(output.getvalue(), "")
        self.assertEqual(self.run_command(["ip", "netns", "list"], ""), before_namespaces)
        self.assertEqual(
            self.run_command(["ip", "-o", "link", "show", "type", "wireguard"], ""), before_interfaces,
        )

    def test_repeated_probes_remove_temporary_network(self):
        before = self.run_command(["ip", "netns", "list"], "")
        fixture = self.fixture()
        result = fixture.checker.check(fixture.reachable[0])
        self.assertTrue(result.reachable, f"{fixture.reachable[0].endpoint}: {result.detail}")
        self.assertFalse(fixture.checker.check(fixture.unreachable).reachable)
        self.assertEqual(self.run_command(["ip", "netns", "list"], ""), before)


class ExtractorValidationTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "linux", "CPU affinity is Linux-specific")
    def test_default_jobs_uses_available_cpu_count(self):
        result = subprocess.run(
            [sys.executable, "nordvpn_wireguard_extractor.py", "--help"],
            capture_output=True, text=True, timeout=5,
        )
        self.assertEqual(result.returncode, 0)
        self.assertIn(
            f"default: available CPUs ({len(os.sched_getaffinity(0))})",
            " ".join(result.stdout.split()),
        )

    def test_jobs_must_be_positive(self):
        result = subprocess.run(
            [sys.executable, "nordvpn_wireguard_extractor.py", "--endpoints", "--check", "--jobs", "0"],
            capture_output=True, text=True, timeout=5,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("--jobs must be positive", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_missing_public_key_is_an_error(self):
        server = {"hostname": "invalid-server", "technologies": []}
        with self.assertRaisesRegex(ValueError, "No WireGuard public key"):
            NordVPNConfigExtractor.peer_public_key(server)

    def test_check_requires_private_key_without_requesting_api(self):
        result = subprocess.run(
            [sys.executable, "nordvpn_wireguard_extractor.py", "--endpoints", "--check"],
            capture_output=True, text=True, timeout=5,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("--check requires --private-key-file", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_check_requires_endpoint_mode(self):
        result = subprocess.run(
            [sys.executable, "nordvpn_wireguard_extractor.py", "--check"],
            capture_output=True, text=True, timeout=5,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("--check requires --endpoints", result.stderr)


if __name__ == "__main__":
    if sys.argv[1:] == ["--serve-probe"]:
        server = HTTPServer(("10.5.0.1", 0), ProbeHandler)
        print(server.server_port, flush=True)
        server.serve_forever()
    else:
        unittest.main()
