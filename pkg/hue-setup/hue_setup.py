#!/usr/bin/env python3
"""Declarative zigbee2mqtt group and scene setup over MQTT.

Reconciles z2m groups and their member/scene state against a JSON config.

Additive by default:
  * Missing groups are created
  * Missing members are added
  * Missing scenes are created (dedup by group + id + name)

Destructive operations (removing members not in config, re-creating
scenes whose values might have changed) are opt-in via --prune and
--force-update respectively.
"""

from __future__ import annotations

import argparse
import itertools
import json
import logging
import sys
import time
from pathlib import Path
from threading import Event, Lock
from typing import Any, Callable, TypeVar

import paho.mqtt.client as mqtt
from paho.mqtt.enums import CallbackAPIVersion
from pydantic import BaseModel, ConfigDict, Field, ValidationError

logger = logging.getLogger("hue-setup")

BRIDGE_GROUPS_TOPIC = "zigbee2mqtt/bridge/groups"
BRIDGE_DEVICES_TOPIC = "zigbee2mqtt/bridge/devices"
BRIDGE_RESPONSE_PREFIX = "zigbee2mqtt/bridge/response/"

DEFAULT_SETTLE_SECONDS = 0.4


# ---------- Config models ----------


class SceneSpec(BaseModel):
    """A single scene to (re)create on a z2m group.

    `transition` is specified in **seconds**. z2m's `scene_add` converter
    has two code paths depending on whether the JSON value is an integer
    or a float (toZigbee.js around line 3907):

      - integer N -> issues `genScenes.add` with `transtime=N`
      - float F   -> issues `genScenes.enhancedAdd` with
                     `transtime=floor(F*10)`

    Hue bulbs only honor the transition correctly via enhancedAdd, so
    `to_scene_add_payload` forces a non-integer JSON encoding regardless
    of how the value was written in the source config.
    """

    model_config = ConfigDict(extra="forbid")

    id: int = Field(ge=1, le=255)
    name: str = Field(min_length=1)
    state: str = "ON"
    brightness: int | None = Field(default=None, ge=0, le=254)
    color_temp: int | None = Field(default=None, ge=153, le=500)
    transition: float = Field(default=0.0, ge=0.0)

    def to_scene_add_payload(self) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "ID": self.id,
            "name": self.name,
            # Sub-millisecond epsilon so `Number.isInteger` on the JS
            # side returns false and z2m routes to enhancedAdd. The
            # offset is well below the 1/10s resolution z2m floors.
            "transition": self.transition + 1e-4,
            "state": self.state,
        }
        if self.brightness is not None:
            payload["brightness"] = self.brightness
        if self.color_temp is not None:
            payload["color_temp"] = self.color_temp
        return payload


class GroupSpec(BaseModel):
    """A z2m group, its members, and its scenes.

    `members` is a list of `"ieee_address/endpoint"` strings. The
    endpoint is split off at API call time because z2m's
    `bridge/request/group/members/add` takes `device` and `endpoint`
    as separate fields.
    """

    model_config = ConfigDict(extra="forbid")

    id: int | None = Field(default=None, ge=1, le=255)
    members: list[str] = Field(default_factory=list)
    scenes: list[SceneSpec] = Field(default_factory=list)


class DeviceSpec(BaseModel):
    """Per-device z2m options to reconcile.

    `options` is an opaque attrset of attributes that get written via
    the device's `/set` topic when the live state doesn't already
    match. Each option is dedup-checked against the current state
    (via the device's retained state topic) so re-runs are no-ops if
    nothing has changed — important for sensors whose attribute
    writes hit on-device NVS (e.g. Hue motion sensors).
    """

    model_config = ConfigDict(extra="forbid")

    options: dict[str, Any] = Field(default_factory=dict)


