#!/usr/bin/env python3
"""Dump the current zigbee2mqtt friendly_name → ieee_address mapping.

Connects to MQTT, reads the retained `zigbee2mqtt/bridge/devices`
topic, and writes a JSON object of the form

  { "<friendly_name>": "<ieee_address>", ... }

to stdout. Output is sorted by friendly_name for stable diffs so the
result can be checked into source control as the canonical mapping
that the rest of the hue tooling consumes.

Coordinator entries (z2m's own bridge endpoint) are skipped: they
don't represent a real device the user would ever rename, and
including them would force every consumer of the mapping to filter
the literal string "Coordinator" out of its address space.
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
from pathlib import Path
from threading import Event
from typing import Any

import paho.mqtt.client as mqtt
from paho.mqtt.enums import CallbackAPIVersion

logger = logging.getLogger("zigbee-mqtt-import")

BRIDGE_DEVICES_TOPIC = "zigbee2mqtt/bridge/devices"


class Z2mDevicesClient:
    """One-shot MQTT client that fetches the retained bridge/devices payload."""

    def __init__(
        self,
        host: str,
        port: int,
        user: str,
        password: str,
        timeout_s: float,
    ) -> None:
        self._timeout_s = timeout_s
        self._client = mqtt.Client(
            CallbackAPIVersion.VERSION2,
            client_id="zigbee-mqtt-import",
        )
        self._client.username_pw_set(user, password)

        self._connected = Event()
        self._payload_event = Event()
        self._payload: bytes | None = None

        self._client.on_connect = self._on_connect
        self._client.on_message = self._on_message

        logger.debug("connecting to %s:%d as %s", host, port, user)
        self._client.connect(host, port)
        self._client.loop_start()
        if not self._connected.wait(self._timeout_s):
            self.close()
            raise TimeoutError(
                f"MQTT connect did not complete within {self._timeout_s}s"
            )

    def _on_connect(
        self,
        client: mqtt.Client,
        _userdata: Any,
        _flags: Any,
        reason_code: Any,
        _properties: Any,
    ) -> None:
        if hasattr(reason_code, "is_failure") and reason_code.is_failure:
            logger.error("MQTT connect failed: %s", reason_code)
            return
        logger.debug("MQTT connected; subscribing to %s", BRIDGE_DEVICES_TOPIC)
        client.subscribe(BRIDGE_DEVICES_TOPIC, qos=1)
        self._connected.set()

    def _on_message(
        self,
        _client: mqtt.Client,
        _userdata: Any,
        message: mqtt.MQTTMessage,
    ) -> None:
        if message.topic != BRIDGE_DEVICES_TOPIC:
            return
        self._payload = message.payload
        self._payload_event.set()

    def fetch_devices(self) -> list[dict[str, Any]]:
        """Wait for the retained bridge/devices payload and parse it."""
        if not self._payload_event.wait(self._timeout_s):
            raise TimeoutError(
                f"no message on {BRIDGE_DEVICES_TOPIC} within {self._timeout_s}s "
                "(is zigbee2mqtt running?)"
            )
        assert self._payload is not None
        raw = json.loads(self._payload)
        if not isinstance(raw, list):
            raise ValueError(
                f"unexpected payload shape on {BRIDGE_DEVICES_TOPIC}: "
                f"{type(raw).__name__}"
            )
        # The list elements are arbitrary attrsets; we only consume two
        # fields downstream so a permissive cast is fine here.
        return [d for d in raw if isinstance(d, dict)]

    def close(self) -> None:
        self._client.loop_stop()
        self._client.disconnect()


def build_mapping(devices: list[dict[str, Any]]) -> dict[str, str]:
    """Reduce z2m's bridge/devices payload to {friendly_name: ieee_address}.

    Skips the coordinator and any entry that is missing either field.
    Raises on a duplicate friendly_name (z2m enforces uniqueness, so
    this is a corruption signal — surface it loudly rather than
    silently dropping a bulb on the floor).
    """
    mapping: dict[str, str] = {}
    for device in devices:
        if device.get("type") == "Coordinator":
            continue
        friendly_name = device.get("friendly_name")
        ieee_address = device.get("ieee_address")
        if not isinstance(friendly_name, str) or not isinstance(ieee_address, str):
            logger.debug(
                "skipping device entry with missing fields: %s",
                device,
            )
            continue
        if friendly_name in mapping:
            raise ValueError(
                f"duplicate friendly_name {friendly_name!r} in bridge/devices: "
                f"{mapping[friendly_name]} vs {ieee_address}"
            )
        mapping[friendly_name] = ieee_address
    return dict(sorted(mapping.items()))


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Dump the current zigbee2mqtt friendly_name → ieee_address "
            "mapping to stdout as JSON."
        ),
    )
    parser.add_argument("--mqtt-host", default="localhost")
    parser.add_argument("--mqtt-port", type=int, default=1883)
    parser.add_argument("--mqtt-user", default="mqtt")
    parser.add_argument(
        "--mqtt-password-file",
        type=Path,
        required=True,
        help="Path to a file containing the MQTT password",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=5.0,
        help="MQTT operation timeout in seconds",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="Enable debug logging on stderr",
    )
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.WARNING,
        format="%(levelname)s %(message)s",
        stream=sys.stderr,
    )

    try:
        password = args.mqtt_password_file.read_text().strip()
    except OSError as e:
        logger.error(
            "cannot read MQTT password file %s: %s (rerun with sudo?)",
            args.mqtt_password_file,
            e,
        )
        return 2

    try:
        client = Z2mDevicesClient(
            host=args.mqtt_host,
            port=args.mqtt_port,
            user=args.mqtt_user,
            password=password,
            timeout_s=args.timeout,
        )
    except (TimeoutError, OSError) as e:
        logger.error("MQTT connect failed: %s", e)
        return 1

    try:
        devices = client.fetch_devices()
    except (TimeoutError, ValueError) as e:
        logger.error("fetch failed: %s", e)
        return 1
    finally:
        client.close()

    try:
        mapping = build_mapping(devices)
    except ValueError as e:
        logger.error("%s", e)
        return 1

    json.dump(mapping, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
