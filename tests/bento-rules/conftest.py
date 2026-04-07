"""Pytest fixtures for bento end-to-end tests.

Each test gets:
  * a real mosquitto broker on an ephemeral port (fixture `mosquitto`)
  * a factory to launch bento against a config string (fixture `bento_runner`)
  * a paho-mqtt test client plus a thread-safe list of received messages
    (fixture `mqtt_client`)

Nothing is mocked. Configs are rendered into temp files with the broker's
port substituted for `{MQTT_HOST}` / `{MQTT_PORT}` placeholders.
"""

from __future__ import annotations

import contextlib
import os
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from threading import Lock
from typing import Any, Callable, Iterator

import paho.mqtt.client as mqtt
from paho.mqtt.enums import CallbackAPIVersion
import pytest


# ---------- small utilities ----------


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _wait_for_tcp(host: str, port: int, timeout_s: float = 5.0) -> None:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        try:
            with socket.create_connection((host, port), timeout=0.2):
                return
        except (ConnectionRefusedError, OSError):
            time.sleep(0.05)
    raise TimeoutError(f"nothing listening on {host}:{port} after {timeout_s}s")


# ---------- mosquitto fixture ----------


@pytest.fixture
def mosquitto() -> Iterator[tuple[str, int]]:
    """Boot a private mosquitto on an ephemeral port. Yields (host, port)."""
    host = "127.0.0.1"
    port = _free_port()
    with tempfile.TemporaryDirectory() as tmpdir:
        conf = Path(tmpdir) / "mosquitto.conf"
        conf.write_text(
            f"listener {port} {host}\n"
            "allow_anonymous true\n"
            "persistence false\n"
            "log_type none\n"
            "log_dest none\n"
        )
        proc = subprocess.Popen(
            ["mosquitto", "-c", str(conf)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            _wait_for_tcp(host, port)
            yield (host, port)
        finally:
            proc.terminate()
            with contextlib.suppress(subprocess.TimeoutExpired):
                proc.wait(timeout=5)
            if proc.poll() is None:
                proc.kill()


# ---------- bento fixture ----------


BentoRunner = Callable[..., None]


def tz_for_target_local_hour(target_hour: int) -> str:
    """Return an IANA TZ identifier that makes Go's `time.Local`
    report the supplied local hour when the test runs.

    Go's `time` package accepts IANA zone names like
    `Etc/GMT-5` but does NOT parse POSIX TZ strings like `UTC-5`
    (it treats them as plain UTC). The `Etc/GMT±N` zones also use
    inverted signs per historical POSIX convention: `Etc/GMT-5`
    means UTC+5, and `Etc/GMT+5` means UTC-5.

    We compute the offset so that `(utc_hour + offset) % 24 ==
    target_hour`, then pick the right `Etc/GMT±N` zone depending
    on whether the offset fits in the positive or negative range.

    Used by tests that need to exercise time-of-day slot dispatch
    without waiting for the wall clock to reach a given hour.
    """
    assert 0 <= target_hour <= 23, f"target_hour must be 0..23, got {target_hour}"
    now_utc_hour = time.gmtime().tm_hour
    offset = (target_hour - now_utc_hour) % 24  # 0..23
    if offset == 0:
        return "UTC"
    if offset <= 12:
        # Desired shift is UTC+offset (up to +12), expressed as
        # Etc/GMT-offset (note the sign flip).
        return f"Etc/GMT-{offset}"
    # offset > 12: express as UTC-(24-offset) instead, i.e. shifting
    # backwards through midnight. Etc/GMT+N means UTC-N.
    return f"Etc/GMT+{24 - offset}"


def _wait_for_bento_ready(http_port: int, timeout_s: float = 10.0) -> None:
    """Poll bento's `/ready` endpoint until it returns 200.

    Bento exposes `/ready` once every input *and* output is connected,
    which for our tests means the MQTT input has subscribed to its
    topics. Polling this is what lets us drop the previous fixed
    `time.sleep(0.8)` — that sleep was both too long for fast
    machines and not always long enough on contended ones.
    """
    url = f"http://127.0.0.1:{http_port}/ready"
    deadline = time.time() + timeout_s
    last_err: Exception | None = None
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=0.3) as resp:
                if resp.status == 200:
                    return
        except (urllib.error.URLError, ConnectionError, TimeoutError, OSError) as e:
            last_err = e
        time.sleep(0.02)
    raise TimeoutError(
        f"bento /ready did not respond within {timeout_s}s "
        f"(last error: {last_err!r})"
    )


@pytest.fixture
def bento_runner(
    mosquitto: tuple[str, int], tmp_path: Path
) -> Iterator[BentoRunner]:
    """Factory: call with a bento YAML string (possibly containing
    `{MQTT_HOST}` / `{MQTT_PORT}` / `{HTTP_PORT}` placeholders) to
    start a bento instance against the fixture mosquitto. All
    instances are cleaned up after the test. Blocks until bento's
    `/ready` endpoint reports 200 before returning, so subsequent
    publishes can't race the input subscription.

    Each spawn gets a fresh ephemeral HTTP port — config builders
    must include an `http: enabled: true, address: 127.0.0.1:{HTTP_PORT}`
    block so the readiness probe has somewhere to land.

    Optional `tz` argument sets the `TZ` environment variable for the
    child bento process, which Go's `time` package reads at process
    start to populate `time.Local`. Use `tz_for_target_local_hour(h)`
    to compute a string that makes bento's `timestamp_unix().ts_format("15", "Local")`
    return a specific hour regardless of wall-clock time at test runtime.
    """
    host, port = mosquitto
    procs: list[subprocess.Popen[bytes]] = []

    def start(config_yaml: str, *, tz: str | None = None) -> None:
        http_port = _free_port()
        rendered = (
            config_yaml.replace("{MQTT_HOST}", host)
            .replace("{MQTT_PORT}", str(port))
            .replace("{HTTP_PORT}", str(http_port))
        )
        config_path = tmp_path / f"bento-{len(procs)}.yaml"
        config_path.write_text(rendered)
        env = os.environ.copy()
        if tz is not None:
            env["TZ"] = tz
        proc = subprocess.Popen(
            ["bento", "-c", str(config_path)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=env,
        )
        procs.append(proc)
        _wait_for_bento_ready(http_port)

    try:
        yield start
    finally:
        for proc in procs:
            proc.terminate()
            with contextlib.suppress(subprocess.TimeoutExpired):
                proc.wait(timeout=5)
            if proc.poll() is None:
                proc.kill()


# ---------- MQTT test client fixture ----------


class MqttInbox:
    """Thread-safe inbox for received MQTT messages, with helpers for
    waiting on expected counts."""

    def __init__(self) -> None:
        self._lock = Lock()
        self._messages: list[tuple[str, str]] = []

    def append(self, topic: str, payload: str) -> None:
        with self._lock:
            self._messages.append((topic, payload))

    def snapshot(self) -> list[tuple[str, str]]:
        with self._lock:
            return list(self._messages)

    def clear(self) -> None:
        with self._lock:
            self._messages.clear()

    def wait_for_count(self, topic: str, count: int, timeout_s: float = 5.0) -> None:
        deadline = time.time() + timeout_s
        while time.time() < deadline:
            with self._lock:
                got = sum(1 for t, _ in self._messages if t == topic)
            if got >= count:
                return
            time.sleep(0.02)
        raise AssertionError(
            f"expected {count} messages on {topic} within {timeout_s}s, "
            f"got {[m for m in self.snapshot() if m[0] == topic]}"
        )

    def payloads_on(self, topic: str) -> list[str]:
        with self._lock:
            return [p for t, p in self._messages if t == topic]

    def wait_silence(self, topic: str, for_s: float = 0.4) -> None:
        """Wait `for_s` seconds and assert no new messages arrived on
        `topic`. Useful for "no message expected" assertions."""
        before = len(self.payloads_on(topic))
        time.sleep(for_s)
        after = len(self.payloads_on(topic))
        assert before == after, (
            f"expected no new messages on {topic} during {for_s}s, "
            f"but got {self.payloads_on(topic)[before:]}"
        )


@pytest.fixture
def mqtt_client(mosquitto: tuple[str, int]) -> Iterator[tuple[mqtt.Client, MqttInbox]]:
    host, port = mosquitto
    inbox = MqttInbox()

    client = mqtt.Client(
        CallbackAPIVersion.VERSION2, client_id="test-bento-rules-client"
    )

    def _on_message(
        _client: mqtt.Client,
        _userdata: Any,
        message: mqtt.MQTTMessage,
    ) -> None:
        try:
            payload = message.payload.decode()
        except UnicodeDecodeError:
            payload = repr(message.payload)
        inbox.append(message.topic, payload)

    client.on_message = _on_message
    client.connect(host, port)
    client.loop_start()

    try:
        yield (client, inbox)
    finally:
        client.loop_stop()
        client.disconnect()