class Config(BaseModel):
    model_config = ConfigDict(extra="forbid")

    groups: dict[str, GroupSpec]
    devices: dict[str, DeviceSpec] = Field(default_factory=dict)
    # Canonical mapping ieee_address → friendly_name. When non-empty,
    # the reconcile pass starts with a `reconcile_names` phase that
    # renames any z2m device whose current friendly_name doesn't match
    # this mapping (via `bridge/request/device/rename` with
    # `homeassistant_rename: true` so HA's entity ids follow). The
    # mapping is the source of truth for device naming across this
    # whole stack — Nix uses the same data to validate room references
    # and to render the bento source/target topics.
    name_by_address: dict[str, str] = Field(default_factory=dict)


# ---------- Existing-state models (parsed from bridge/groups) ----------


class ExistingMember(BaseModel):
    model_config = ConfigDict(extra="ignore")

    ieee_address: str
    endpoint: int

    def as_key(self) -> str:
        return f"{self.ieee_address}/{self.endpoint}"


class ExistingScene(BaseModel):
    model_config = ConfigDict(extra="ignore")

    id: int
    name: str


class ExistingGroup(BaseModel):
    model_config = ConfigDict(extra="ignore")

    id: int
    friendly_name: str
    members: list[ExistingMember] = []
    scenes: list[ExistingScene] = []


class ExistingDevice(BaseModel):
    """One entry from `zigbee2mqtt/bridge/devices`.

    z2m publishes a list of all paired devices on this retained topic;
    we only consume two fields, but extra="ignore" lets us tolerate
    schema additions without forcing a code update.
    """

    model_config = ConfigDict(extra="ignore")

    ieee_address: str
    friendly_name: str


# ---------- Response envelope ----------


class Z2mResponse(BaseModel):
    """Envelope for zigbee2mqtt/bridge/response/* messages."""

    model_config = ConfigDict(extra="allow")

    status: str
    data: Any = None
    error: str | None = None
    transaction: str | None = None


# ---------- Member key helpers ----------


def parse_member_key(member: str) -> tuple[str, int]:
    """Split `"0x.../11"` into `("0x...", 11)`."""
    if "/" not in member:
        raise ValueError(
            f"member {member!r} must be in the form 'ieee_address/endpoint'"
        )
    device, _, endpoint_str = member.rpartition("/")
    try:
        endpoint = int(endpoint_str)
    except ValueError as e:
        raise ValueError(
            f"member {member!r}: endpoint {endpoint_str!r} is not a number"
        ) from e
    return device, endpoint


def normalize_member_key(member: str, name_by_address: dict[str, str]) -> str:
    """Canonicalize a 'device/endpoint' key by translating any
    `0x...` device part to its friendly_name when an entry exists in
    name_by_address.

    Used by `reconcile_groups` to bring both sides of the member set
    diff into the same form before comparison. z2m's bridge/groups
    always returns members as ieee_address; the rendered hue-setup
    config (from `defineRooms`) always uses friendly names. Without
    this normalization the diff considers every member missing on
    one side and extra on the other, leading to redundant add/remove
    on every reconcile pass — and a permanent churn loop, since the
    next bridge/groups fetch would still report the ieee form.

    Falls back to the input string when:
      * the device part isn't in `0x` form (already canonical)
      * the device part is in `0x` form but not in name_by_address
        (the user knows about the device but hasn't named it; treat
        the bare ieee as the canonical form for this run)

    Malformed inputs (no '/') are returned unchanged so that
    downstream `parse_member_key` raises the precise error rather
    than this helper swallowing it.
    """
    if "/" not in member:
        return member
    device, _, endpoint = member.rpartition("/")
    if device.startswith("0x") and device in name_by_address:
        device = name_by_address[device]
    return f"{device}/{endpoint}"


# ---------- MQTT client ----------


