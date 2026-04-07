"""Tests for `pkg/setup-hue/setup_hue.py` against a fake z2m bridge.

Each test boots a real mosquitto + a fake-z2m subscriber that handles
`bridge/request/*` topics in-process, then drives `setup_hue.reconcile`
through real `Z2mClient` and asserts on the resulting bridge inventory
or on captured publishes.

What's covered:
  * additive group creation
  * additive member add
  * skip when state already matches
  * --prune removes stale members
  * --prune removes stale groups (phase 0)
  * --prune clears ghost group ids before re-creating at the same id
  * scene_add issues a non-integer transition (so z2m takes the
    enhancedAdd code path on Hue bulbs)
  * scene skip when (id, name) already match
  * --force-update re-issues every scene
  * device option dedup against retained state
  * fetch_groups retry succeeds when first attempt times out
"""

from __future__ import annotations

import json
import time

import pytest

import setup_hue  # type: ignore[import-not-found]
from conftest import FakeZ2m


# ---------- helpers ----------


def _client(mosquitto: tuple[str, int]) -> setup_hue.Z2mClient:
    host, port = mosquitto
    return setup_hue.Z2mClient(
        host=host,
        port=port,
        user="anything",
        password="anything",
        timeout_s=3.0,
    )


def _config(**groups: dict) -> setup_hue.Config:
    return setup_hue.Config.model_validate({"groups": groups})


def _config_with_devices(
    groups: dict, devices: dict
) -> setup_hue.Config:
    return setup_hue.Config.model_validate({"groups": groups, "devices": devices})


def _reconcile(
    client: setup_hue.Z2mClient,
    config: setup_hue.Config,
    *,
    prune: bool = False,
    force_update: bool = False,
    dry_run: bool = False,
) -> tuple[int, int]:
    return setup_hue.reconcile(
        client,
        config,
        force_update=force_update,
        prune=prune,
        dry_run=dry_run,
        # Tests don't need the production 0.4s settle delay between
        # publishes — the fake bridge processes synchronously and
        # republishes bridge/groups before responding.
        settle_seconds=0.0,
        fetch_attempts=3,
        fetch_retry_seconds=0.1,
    )


# ---------- group creation ----------


def test_additive_creates_missing_group(
    mosquitto: tuple[str, int], fake_z2m: FakeZ2m
) -> None:
    config = _config(study={"id": 50, "members": ["0xaaaa/11"]})
    client = _client(mosquitto)
    try:
        touched, skipped = _reconcile(client, config)
    finally:
        client.close()

    assert touched >= 2  # group create + member add
    inv = fake_z2m.snapshot()
    assert len(inv) == 1
    assert inv[0]["friendly_name"] == "study"
    assert inv[0]["id"] == 50
    assert inv[0]["members"] == [{"ieee_address": "0xaaaa", "endpoint": 11}]


def test_skip_when_group_already_matches(
    mosquitto: tuple[str, int], fake_z2m: FakeZ2m
) -> None:
    fake_z2m.add_existing_group("study", 50, members=[("0xaaaa", 11)])
    config = _config(study={"id": 50, "members": ["0xaaaa/11"]})
    client = _client(mosquitto)
    try:
        touched, skipped = _reconcile(client, config)
    finally:
        client.close()

    assert touched == 0
    assert skipped >= 1  # at minimum the group itself is skipped
    # Inventory unchanged
    assert fake_z2m.snapshot()[0]["members"] == [
        {"ieee_address": "0xaaaa", "endpoint": 11}
    ]


def test_dry_run_publishes_nothing(
    mosquitto: tuple[str, int], fake_z2m: FakeZ2m
) -> None:
    config = _config(study={"id": 50, "members": ["0xaaaa/11"]})
    client = _client(mosquitto)
    try:
        _reconcile(client, config, dry_run=True)
    finally:
        client.close()
    assert fake_z2m.snapshot() == []


# ---------- member reconciliation ----------


def test_additive_adds_missing_member(
    mosquitto: tuple[str, int], fake_z2m: FakeZ2m
) -> None:
    fake_z2m.add_existing_group("study", 50, members=[("0xaaaa", 11)])
    config = _config(
        study={"id": 50, "members": ["0xaaaa/11", "0xbbbb/11"]}
    )
    client = _client(mosquitto)
    try:
        _reconcile(client, config)
    finally:
        client.close()
    members = {(m["ieee_address"], m["endpoint"]) for m in fake_z2m.snapshot()[0]["members"]}
    assert members == {("0xaaaa", 11), ("0xbbbb", 11)}


def test_additive_does_not_remove_extra_member(
    mosquitto: tuple[str, int], fake_z2m: FakeZ2m
) -> None:
    fake_z2m.add_existing_group(
        "study", 50, members=[("0xaaaa", 11), ("0xextra", 11)]
    )
    config = _config(study={"id": 50, "members": ["0xaaaa/11"]})
    client = _client(mosquitto)
    try:
        _reconcile(client, config, prune=False)
    finally:
        client.close()
    members = {(m["ieee_address"], m["endpoint"]) for m in fake_z2m.snapshot()[0]["members"]}
    assert ("0xextra", 11) in members


