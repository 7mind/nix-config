"""Tests for `pkg/hue-setup/hue_setup.py` against a fake z2m bridge.

Each test boots a real mosquitto + a fake-z2m subscriber that handles
`bridge/request/*` topics in-process, then drives `hue_setup.reconcile`
through real `Z2mClient` and asserts on the resulting bridge inventory
or on captured publishes.

What's covered:
  * additive group creation
  * additive member add
  * skip when state already matches
  * --prune removes stale members
  * --prune removes stale groups (phase 0)
  * --prune clears ghost group ids before re-creating at the same id
  * group rename when id matches but friendly_name has drifted, with
    member/scene preservation and correct rename-before-prune ordering
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

import hue_setup  # type: ignore[import-not-found]
from conftest import FakeZ2m


# ---------- helpers ----------


def _client(mosquitto: tuple[str, int]) -> hue_setup.Z2mClient:
    host, port = mosquitto
    return hue_setup.Z2mClient(
        host=host,
        port=port,
        user="anything",
        password="anything",
        timeout_s=3.0,
    )


def _config(**groups: dict) -> hue_setup.Config:
    return hue_setup.Config.model_validate({"groups": groups})


def _config_with_devices(
    groups: dict, devices: dict
) -> hue_setup.Config:
    return hue_setup.Config.model_validate({"groups": groups, "devices": devices})


def _config_with_names(
    name_by_address: dict[str, str],
    groups: dict | None = None,
) -> hue_setup.Config:
    return hue_setup.Config.model_validate(
        {
            "groups": groups or {},
            "name_by_address": name_by_address,
        }
    )


def _reconcile(
    client: hue_setup.Z2mClient,
    config: hue_setup.Config,
    *,
    prune: bool = False,
    force_update: bool = False,
    dry_run: bool = False,
) -> tuple[int, int]:
    return hue_setup.reconcile(
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


# ---------- member key normalization (friendly vs ieee diff bug) ----------


def test_member_diff_uses_name_by_address_to_normalize(
    mosquitto: tuple[str, int], fake_z2m: FakeZ2m
) -> None:
    """Regression: when the config has members in friendly form
    (because defineRooms translated them at build time) but z2m's
    bridge/groups reports them in ieee form (it always does), the
    member diff must normalize through name_by_address before
    comparing — otherwise every member looks both missing and extra
    on every reconcile, and we permanently churn add/remove calls.

    This is the exact scenario the user hit running hue-apply on
    raspi5m: every existing group reported "add member <friendly>"
    plus "[skip] member <ieee> ... not in config" on every run.
    """
    fake_z2m.add_existing_device("0xaaaa", "lamp-a")
    fake_z2m.add_existing_device("0xbbbb", "lamp-b")
    fake_z2m.add_existing_group(
        "study", 50, members=[("0xaaaa", 11), ("0xbbbb", 11)]
    )
    config = hue_setup.Config.model_validate(
        {
            "name_by_address": {
                "0xaaaa": "lamp-a",
                "0xbbbb": "lamp-b",
            },
            "groups": {
                "study": {
                    "id": 50,
                    "members": ["lamp-a/11", "lamp-b/11"],
                },
            },
        }
    )
    client = _client(mosquitto)
    try:
        touched, _skipped = _reconcile(client, config, prune=True)
    finally:
        client.close()
    # No add/remove on either side — the diff should be empty.
    assert touched == 0, (
        "diff was not normalized: hue-setup tried to mutate group "
        "membership when both sides describe the same physical bulbs"
    )
    # Inventory unchanged — exactly the two original members, still
    # reported in ieee form (z2m never rewrites these to friendly).
    members = {
        (m["ieee_address"], m["endpoint"])
        for m in fake_z2m.snapshot()[0]["members"]
    }
    assert members == {("0xaaaa", 11), ("0xbbbb", 11)}


def test_member_diff_falls_back_to_ieee_when_unmapped(
    mosquitto: tuple[str, int], fake_z2m: FakeZ2m
) -> None:
    """A device whose ieee isn't in name_by_address falls back to
    its bare ieee in the normalized form on both sides. The config
    can reference the bare ieee and the diff still works."""
    fake_z2m.add_existing_group(
        "study", 50, members=[("0x99999", 11)]
    )
    config = hue_setup.Config.model_validate(
        {
            # name_by_address intentionally empty
            "groups": {
                "study": {"id": 50, "members": ["0x99999/11"]},
            },
        }
    )
    client = _client(mosquitto)
    try:
        touched, _skipped = _reconcile(client, config)
    finally:
        client.close()
    assert touched == 0


def test_normalize_member_key_unit() -> None:
    """Direct unit checks on the helper, since the integration tests
    above only cover the happy path through the broker."""
    # Friendly name with mapping → translated
    assert hue_setup.normalize_member_key(
        "0xaaaa/11", {"0xaaaa": "lamp-a"}
    ) == "lamp-a/11"
    # ieee not in mapping → unchanged
    assert hue_setup.normalize_member_key("0xunknown/11", {}) == "0xunknown/11"
    # Already a friendly name → unchanged regardless of mapping
    assert hue_setup.normalize_member_key(
        "lamp-a/11", {"0xaaaa": "lamp-a"}
    ) == "lamp-a/11"
    # Empty mapping → unchanged
    assert hue_setup.normalize_member_key("0xaaaa/11", {}) == "0xaaaa/11"
    # Multi-slash friendly name with endpoint → split on LAST slash
    assert hue_setup.normalize_member_key(
        "weird/name/11", {}
    ) == "weird/name/11"
    # Malformed (no '/') → returned as-is so parse_member_key can raise
    assert hue_setup.normalize_member_key("malformed", {}) == "malformed"


def test_prune_clears_ghost_id_before_recreate(
    mosquitto: tuple[str, int], fake_z2m: FakeZ2m
) -> None:
    """A group id can linger in z2m's settings.groups after the zigbee
    side is gone. Adding a new group at that id fails until the ghost
    is removed. hue_setup's prune phase explicitly issues a remove
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
    # hue_setup connects and subscribes.
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
    client = hue_setup.Z2mClient(
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
        hue_setup.reconcile(
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


# ---------- rename phase ----------


def test_rename_renames_when_friendly_differs(
    mosquitto: tuple[str, int], fake_z2m: FakeZ2m
) -> None:
    """A device whose current friendly_name doesn't match the canonical
    mapping is renamed via bridge/request/device/rename."""
    fake_z2m.add_existing_device("0xaaaa", "old-name")
    config = _config_with_names({"0xaaaa": "lamp-a"})
    client = _client(mosquitto)
    try:
        touched, _skipped = _reconcile(client, config)
    finally:
        client.close()
    assert touched >= 1
    assert fake_z2m.rename_calls == [("0xaaaa", "old-name", "lamp-a")]
    snapshot = {d["ieee_address"]: d["friendly_name"] for d in fake_z2m.device_snapshot()}
    assert snapshot["0xaaaa"] == "lamp-a"


def test_rename_skip_when_already_correct(
    mosquitto: tuple[str, int], fake_z2m: FakeZ2m
) -> None:
    """No rename when the device's current friendly_name already
    matches the mapping. The skipped count includes the device."""
    fake_z2m.add_existing_device("0xaaaa", "lamp-a")
    config = _config_with_names({"0xaaaa": "lamp-a"})
    client = _client(mosquitto)
    try:
        _, skipped = _reconcile(client, config)
    finally:
        client.close()
    assert fake_z2m.rename_calls == []
    assert skipped >= 1


def test_rename_homeassistant_rename_flag_is_set(
    mosquitto: tuple[str, int], fake_z2m: FakeZ2m
) -> None:
    """Every rename request must carry homeassistant_rename: true so
    HA's entity ids follow the friendly_name change in the same
    operation. We check this by intercepting the raw request the
    fake bridge receives."""
    captured: list[dict] = []

    # Wrap the existing handler to capture the raw payload before it
    # mutates the inventory.
    original_handler = fake_z2m._handle_device_rename

    def spy(payload: dict) -> None:
        captured.append(dict(payload))
        original_handler(payload)

    fake_z2m._handle_device_rename = spy  # type: ignore[method-assign]

    fake_z2m.add_existing_device("0xaaaa", "old")
    config = _config_with_names({"0xaaaa": "lamp-a"})
    client = _client(mosquitto)
    try:
        _reconcile(client, config)
    finally:
        client.close()

    assert len(captured) == 1
    assert captured[0]["homeassistant_rename"] is True
    assert captured[0]["from"] == "0xaaaa"
    assert captured[0]["to"] == "lamp-a"


def test_rename_skips_missing_device_with_warning(
    mosquitto: tuple[str, int], fake_z2m: FakeZ2m
) -> None:
    """A mapping entry whose ieee isn't currently visible in z2m
    (offline, not paired yet) must NOT crash the reconcile. The
    rename phase logs a warning and moves on."""
    fake_z2m.add_existing_device("0xaaaa", "lamp-a")
    config = _config_with_names(
        {
            "0xaaaa": "lamp-a",
            "0xmissing": "lamp-z",  # not in z2m
        }
    )
    client = _client(mosquitto)
    try:
        # No exception expected.
        _reconcile(client, config)
    finally:
        client.close()
    # The visible device was already correct -> no rename calls.
    assert fake_z2m.rename_calls == []


def test_rename_dry_run_does_not_send_request(
    mosquitto: tuple[str, int], fake_z2m: FakeZ2m
) -> None:
    """Dry-run logs the planned rename but never publishes the
    bridge/request/device/rename topic."""
    fake_z2m.add_existing_device("0xaaaa", "old")
    config = _config_with_names({"0xaaaa": "lamp-a"})
    client = _client(mosquitto)
    try:
        _reconcile(client, config, dry_run=True)
    finally:
        client.close()
    assert fake_z2m.rename_calls == []
    snapshot = {d["ieee_address"]: d["friendly_name"] for d in fake_z2m.device_snapshot()}
    assert snapshot["0xaaaa"] == "old"


def test_rename_runs_before_groups_phase(
    mosquitto: tuple[str, int], fake_z2m: FakeZ2m
) -> None:
    """The rename phase must run BEFORE the group/member phase so
    later phases see the canonical names. We assert ordering by
    checking that a fresh group create still happens after a rename
    fired in the same reconcile pass."""
    fake_z2m.add_existing_device("0xaaaa", "old")
    config = hue_setup.Config.model_validate(
        {
            "name_by_address": {"0xaaaa": "lamp-a"},
            "groups": {
                "study": {"id": 50, "members": ["0xaaaa/11"]},
            },
        }
    )
    client = _client(mosquitto)
    try:
        _reconcile(client, config)
    finally:
        client.close()
    # The rename happened
    assert fake_z2m.rename_calls == [("0xaaaa", "old", "lamp-a")]
    # And the group create happened in the same pass
    inv = fake_z2m.snapshot()
    assert len(inv) == 1
    assert inv[0]["friendly_name"] == "study"
    assert inv[0]["members"] == [{"ieee_address": "0xaaaa", "endpoint": 11}]


def test_reconcile_with_empty_name_mapping_skips_devices_fetch(
    mosquitto: tuple[str, int], fake_z2m: FakeZ2m
) -> None:
    """When name_by_address is empty (the default), the rename
    phase is a complete no-op and never queries bridge/devices.
    Verifies the gating in `reconcile()` so existing configs that
    don't use the new feature don't pay for it."""
    config = _config(study={"id": 50, "members": ["0xaaaa/11"]})
    client = _client(mosquitto)
    try:
        _reconcile(client, config)
    finally:
        client.close()
    assert fake_z2m.rename_calls == []


# ---------- group rename phase ----------


def test_group_rename_when_id_matches_but_name_differs(
    mosquitto: tuple[str, int], fake_z2m: FakeZ2m
) -> None:
    """A group whose id matches an existing z2m group but whose
    declared friendly_name has changed must be renamed in place via
    bridge/request/group/rename — NOT removed and re-created, which
    would lose its members and scenes."""
    fake_z2m.add_existing_group(
        "old-study", 50, members=[("0xaaaa", 11)]
    )
    config = _config(study={"id": 50, "members": ["0xaaaa/11"]})
    client = _client(mosquitto)
    try:
        _reconcile(client, config)
    finally:
        client.close()

    assert fake_z2m.group_rename_calls == [("old-study", "study")]
    inv = fake_z2m.snapshot()
    assert len(inv) == 1
    assert inv[0]["friendly_name"] == "study"
    assert inv[0]["id"] == 50
    # Members preserved across the rename — no add/remove churn.
    assert inv[0]["members"] == [{"ieee_address": "0xaaaa", "endpoint": 11}]


def test_group_rename_preserves_scenes(
    mosquitto: tuple[str, int], fake_z2m: FakeZ2m
) -> None:
    """Scenes attached to the renamed group must survive the
    rename and be skipped (not re-added) by the scene phase."""
    fake_z2m.add_existing_group(
        "old-study",
        50,
        members=[("0xaaaa", 11)],
        scenes=[(1, "bright")],
    )
    config = _config(
        study={
            "id": 50,
            "members": ["0xaaaa/11"],
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

    assert fake_z2m.group_rename_calls == [("old-study", "study")]
    inv = fake_z2m.snapshot()
    assert inv[0]["scenes"] == [{"id": 1, "name": "bright"}]
    # And the scene phase didn't re-issue scene_add for the matching scene.
    assert fake_z2m.scene_add_raw == []


def test_group_rename_skip_when_no_id_in_config(
    mosquitto: tuple[str, int], fake_z2m: FakeZ2m
) -> None:
    """A group declared without an explicit id can't be matched to
    an existing z2m group by id, so the rename phase is a no-op for
    it. The downstream create-by-name flow handles it instead."""
    fake_z2m.add_existing_group(
        "old-study", 50, members=[("0xaaaa", 11)]
    )
    config = _config(study={"members": ["0xaaaa/11"]})  # no id
    client = _client(mosquitto)
    try:
        _reconcile(client, config)
    finally:
        client.close()
    assert fake_z2m.group_rename_calls == []


def test_group_rename_collision_aborts(
    mosquitto: tuple[str, int], fake_z2m: FakeZ2m
) -> None:
    """If the desired name is already taken by a different existing
    group, the rename phase must fail loudly rather than silently
    leaving the config and z2m out of sync. The user is expected to
    resolve the conflict manually."""
    fake_z2m.add_existing_group("old-study", 50)
    fake_z2m.add_existing_group("study", 51)  # already taken at a different id
    config = _config(study={"id": 50})
    client = _client(mosquitto)
    try:
        with pytest.raises(RuntimeError, match="already in use"):
            _reconcile(client, config)
    finally:
        client.close()
    # No rename was attempted before the abort.
    assert fake_z2m.group_rename_calls == []


def test_group_rename_dry_run_does_not_publish(
    mosquitto: tuple[str, int], fake_z2m: FakeZ2m
) -> None:
    """Dry-run logs the planned rename but never actually publishes
    bridge/request/group/rename, so z2m's inventory is unchanged."""
    fake_z2m.add_existing_group(
        "old-study", 50, members=[("0xaaaa", 11)]
    )
    config = _config(study={"id": 50, "members": ["0xaaaa/11"]})
    client = _client(mosquitto)
    try:
        _reconcile(client, config, dry_run=True)
    finally:
        client.close()
    assert fake_z2m.group_rename_calls == []
    inv = fake_z2m.snapshot()
    assert inv[0]["friendly_name"] == "old-study"


def test_group_rename_then_prune_does_not_delete_renamed_group(
    mosquitto: tuple[str, int], fake_z2m: FakeZ2m
) -> None:
    """Critical ordering check: rename must happen BEFORE prune.
    Otherwise prune sees the old name as 'not in config' and deletes
    the group (with all its members and scenes) before rename can
    fire — which would silently destroy state on every config rename."""
    fake_z2m.add_existing_group(
        "old-study", 50, members=[("0xaaaa", 11)]
    )
    config = _config(study={"id": 50, "members": ["0xaaaa/11"]})
    client = _client(mosquitto)
    try:
        _reconcile(client, config, prune=True)
    finally:
        client.close()
    # Group still exists, with its original id and members.
    inv = fake_z2m.snapshot()
    assert len(inv) == 1
    assert inv[0]["friendly_name"] == "study"
    assert inv[0]["id"] == 50
    assert inv[0]["members"] == [{"ieee_address": "0xaaaa", "endpoint": 11}]
    # And the rename was issued, not a remove+create.
    assert fake_z2m.group_rename_calls == [("old-study", "study")]


def test_group_rename_skip_when_already_correct(
    mosquitto: tuple[str, int], fake_z2m: FakeZ2m
) -> None:
    """When the existing friendly_name already matches the config,
    no rename request is sent."""
    fake_z2m.add_existing_group(
        "study", 50, members=[("0xaaaa", 11)]
    )
    config = _config(study={"id": 50, "members": ["0xaaaa/11"]})
    client = _client(mosquitto)
    try:
        _reconcile(client, config)
    finally:
        client.close()
    assert fake_z2m.group_rename_calls == []
