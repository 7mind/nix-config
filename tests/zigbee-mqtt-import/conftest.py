"""Fixtures for zigbee_mqtt_import.py end-to-end tests.

Boots a real mosquitto on an ephemeral port and a tiny in-process
publisher that drops a retained `zigbee2mqtt/bridge/devices` payload
into the broker. The script-under-test then connects to the same
broker and reads back the retained list — no MQTT-layer mocking.
"""

from __future__ import annotations

import contextlib
import json
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Iterator

import paho.mqtt.client as mqtt
from paho.mqtt.enums import CallbackAPIVersion
import pytest


REPO_ROOT = Path(__file__).resolve().parents[2]
ZIGBEE_MQTT_IMPORT_DIR = REPO_ROOT / "pkg/zigbee-mqtt-import"

# Make `import zigbee_mqtt_import` work without invoking the wrapped
# binary. The directory is hyphenated so we cannot do a normal package
# import — add it to sys.path and import the bare module.
sys.path.insert(0, str(ZIGBEE_MQTT_IMPORT_DIR))


# ---------- mosquitto (kept independent of the bento-rules / hue-setup
# conftests so the three test directories don't depend on each other) ----------


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


@pytest.fixture
def mosquitto() -> Iterator[tuple[str, int]]:
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


# ---------- bridge/devices retained publisher ----------


def publish_bridge_devices(
    host: str, port: int, devices: list[dict[str, Any]]
) -> None:
    """Publish a retained `bridge/devices` payload and disconnect.

    Used by tests to seed the broker with whatever device list the
    script-under-test should observe. The retained flag means the
    script will receive the payload as soon as it subscribes, even
    though we've already disconnected.
    """
    client = mqtt.Client(
        CallbackAPIVersion.VERSION2,
        client_id="fake-z2m-bridge-devices-seeder",
    )
    client.connect(host, port)
    client.loop_start()
    info = client.publish(
        "zigbee2mqtt/bridge/devices",
        json.dumps(devices),
        qos=1,
        retain=True,
    )
    info.wait_for_publish(5.0)
    client.loop_stop()
    client.disconnect()