def test_prune_removes_extra_member(
    mosquitto: tuple[str, int], fake_z2m: FakeZ2m
) -> None:
    fake_z2m.add_existing_group(
        "study", 50, members=[("0xaaaa", 11), ("0xextra", 11)]
    )
    config = _config(study={"id": 50, "members": ["0xaaaa/11"]})
    client = _client(mosquitto)
    try:
        _reconcile(client, config, prune=True)
    finally:
        client.close()
    members = {(m["ieee_address"], m["endpoint"]) for m in fake_z2m.snapshot()[0]["members"]}
    assert members == {("0xaaaa", 11)}


def test_prune_removes_stale_group(
    mosquitto: tuple[str, int], fake_z2m: FakeZ2m
) -> None:
    fake_z2m.add_existing_group("study", 50, members=[("0xaaaa", 11)])
    fake_z2m.add_existing_group("ghost-room", 99, members=[("0xzzzz", 11)])
    config = _config(study={"id": 50, "members": ["0xaaaa/11"]})
    client = _client(mosquitto)
    try:
        _reconcile(client, config, prune=True)
    finally:
        client.close()
    names = {g["friendly_name"] for g in fake_z2m.snapshot()}
    assert names == {"study"}


def test_prune_clears_ghost_id_before_recreate(
    mosquitto: tuple[str, int], fake_z2m: FakeZ2m
) -> None:
    """A group id can linger in z2m's settings.groups after the zigbee
    side is gone. Adding a new group at that id fails until the ghost
    is removed. setup_hue's prune phase explicitly issues a remove
    against the numeric id before the create."""
    fake_z2m.add_ghost_id(50)
    config = _config(study={"id": 50, "members": ["0xaaaa/11"]})
    client = _client(mosquitto)
    try:
        _reconcile(client, config, prune=True)
    finally:
        client.close()
    inv = fake_z2m.snapshot()
    assert len(inv) == 1 and inv[0]["id"] == 50


# ---------- scenes ----------


def test_scene_add_uses_float_transition(
    mosquitto: tuple[str, int], fake_z2m: FakeZ2m
) -> None:
    """The scene_add payload's `transition` field MUST be encoded as a
    JSON float (with a decimal point), not an integer. z2m's converter
    routes integer transtimes through `genScenes.add` and float
    transtimes through `genScenes.enhancedAdd`. Hue bulbs only honor
    the transition correctly via enhancedAdd, so a regression that
    drops the float epsilon would silently break scene transitions on
    real hardware."""
    fake_z2m.add_existing_group("study", 50)
    config = _config(
        study={
            "id": 50,
            "scenes": [
                {
                    "id": 1,
                    "name": "bright",
                    "state": "ON",
                    "brightness": 254,
                    "color_temp": 250,
                    "transition": 0,  # written as int in source config
                }
            ],
        }
    )
    client = _client(mosquitto)
    try:
        _reconcile(client, config)
    finally:
        client.close()

    assert fake_z2m.scene_add_raw, "no scene_add publish was captured"
    raw = fake_z2m.scene_add_raw[-1]
    parsed = json.loads(raw)
    transition = parsed["scene_add"]["transition"]
    assert isinstance(transition, float), (
        f"expected float transition, got {type(transition).__name__}: {transition!r}"
    )
    # And the raw JSON has a decimal point
    assert '"transition":' in raw
    after = raw.split('"transition":', 1)[1].lstrip()
    assert after.startswith("0.") or after.startswith("0."), (
        f"transition was not encoded with a decimal: {raw!r}"
    )


def test_scene_skip_when_id_and_name_match(
    mosquitto: tuple[str, int], fake_z2m: FakeZ2m
) -> None:
    fake_z2m.add_existing_group("study", 50, scenes=[(1, "bright")])
    config = _config(
        study={
            "id": 50,
            "scenes": [
                {"id": 1, "name": "bright", "state": "ON", "transition": 0.5}
            ],
        }
    )
    client = _client(mosquitto)
    try:
        _reconcile(client, config)
    finally:
        client.close()
    assert fake_z2m.scene_add_raw == [], (
        f"expected no scene_add, got {fake_z2m.scene_add_raw}"
    )


def test_scene_force_update_reissues(
    mosquitto: tuple[str, int], fake_z2m: FakeZ2m
) -> None:
    fake_z2m.add_existing_group("study", 50, scenes=[(1, "bright")])
    config = _config(
        study={
            "id": 50,
            "scenes": [
                {"id": 1, "name": "bright", "state": "ON", "transition": 0.5}
            ],
        }
    )
    client = _client(mosquitto)
    try:
        _reconcile(client, config, force_update=True)
    finally:
        client.close()
    assert len(fake_z2m.scene_add_raw) == 1