class Z2mClient:
    """Thin wrapper around paho-mqtt for the operations we need.

    Subscribes at connect time to both `bridge/groups` (for inventory)
    and `bridge/response/#` (for correlated responses to our requests).
    Each request method publishes with a unique transaction id and blocks
    on an `Event` until the matching response arrives.
    """

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
            client_id="hue-setup",
        )
        self._client.username_pw_set(user, password)

        self._connected = Event()
        self._groups_event = Event()
        self._groups_payload: bytes | None = None
        self._devices_event = Event()
        self._devices_payload: bytes | None = None

        self._response_lock = Lock()
        self._response_events: dict[str, Event] = {}
        self._responses: dict[str, Z2mResponse] = {}

        self._retained_lock = Lock()
        self._retained_payloads: dict[str, bytes] = {}
        self._retained_events: dict[str, Event] = {}

        self._txn_lock = Lock()
        self._txn_counter = itertools.count(1)

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
        userdata: Any,
        flags: Any,
        reason_code: Any,
        properties: Any,
    ) -> None:
        if hasattr(reason_code, "is_failure") and reason_code.is_failure:
            logger.error("MQTT connect failed: %s", reason_code)
            return
        logger.debug("MQTT connected")
        client.subscribe(BRIDGE_GROUPS_TOPIC, qos=1)
        client.subscribe(BRIDGE_DEVICES_TOPIC, qos=1)
        client.subscribe(f"{BRIDGE_RESPONSE_PREFIX}#", qos=1)
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
            return
        if message.topic == BRIDGE_DEVICES_TOPIC:
            self._devices_payload = message.payload
            self._devices_event.set()
            return
        if message.topic.startswith(BRIDGE_RESPONSE_PREFIX):
            try:
                resp = Z2mResponse.model_validate_json(message.payload)
            except ValidationError:
                return
            if resp.transaction is None:
                return
            with self._response_lock:
                self._responses[resp.transaction] = resp
                event = self._response_events.get(resp.transaction)
            if event is not None:
                event.set()
            return
        # Generic retained-message dispatch for fetch_retained callers.
        with self._retained_lock:
            self._retained_payloads[message.topic] = message.payload
            event = self._retained_events.get(message.topic)
        if event is not None:
            event.set()

    def _next_transaction(self) -> str:
        with self._txn_lock:
            return f"hue-setup-{next(self._txn_counter)}"

    def _request(self, topic: str, payload: dict[str, Any]) -> Z2mResponse:
        """Publish a request with a fresh transaction id, wait for the
        matching response, raise on non-ok status.
        """
        txn = self._next_transaction()
        body = {**payload, "transaction": txn}
        event = Event()
        with self._response_lock:
            self._response_events[txn] = event
        try:
            info = self._client.publish(topic, json.dumps(body), qos=1)
            info.wait_for_publish(self._timeout_s)
            if not info.is_published():
                raise RuntimeError(
                    f"publish to {topic} did not confirm within {self._timeout_s}s"
                )
            if not event.wait(self._timeout_s):
                raise TimeoutError(
                    f"no response on bridge/response for {topic} "
                    f"(txn {txn}) within {self._timeout_s}s"
                )
            with self._response_lock:
                resp = self._responses.pop(txn)
            if resp.status != "ok":
                raise RuntimeError(
                    f"z2m rejected {topic}: {resp.error or 'unknown error'}"
                )
            return resp
        finally:
            with self._response_lock:
                self._response_events.pop(txn, None)

    def fetch_groups(self) -> list[ExistingGroup]:
        """Re-trigger a retained-message delivery on bridge/groups and parse."""
        self._groups_event.clear()
        self._groups_payload = None
        # Re-subscribing forces z2m/mosquitto to resend the retained message.
        self._client.unsubscribe(BRIDGE_GROUPS_TOPIC)
        self._client.subscribe(BRIDGE_GROUPS_TOPIC, qos=1)
        if not self._groups_event.wait(self._timeout_s):
            raise TimeoutError(
                f"no message on {BRIDGE_GROUPS_TOPIC} within {self._timeout_s}s "
                "(is zigbee2mqtt running?)"
            )
        assert self._groups_payload is not None
        raw = json.loads(self._groups_payload)
        if not isinstance(raw, list):
            raise ValueError(
                f"unexpected payload shape on {BRIDGE_GROUPS_TOPIC}: {type(raw).__name__}"
            )
        return [ExistingGroup.model_validate(g) for g in raw]

    def fetch_devices(self) -> list[ExistingDevice]:
        """Re-trigger a retained-message delivery on bridge/devices and parse.

        Skips entries that don't have both `ieee_address` and
        `friendly_name` (e.g. half-interviewed devices, the
        coordinator entry under some z2m versions). The reconcile
        phase only cares about devices we can address by ieee, so
        silently dropping the rest is fine.
        """
        self._devices_event.clear()
        self._devices_payload = None
        # Re-subscribing forces z2m/mosquitto to resend the retained message.
        self._client.unsubscribe(BRIDGE_DEVICES_TOPIC)
        self._client.subscribe(BRIDGE_DEVICES_TOPIC, qos=1)
        if not self._devices_event.wait(self._timeout_s):
            raise TimeoutError(
                f"no message on {BRIDGE_DEVICES_TOPIC} within {self._timeout_s}s "
                "(is zigbee2mqtt running?)"
            )
        assert self._devices_payload is not None
        raw = json.loads(self._devices_payload)
        if not isinstance(raw, list):
            raise ValueError(
                f"unexpected payload shape on {BRIDGE_DEVICES_TOPIC}: {type(raw).__name__}"
            )
        result: list[ExistingDevice] = []
        for entry in raw:
            if not isinstance(entry, dict):
                continue
            if "ieee_address" not in entry or "friendly_name" not in entry:
                continue
            result.append(ExistingDevice.model_validate(entry))
        return result

    def rename_device(self, current_name: str, new_name: str) -> None:
        """Rename a z2m device. `current_name` may be either the
        ieee_address or the current friendly_name; we always pass
        the ieee_address from the caller for unambiguity.

        `homeassistant_rename: true` triggers Home Assistant's
        entity-id rename machinery in the same request, so HA's
        entity ids follow the z2m friendly_name change without a
        separate API call.
        """
        self._request(
            "zigbee2mqtt/bridge/request/device/rename",
            {
                "from": current_name,
                "to": new_name,
                "homeassistant_rename": True,
            },
        )

    def add_group(self, friendly_name: str, group_id: int | None) -> None:
        payload: dict[str, Any] = {"friendly_name": friendly_name}
        if group_id is not None:
            # z2m expects id as string in the request body
            payload["id"] = str(group_id)
        self._request("zigbee2mqtt/bridge/request/group/add", payload)

    def remove_group(self, friendly_name: str, *, force: bool = True) -> None:
        self._request(
            "zigbee2mqtt/bridge/request/group/remove",
            {"id": friendly_name, "force": force},
        )

    def add_member(self, group_friendly_name: str, device: str, endpoint: int) -> None:
        self._request(
            "zigbee2mqtt/bridge/request/group/members/add",
            {"group": group_friendly_name, "device": device, "endpoint": endpoint},
        )

    def remove_member(
        self, group_friendly_name: str, device: str, endpoint: int
    ) -> None:
        self._request(
            "zigbee2mqtt/bridge/request/group/members/remove",
            {"group": group_friendly_name, "device": device, "endpoint": endpoint},
        )

    def add_scene(self, group_friendly_name: str, scene: SceneSpec) -> None:
        topic = f"zigbee2mqtt/{group_friendly_name}/set"
        payload = json.dumps({"scene_add": scene.to_scene_add_payload()})
        info = self._client.publish(topic, payload, qos=1)
        info.wait_for_publish(self._timeout_s)
        if not info.is_published():
            raise RuntimeError(
                f"publish to {topic} did not confirm within {self._timeout_s}s"
            )

    def fetch_retained(self, topic: str) -> bytes | None:
        """Subscribe to `topic`, wait for a (possibly retained) message,
        and return its payload. Returns None on timeout (e.g. no
        retained state ever published)."""
        event = Event()
        with self._retained_lock:
            self._retained_events[topic] = event
            self._retained_payloads.pop(topic, None)
        try:
            self._client.subscribe(topic, qos=1)
            if not event.wait(self._timeout_s):
                return None
            with self._retained_lock:
                return self._retained_payloads.get(topic)
        finally:
            self._client.unsubscribe(topic)
            with self._retained_lock:
                self._retained_events.pop(topic, None)
                self._retained_payloads.pop(topic, None)

    def fetch_device_state(self, friendly_name: str) -> dict[str, Any] | None:
        """Read the device's current state JSON from its retained
        zigbee2mqtt/<name> topic. Returns None if no retained state
        is available within the timeout."""
        payload = self.fetch_retained(f"zigbee2mqtt/{friendly_name}")
        if payload is None:
            return None
        try:
            parsed = json.loads(payload)
        except json.JSONDecodeError:
            return None
        if not isinstance(parsed, dict):
            return None
        return parsed

    def set_device_options(
        self, friendly_name: str, options: dict[str, Any]
    ) -> None:
        """Publish a single /set with the given attributes. z2m
        translates these into zigbee writeAttribute commands against
        the device, and the device persists them to its NVS."""
        topic = f"zigbee2mqtt/{friendly_name}/set"
        info = self._client.publish(topic, json.dumps(options), qos=1)
        info.wait_for_publish(self._timeout_s)
        if not info.is_published():
            raise RuntimeError(
                f"publish to {topic} did not confirm within {self._timeout_s}s"
            )

    def close(self) -> None:
        self._client.loop_stop()
        self._client.disconnect()


