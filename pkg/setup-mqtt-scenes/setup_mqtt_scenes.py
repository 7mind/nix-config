#!/usr/bin/env python3
"""Declarative zigbee2mqtt scene setup over MQTT.

Reconciles z2m group scenes against a JSON config: any scene declared in
the config that is not already present on the target group with a matching
(id, name) gets created via `scene_add`. Existing scenes are left alone
unless --force-update is passed (z2m's scene API doesn't expose stored
attribute values, so we can only dedupe on id+name without external state).
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
import time
from pathlib import Path
from threading import Event
from typing import Any

import paho.mqtt.client as mqtt
from paho.mqtt.enums import CallbackAPIVersion
from pydantic import BaseModel, ConfigDict, Field, ValidationError

logger = logging.getLogger("setup-mqtt-scenes")

BRIDGE_GROUPS_TOPIC = "zigbee2mqtt/bridge/groups"
DEFAULT_SETTLE_SECONDS = 0.4


class SceneSpec(BaseModel):
    """A single scene to (re)create on a z2m group."""

    model_config = ConfigDict(extra="forbid")

    id: int = Field(ge=1, le=255)
    name: str = Field(min_length=1)
    state: str = "ON"
    brightness: int | None = Field(default=None, ge=0, le=254)
    color_temp: int | None = Field(default=None, ge=153, le=500)
    transition: float = Field(default=0.0, ge=0.0)

    def to_scene_add_payload(self) -> dict[str, Any]:
        """Build the inner attrs of a `scene_add` MQTT command for z2m."""
        payload: dict[str, Any] = {
            "ID": self.id,
            "name": self.name,
            "transition": self.transition,
            "state": self.state,
        }
        if self.brightness is not None:
            payload["brightness"] = self.brightness
        if self.color_temp is not None:
            payload["color_temp"] = self.color_temp
        return payload


class GroupSpec(BaseModel):
    model_config = ConfigDict(extra="forbid")

    scenes: list[SceneSpec]


class Config(BaseModel):
    model_config = ConfigDict(extra="forbid")

    groups: dict[str, GroupSpec]


class ExistingScene(BaseModel):
    model_config = ConfigDict(extra="ignore")

    id: int
    name: str


class ExistingGroup(BaseModel):
    model_config = ConfigDict(extra="ignore")

    id: int
    friendly_name: str
    scenes: list[ExistingScene] = []


class Z2mClient:
    """Thin wrapper around paho-mqtt for the operations we need."""

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
            client_id="setup-mqtt-scenes",
        )
        self._client.username_pw_set(user, password)
        self._connected = Event()
        self._groups_event = Event()
        self._groups_payload: bytes | None = None
        self._client.on_connect = self._on_connect
        self._client.on_message = self._on_message
        logger.debug("connecting to %s:%d as %s", host, port, user)
        self._client.connect(host, port)
        self._client.loop_start()
        if not self._connected.wait(self._timeout_s):
            self.close()
            raise TimeoutError(f"MQTT connect did not complete within {self._timeout_s}s")

    def _on_connect(
        self,
        client: mqtt.Client,
        userdata: Any,
        flags: Any,
        reason_code: Any,
        properties: Any,
    ) -> None:
        if hasattr(reason_code, "is_failure") and reason_code.is_failure:
            logger.error("MQTT connect failed: %s", reason_code)
            return
        logger.debug("MQTT connected")
        self._connected.set()

    def _on_message(
        self,
        client: mqtt.Client,
        userdata: Any,
        message: mqtt.MQTTMessage,
    ) -> None:
        if message.topic == BRIDGE_GROUPS_TOPIC:
            self._groups_payload = message.payload
            self._groups_event.set()

    def fetch_groups(self) -> list[ExistingGroup]:
        """Subscribe to bridge/groups, wait for the retained message, parse."""
        self._groups_event.clear()
        self._groups_payload = None
        self._client.subscribe(BRIDGE_GROUPS_TOPIC, qos=1)
        if not self._groups_event.wait(self._timeout_s):
            raise TimeoutError(
                f"no message on {BRIDGE_GROUPS_TOPIC} within {self._timeout_s}s "
                "(is zigbee2mqtt running?)"
            )
        self._client.unsubscribe(BRIDGE_GROUPS_TOPIC)
        assert self._groups_payload is not None
        raw = json.loads(self._groups_payload)
        if not isinstance(raw, list):
            raise ValueError(
                f"unexpected payload shape on {BRIDGE_GROUPS_TOPIC}: {type(raw).__name__}"
            )
        return [ExistingGroup.model_validate(g) for g in raw]

    def add_scene(self, group_friendly_name: str, scene: SceneSpec) -> None:
        topic = f"zigbee2mqtt/{group_friendly_name}/set"
        payload = json.dumps({"scene_add": scene.to_scene_add_payload()})
        info = self._client.publish(topic, payload, qos=1)
        info.wait_for_publish(self._timeout_s)
        if not info.is_published():
            raise RuntimeError(f"publish to {topic} did not confirm within timeout")

    def close(self) -> None:
        self._client.loop_stop()
        self._client.disconnect()


def _scene_status(
    desired: SceneSpec, existing: ExistingScene | None, force_update: bool
) -> tuple[bool, str]:
    """Return (needs_action, reason)."""
    if existing is None:
        return True, "missing"
    if existing.name != desired.name:
        return True, f"name differs ({existing.name!r} -> {desired.name!r})"
    if force_update:
        return True, "force-update"
    return False, "already exists with matching id+name"


def reconcile(
    client: Z2mClient,
    config: Config,
    *,
    force_update: bool,
    dry_run: bool,
    settle_seconds: float,
) -> tuple[int, int]:
    """Reconcile scenes against config.

    Returns (touched, skipped).
    """
    existing_groups = client.fetch_groups()
    by_name = {g.friendly_name: g for g in existing_groups}

    touched = 0
    skipped = 0
    missing_groups: list[str] = []

    for group_name, group_spec in config.groups.items():
        existing_group = by_name.get(group_name)
        if existing_group is None:
            missing_groups.append(group_name)
            continue

        existing_by_id = {s.id: s for s in existing_group.scenes}

        for scene in group_spec.scenes:
            current = existing_by_id.get(scene.id)
            needs, reason = _scene_status(scene, current, force_update)

            if not needs:
                logger.info(
                    "[skip] %s/scene-%d %r: %s",
                    group_name,
                    scene.id,
                    scene.name,
                    reason,
                )
                skipped += 1
                continue

            verb = "[dry-run] would create" if dry_run else "create"
            logger.info(
                "%s %s/scene-%d %r (reason: %s) brightness=%s color_temp=%s",
                verb,
                group_name,
                scene.id,
                scene.name,
                reason,
                scene.brightness,
                scene.color_temp,
            )

            if not dry_run:
                client.add_scene(group_name, scene)
                touched += 1
                time.sleep(settle_seconds)

    if missing_groups:
        raise RuntimeError(
            f"these groups are not present in zigbee2mqtt: {missing_groups}; "
            "create them in the z2m frontend first"
        )

    return touched, skipped


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Declarative zigbee2mqtt scene setup over MQTT.",
    )
    parser.add_argument(
        "--config",
        type=Path,
        required=True,
        help="JSON config file describing groups and their scenes",
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
        "--force-update",
        action="store_true",
        help=(
            "Re-issue scene_add for every configured scene, even when a "
            "scene with the same id and name already exists"
        ),
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print what would be done; don't publish anything",
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
        help="Enable debug logging",
    )
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s %(message)s",
    )

    try:
        config_raw = json.loads(args.config.read_text())
    except OSError as e:
        logger.error("cannot read config: %s", e)
        return 2
    except json.JSONDecodeError as e:
        logger.error("config is not valid JSON: %s", e)
        return 2

    try:
        config = Config.model_validate(config_raw)
    except ValidationError as e:
        logger.error("config validation failed:\n%s", e)
        return 2

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
        client = Z2mClient(
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
        touched, skipped = reconcile(
            client,
            config,
            force_update=args.force_update,
            dry_run=args.dry_run,
            settle_seconds=DEFAULT_SETTLE_SECONDS,
        )
    except (TimeoutError, RuntimeError, ValueError) as e:
        logger.error("reconcile failed: %s", e)
        return 1
    finally:
        client.close()

    action_word = "would touch" if args.dry_run else "touched"
    logger.info("done; %s %d scene(s), skipped %d", action_word, touched, skipped)
    return 0


if __name__ == "__main__":
    sys.exit(main())