def test_scene_create_when_name_differs(
    mosquitto: tuple[str, int], fake_z2m: FakeZ2m
) -> None:
    fake_z2m.add_existing_group("study", 50, scenes=[(1, "old-name")])
    config = _config(
        study={
            "id": 50,
            "scenes": [
                {"id": 1, "name": "new-name", "state": "ON", "transition": 0.5}
            ],
        }
    )
    client = _client(mosquitto)
    try:
        _reconcile(client, config)
    finally:
        client.close()
    assert len(fake_z2m.scene_add_raw) == 1
    parsed = json.loads(fake_z2m.scene_add_raw[0])
    assert parsed["scene_add"]["name"] == "new-name"


# ---------- device option dedup ----------


def test_device_option_skipped_when_state_matches(
    mosquitto: tuple[str, int], fake_z2m: FakeZ2m
) -> None:
    """When the retained device state already has the desired option
    value, no /set should be issued. This is the dedup that keeps
    re-runs from hammering the on-device NVS of motion sensors."""
    fake_z2m.seed_device_state(
        "hue-ms-hall",
        {"occupancy_timeout": 75, "motion_sensitivity": "high"},
    )
    # Give the broker a moment to settle the retained publish before
    # setup_hue connects and subscribes.
    time.sleep(0.2)
    config = _config_with_devices(
        groups={},
        devices={
            "hue-ms-hall": {
                "options": {
                    "occupancy_timeout": 75,
                    "motion_sensitivity": "high",
                }
            }
        },
    )
    client = _client(mosquitto)
    try:
        _reconcile(client, config)
    finally:
        client.close()
    assert fake_z2m.device_sets == [], (
        f"expected no device /set, got {fake_z2m.device_sets}"
    )


def test_device_option_written_when_state_differs(
    mosquitto: tuple[str, int], fake_z2m: FakeZ2m
) -> None:
    fake_z2m.seed_device_state(
        "hue-ms-hall",
        {"occupancy_timeout": 30, "motion_sensitivity": "medium"},
    )
    time.sleep(0.2)
    config = _config_with_devices(
        groups={},
        devices={
            "hue-ms-hall": {
                "options": {
                    "occupancy_timeout": 75,
                    "motion_sensitivity": "high",
                }
            }
        },
    )
    client = _client(mosquitto)
    try:
        _reconcile(client, config)
    finally:
        client.close()
    # Each diff is published as a separate /set so the writes can
    # land independently and the device acks each one.
    sets = {tuple(sorted(payload.items())) for _, payload in fake_z2m.device_sets}
    assert sets == {
        (("occupancy_timeout", 75),),
        (("motion_sensitivity", "high"),),
    }


def test_device_option_written_when_no_retained_state(
    mosquitto: tuple[str, int], fake_z2m: FakeZ2m
) -> None:
    """First-time provisioning: no retained state means we cannot
    dedup, so every option must be written unconditionally."""
    config = _config_with_devices(
        groups={},
        devices={
            "hue-ms-hall": {"options": {"occupancy_timeout": 75}}
        },
    )
    client = _client(mosquitto)
    try:
        _reconcile(client, config)
    finally:
        client.close()
    assert any(
        payload == {"occupancy_timeout": 75}
        for _, payload in fake_z2m.device_sets
    ), f"expected an unconditional write, got {fake_z2m.device_sets}"


# ---------- fetch retry ----------


def test_fetch_groups_retries_until_inventory_available(
    mosquitto: tuple[str, int]
) -> None:
    """If z2m hasn't published bridge/groups yet, fetch_groups
    times out — but the reconcile wrapper retries with a delay so
    early-boot races don't kill the service."""
    # Note: no fake_z2m fixture, so nothing publishes bridge/groups.
    # Start a delayed publisher in a thread.
    import threading

    host, port = mosquitto
    bridge_started = threading.Event()

    def delayed_bridge() -> None:
        time.sleep(0.5)
        bridge = FakeZ2m(host, port)
        bridge_started.set()
        # Hold the bridge alive until the test ends
        time.sleep(5.0)
        bridge.close()

    t = threading.Thread(target=delayed_bridge, daemon=True)
    t.start()

    config = _config(study={"id": 50, "members": ["0xaaaa/11"]})
    client = setup_hue.Z2mClient(
        host=host,
        port=port,
        user="x",
        password="y",
        # short per-op timeout, so the first fetch attempt times out
        # quickly and the retry path is exercised
        timeout_s=0.3,
    )
    try:
        # Expect this to succeed via the retry path
        setup_hue.reconcile(
            client,
            config,
            force_update=False,
            prune=False,
            dry_run=False,
            settle_seconds=0.0,
            fetch_attempts=10,
            fetch_retry_seconds=0.2,
        )
    finally:
        client.close()
    assert bridge_started.is_set()