# ---------- Reconcile phases ----------


T = TypeVar("T")


def _fetch_with_retry(
    label: str,
    fetcher: Callable[[], T],
    fetch_attempts: int,
    fetch_retry_seconds: float,
) -> T:
    """Generic retry loop for the retained-topic fetchers.

    Used by both `fetch_groups` and `fetch_devices`. The retry path
    exists for early-boot races where z2m is up but hasn't yet
    published the retained inventory we want.
    """
    last_err: Exception | None = None
    for attempt in range(1, fetch_attempts + 1):
        try:
            return fetcher()
        except (TimeoutError, ValueError) as e:
            last_err = e
            logger.info(
                "%s attempt %d/%d failed (%s); retrying in %.1fs",
                label,
                attempt,
                fetch_attempts,
                e,
                fetch_retry_seconds,
            )
            time.sleep(fetch_retry_seconds)
    assert last_err is not None
    raise RuntimeError(
        f"could not {label} after {fetch_attempts} attempts: {last_err}"
    )


def reconcile_names(
    client: Z2mClient,
    config: Config,
    existing_devices: list[ExistingDevice],
    *,
    dry_run: bool,
    settle_seconds: float,
) -> tuple[int, int]:
    """Rename z2m devices so their friendly_name matches the canonical
    `name_by_address` mapping. Runs FIRST in `reconcile()` so all
    subsequent phases see the corrected names.

    For each (ieee, desired_friendly) in the mapping:
      * if no z2m device exists with that ieee → warn (device offline,
        not yet paired, or just plain missing); skip without failing
      * if current friendly == desired → skip
      * else → issue `bridge/request/device/rename` with
        `homeassistant_rename: true` so HA's entity ids follow

    Returns (touched, skipped). The mapping is treated as the source
    of truth: a device whose ieee is not in the mapping is left
    completely alone, even if its friendly_name might collide with
    something the user later wants. The user owns the mapping; we
    don't try to be cleverer than them.
    """
    if not config.name_by_address:
        return 0, 0

    by_address = {d.ieee_address: d for d in existing_devices}
    touched = 0
    skipped = 0

    for ieee, desired_name in config.name_by_address.items():
        existing = by_address.get(ieee)
        if existing is None:
            logger.warning(
                "rename: %s (%s) not present in z2m bridge/devices "
                "(offline or not paired); skipping",
                ieee,
                desired_name,
            )
            continue
        if existing.friendly_name == desired_name:
            logger.info(
                "[skip] %s already named %r",
                ieee,
                desired_name,
            )
            skipped += 1
            continue
        verb = "[dry-run] would rename" if dry_run else "rename"
        logger.info(
            "%s %s: %r -> %r",
            verb,
            ieee,
            existing.friendly_name,
            desired_name,
        )
        if not dry_run:
            client.rename_device(ieee, desired_name)
            time.sleep(settle_seconds)
            touched += 1

    return touched, skipped


def reconcile_groups(
    client: Z2mClient,
    config: Config,
    existing: list[ExistingGroup],
    *,
    prune: bool,
    dry_run: bool,
    settle_seconds: float,
) -> tuple[int, int, bool]:
    """Create missing groups and reconcile members.

    Returns (touched, skipped, state_changed). `state_changed` signals
    that the caller should re-fetch groups before the scene phase.
    """
    by_name = {g.friendly_name: g for g in existing}
    desired_names = set(config.groups.keys())
    touched = 0
    skipped = 0
    state_changed = False

    # Phase 0: if pruning, remove any group present in z2m but not in
    # the config. This must happen BEFORE the create phase so stale
    # group ids/friendly_names are freed and don't collide with
    # newly-declared groups using the same id.
    if prune:
        for stale_group in existing:
            if stale_group.friendly_name in desired_names:
                continue
            verb = "[dry-run] would remove" if dry_run else "remove"
            logger.info(
                "%s group %r (id=%d): not in config",
                verb,
                stale_group.friendly_name,
                stale_group.id,
            )
            if not dry_run:
                client.remove_group(stale_group.friendly_name, force=True)
                time.sleep(settle_seconds)
                touched += 1
                state_changed = True

        if state_changed and not dry_run:
            # Re-fetch so the create phase below sees a clean slate.
            time.sleep(settle_seconds)
            existing = client.fetch_groups()
            by_name = {g.friendly_name: g for g in existing}

    for group_name, group_spec in config.groups.items():
        existing_group = by_name.get(group_name)

        if existing_group is None:
            # When pruning, clean up any ghost settings.groups entry at
            # the id we're about to claim. z2m's settings.groups and
            # zigbee network state can disagree: a group can linger in
            # settings.groups (and block addGroup) after its zigbee side
            # was removed. Such ghosts aren't visible in `bridge/groups`
            # so phase 0 above can't see them — we have to explicitly
            # target the id.
            if prune and group_spec.id is not None:
                try:
                    if not dry_run:
                        client.remove_group(str(group_spec.id), force=True)
                        time.sleep(settle_seconds)
                    logger.info(
                        "%s ghost entry at group id %d (clearing before create)",
                        "[dry-run] would prune" if dry_run else "pruned",
                        group_spec.id,
                    )
                    if not dry_run:
                        touched += 1
                        state_changed = True
                except RuntimeError as e:
                    if "does not exist" in str(e).lower():
                        # Nothing to clean up at this id — normal case.
                        pass
                    else:
                        raise

            verb = "[dry-run] would create" if dry_run else "create"
            logger.info(
                "%s group %r (id=%s)",
                verb,
                group_name,
                group_spec.id if group_spec.id is not None else "auto",
            )
            if not dry_run:
                client.add_group(group_name, group_spec.id)
                time.sleep(settle_seconds)
                touched += 1
                state_changed = True
        else:
            if group_spec.id is not None and existing_group.id != group_spec.id:
                logger.warning(
                    "group %r has id %d in z2m but config declares %d; "
                    "leaving alone (id changes require manual remove+recreate)",
                    group_name,
                    existing_group.id,
                    group_spec.id,
                )
            logger.info("[skip] group %r: already exists", group_name)
            skipped += 1

    # Re-fetch if we created any groups so the member phase sees fresh state
    if state_changed and not dry_run:
        time.sleep(settle_seconds)
        existing = client.fetch_groups()
        by_name = {g.friendly_name: g for g in existing}

    # Member reconciliation
    for group_name, group_spec in config.groups.items():
        if not group_spec.members and not prune:
            continue
        existing_group = by_name.get(group_name)
        if existing_group is None:
            if dry_run:
                # Group doesn't exist yet in dry-run mode; skip member diff
                logger.info(
                    "[dry-run] skipping member diff for %r (group would be created first)",
                    group_name,
                )
            continue

        # Normalize both sides through name_by_address before diffing,
        # so a config that uses friendly names compares correctly
        # against z2m's bridge/groups which always reports ieee. See
        # `normalize_member_key` for the exact semantics; the call is
        # a no-op when name_by_address is empty.
        desired_keys: set[str] = {
            normalize_member_key(m, config.name_by_address)
            for m in group_spec.members
        }
        current_keys: set[str] = {
            normalize_member_key(m.as_key(), config.name_by_address)
            for m in existing_group.members
        }

        missing = sorted(desired_keys - current_keys)
        extra = sorted(current_keys - desired_keys)

        for member in missing:
            device, endpoint = parse_member_key(member)
            verb = "[dry-run] would add" if dry_run else "add"
            logger.info("%s member %s to group %r", verb, member, group_name)
            if not dry_run:
                client.add_member(group_name, device, endpoint)
                time.sleep(settle_seconds)
                touched += 1
                state_changed = True

        if prune:
            for member in extra:
                device, endpoint = parse_member_key(member)
                verb = "[dry-run] would remove" if dry_run else "remove"
                logger.info(
                    "%s member %s from group %r",
                    verb,
                    member,
                    group_name,
                )
                if not dry_run:
                    client.remove_member(group_name, device, endpoint)
                    time.sleep(settle_seconds)
                    touched += 1
                    state_changed = True
        else:
            for member in extra:
                logger.info(
                    "[skip] member %s in group %r is not in config "
                    "(re-run with --prune to remove)",
                    member,
                    group_name,
                )
                skipped += 1

    return touched, skipped, state_changed


def _scene_status(
    desired: SceneSpec, existing: ExistingScene | None, force_update: bool
) -> tuple[bool, str]:
    if existing is None:
        return True, "missing"
    if existing.name != desired.name:
        return True, f"name differs ({existing.name!r} -> {desired.name!r})"
    if force_update:
        return True, "force-update"
    return False, "already exists with matching id+name"


def reconcile_scenes(
    client: Z2mClient,
    config: Config,
    existing: list[ExistingGroup],
    *,
    force_update: bool,
    dry_run: bool,
    settle_seconds: float,
) -> tuple[int, int]:
    by_name = {g.friendly_name: g for g in existing}
    touched = 0
    skipped = 0
    missing_groups: list[str] = []

    for group_name, group_spec in config.groups.items():
        if not group_spec.scenes:
            continue
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
            f"these groups are not present in zigbee2mqtt and could not be "
            f"created: {missing_groups}"
        )

    return touched, skipped


def reconcile_devices(
    client: Z2mClient,
    config: Config,
    *,
    dry_run: bool,
    settle_seconds: float,
) -> tuple[int, int]:
    """For each declared device, dedup-check each option against the
    device's retained state and write any that differ. Returns
    (touched, skipped). Same option-count semantics as scenes —
    each declared option is one item, regardless of whether it
    actually fires a write.
    """
    touched = 0
    skipped = 0

    for device_name, device_spec in config.devices.items():
        if not device_spec.options:
            continue

        existing = client.fetch_device_state(device_name)
        if existing is None:
            logger.info(
                "[warn] %s: no retained state available; will write all options unconditionally",
                device_name,
            )

        for opt_key, opt_value in device_spec.options.items():
            current = existing.get(opt_key) if existing is not None else None
            if current == opt_value:
                logger.info(
                    "[skip] %s/%s: already %r",
                    device_name,
                    opt_key,
                    current,
                )
                skipped += 1
                continue

            verb = "[dry-run] would set" if dry_run else "set"
            logger.info(
                "%s %s/%s = %r (was %r)",
                verb,
                device_name,
                opt_key,
                opt_value,
                current,
            )

            if not dry_run:
                client.set_device_options(device_name, { opt_key: opt_value })
                touched += 1
                time.sleep(settle_seconds)

    return touched, skipped


def reconcile(
    client: Z2mClient,
    config: Config,
    *,
    force_update: bool,
    prune: bool,
    dry_run: bool,
    settle_seconds: float,
    fetch_attempts: int,
    fetch_retry_seconds: float,
) -> tuple[int, int]:
    """End-to-end reconcile: device renames, then groups+members,
    then scenes, then per-device option writes.

    Returns (touched, skipped).
    """
    name_touched = 0
    name_skipped = 0
    if config.name_by_address:
        existing_devices = _fetch_with_retry(
            "fetch zigbee2mqtt/bridge/devices",
            client.fetch_devices,
            fetch_attempts,
            fetch_retry_seconds,
        )
        name_touched, name_skipped = reconcile_names(
            client,
            config,
            existing_devices,
            dry_run=dry_run,
            settle_seconds=settle_seconds,
        )
        # If we renamed anything, settle so the rest of the pipeline
        # sees the new names in any retained topics it relies on.
        if name_touched > 0 and not dry_run:
            time.sleep(settle_seconds)

    existing = _fetch_with_retry(
        "fetch zigbee2mqtt/bridge/groups",
        client.fetch_groups,
        fetch_attempts,
        fetch_retry_seconds,
    )

    group_touched, group_skipped, state_changed = reconcile_groups(
        client,
        config,
        existing,
        prune=prune,
        dry_run=dry_run,
        settle_seconds=settle_seconds,
    )

    if state_changed and not dry_run:
        time.sleep(settle_seconds)
        existing = client.fetch_groups()

    scene_touched, scene_skipped = reconcile_scenes(
        client,
        config,
        existing,
        force_update=force_update,
        dry_run=dry_run,
        settle_seconds=settle_seconds,
    )

    device_touched, device_skipped = reconcile_devices(
        client,
        config,
        dry_run=dry_run,
        settle_seconds=settle_seconds,
    )

    return (
        name_touched + group_touched + scene_touched + device_touched,
        name_skipped + group_skipped + scene_skipped + device_skipped,
    )


# ---------- CLI ----------


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Declarative zigbee2mqtt group and scene setup over MQTT.",
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
        "--prune",
        action="store_true",
        help=(
            "Remove group members that are present in z2m but not declared "
            "in the config. Default is additive-only."
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
        "--fetch-attempts",
        type=int,
        default=12,
        help=(
            "Number of times to retry fetching zigbee2mqtt/bridge/groups "
            "when running early in boot before z2m is fully ready"
        ),
    )
    parser.add_argument(
        "--fetch-retry-seconds",
        type=float,
        default=5.0,
        help="Delay between fetch_groups retries",
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
            prune=args.prune,
            dry_run=args.dry_run,
            settle_seconds=DEFAULT_SETTLE_SECONDS,
            fetch_attempts=args.fetch_attempts,
            fetch_retry_seconds=args.fetch_retry_seconds,
        )
    except (TimeoutError, RuntimeError, ValueError) as e:
        logger.error("reconcile failed: %s", e)
        return 1
    finally:
        client.close()

    action_word = "would touch" if args.dry_run else "touched"
    logger.info("done; %s %d item(s), skipped %d", action_word, touched, skipped)
    return 0


if __name__ == "__main__":
    sys.exit(main())
