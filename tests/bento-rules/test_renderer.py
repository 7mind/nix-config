"""Structural tests for the `defineRooms` helper in
`private/hosts/raspi5m/hue-lights-tools.nix`.

These complement the behavior tests in `test_bento_rules.py`. Where
those verify *what bento does* given hand-crafted configs, this file
verifies *what the Nix renderer produces* — so a future refactor that
changes the shape of generated rules in a subtly-broken way (wrong
cache label, missing handler, mis-ordered dispatch, etc.) fails the
build rather than silently changing runtime behavior.

The tests spawn `nix eval --impure --json` against a small helper
snippet that imports the tools and calls `defineRooms` with synthetic
room definitions, then assert on the JSON-decoded attrset.

Why `--impure`: the helper needs `<nixpkgs>` to get `lib`, and
pinning it via a flake would add flake scaffolding that doesn't
exist in this tests directory yet. The assertions care only about
structural output, not reproducibility.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
TOOLS_PATH = REPO_ROOT / "private/hosts/raspi5m/hue-lights-tools.nix"


def _auto_address_by_name(rooms_nix: str) -> dict[str, str]:
    """Synthesize an addressByName mapping that covers every device
    reference present in the given rooms snippet.

    `defineRooms` now requires every reference (in `members`,
    `switch`, `motionSensor.name(s)`) to resolve through an explicit
    mapping. Auto-generating one from the snippet keeps the test
    suite ergonomic — each test config still reads as a free-form
    Nix expression, no boilerplate mapping per test.

    Walks the snippet for tokens that look like device references in
    the relevant positions. For each unique friendly name, assigns a
    unique synthetic ieee. For each unique 0x... reference, assigns
    a unique synthetic friendly name keyed in the output mapping.
    """
    member_re = re.compile(r'"([^"\s/]+)/\d+"')
    name_assign_re = re.compile(r'(?:switch|name)\s*=\s*"([^"]+)"')
    names_list_re = re.compile(r'names\s*=\s*\[\s*((?:"[^"]+"\s*)+)\]')

    refs: set[str] = set()
    refs.update(member_re.findall(rooms_nix))
    refs.update(name_assign_re.findall(rooms_nix))
    for names_block in names_list_re.findall(rooms_nix):
        refs.update(re.findall(r'"([^"]+)"', names_block))

    mapping: dict[str, str] = {}
    synth_friendly_counter = 0
    synth_ieee_counter = 0
    for ref in sorted(refs):
        if ref.startswith("0x"):
            synth_name = f"_synth_bulb_{synth_friendly_counter}"
            synth_friendly_counter += 1
            mapping[synth_name] = ref
        else:
            synth_addr = f"0xfe00000000{synth_ieee_counter:06x}"
            synth_ieee_counter += 1
            mapping[ref] = synth_addr
    return mapping


def _render_address_by_name_nix(address_by_name: dict[str, str]) -> str:
    """Render a Python dict as a Nix attrset literal. Both keys and
    values are device-id strings, which never contain quotes — a
    naive renderer is sufficient and avoids pulling in a Nix encoder."""
    entries = " ".join(
        f'"{name}" = "{addr}";' for name, addr in sorted(address_by_name.items())
    )
    return "{ " + entries + " }"


def _eval_define_rooms(
    rooms_nix: str,
    *,
    address_by_name: dict[str, str] | None = None,
) -> dict[str, Any]:
    """Evaluate `defineRooms { addressByName = ...; rooms = ...; }` with
    the given rooms snippet and return the JSON-decoded result.

    `address_by_name` defaults to an auto-extracted mapping covering
    every device reference in `rooms_nix`. Tests that want to verify
    a specific mapping (or trigger a missing-reference error) pass
    their own.
    """
    if address_by_name is None:
        address_by_name = _auto_address_by_name(rooms_nix)
    addr_nix = _render_address_by_name_nix(address_by_name)
    expr = f"""
let
  pkgs = import <nixpkgs> {{ }};
  lib = pkgs.lib;
  tools = import {TOOLS_PATH} {{ inherit lib; }};
  inherit (tools) defaultScheduledScenes defaultDayScenes;
in
tools.defineRooms {{
  addressByName = {addr_nix};
  rooms = {rooms_nix};
}}
"""
    result = subprocess.run(
        ["nix", "eval", "--impure", "--json", "--expr", expr],
        check=True,
        capture_output=True,
        text=True,
        env={**os.environ, "NIX_CONFIG": "experimental-features = nix-command flakes"},
    )
    return json.loads(result.stdout)


# ---------- helpers ----------


def _assert_handler_check_contains(rule: dict, action: str, substring: str) -> None:
    """Find a handler by key and assert its check bloblang contains
    the given substring. Fails loudly if the handler or key is
    missing so refactors that drop a handler are caught."""
    handlers = rule["handlers"]
    assert action in handlers, f"missing handler {action!r} in rule; got {list(handlers)}"
    check = handlers[action].get("check")
    assert check is not None, f"handler {action!r} has no `check`"
    assert substring in check, (
        f"handler {action!r} check does not contain {substring!r}; "
        f"actual: {check!r}"
    )


# ---------- single-room, switch-only ----------


def test_switch_only_room_generates_single_rule() -> None:
    result = _eval_define_rooms(
        """{
      study = {
        groupName = "study";
        id = 50;
        members = [ "0xaaaa/11" ];
        switch = "hue-s-study";
        scenes = defaultDayScenes;
      };
    }"""
    )
    rules = result["smind"]["services"]["mqtt-automations"]["rules"]
    assert list(rules) == ["study-switch"]
    rule = rules["study-switch"]
    assert rule["source"] == "zigbee2mqtt/hue-s-study/action"
    assert rule["target"] == "zigbee2mqtt/study/set"
    # Cache label should be the default derived-from-name form, since
    # there's no motion sensor forcing a shared cacheLabel.
    assert rule.get("cacheLabel") in (None, "")


# ---------- single-room, motion-only ----------


def test_motion_only_room_generates_single_motion_rule() -> None:
    result = _eval_define_rooms(
        """{
      cellar = {
        groupName = "cellar";
        id = 51;
        members = [ "0xbbbb/11" ];
        scenes = defaultDayScenes;
        motionSensor.name = "hue-ms-cellar";
      };
    }"""
    )
    rules = result["smind"]["services"]["mqtt-automations"]["rules"]
    assert list(rules) == ["cellar-motion-hue_ms_cellar"]
    rule = rules["cellar-motion-hue_ms_cellar"]
    assert rule["source"] == "zigbee2mqtt/hue-ms-cellar"
    assert rule["target"] == "zigbee2mqtt/cellar/set"
    assert rule["format"] == "json"
    assert rule["cacheLabel"] == "room_cellar"
    # Motion-only rooms still declare motion-on and motion-off
    assert set(rule["handlers"]) == {"motion-on", "motion-off"}


# ---------- switch + motion in one room, shared cache ----------


def test_switch_plus_motion_share_cache_label() -> None:
    result = _eval_define_rooms(
        """{
      living-room = {
        groupName = "living room";
        id = 52;
        members = [ "0xcccc/11" ];
        switch = "hue-s-living-room";
        motionSensor.name = "hue-ms-living-room";
        scenes = defaultDayScenes;
      };
    }"""
    )
    rules = result["smind"]["services"]["mqtt-automations"]["rules"]
    assert set(rules) == {
        "living-room-switch",
        "living-room-motion-hue_ms_living_room",
    }
    # Both rules must target the same in-memory cache resource so
    # lights_state and last_off_at coordinate correctly.
    assert rules["living-room-switch"]["cacheLabel"] == "room_living_room"
    assert (
        rules["living-room-motion-hue_ms_living_room"]["cacheLabel"]
        == "room_living_room"
    )


# ---------- motion-on check composition ----------


def test_motion_on_check_has_luminance_and_lights_state_gates() -> None:
    result = _eval_define_rooms(
        """{
      hall = {
        groupName = "hall";
        id = 53;
        members = [ "0xdddd/11" ];
        scenes = defaultDayScenes;
        motionSensor.name = "hue-ms-hall";
      };
    }"""
    )
    rule = result["smind"]["services"]["mqtt-automations"]["rules"][
        "hall-motion-hue_ms_hall"
    ]
    _assert_handler_check_contains(rule, "motion-on", "this.occupancy == true")
    _assert_handler_check_contains(rule, "motion-on", "this.illuminance")
    _assert_handler_check_contains(rule, "motion-on", '(meta("lights_state")')
    # Default maxIlluminance is 100
    _assert_handler_check_contains(rule, "motion-on", "< 100")
    # Default offCooldownSeconds is 30 → 30000ms
    _assert_handler_check_contains(rule, "motion-on", "30000")
    _assert_handler_check_contains(rule, "motion-on", "last_off_at")


def test_motion_on_check_respects_max_illuminance_override() -> None:
    result = _eval_define_rooms(
        """{
      closet = {
        groupName = "closet";
        id = 54;
        members = [ "0xeeee/11" ];
        scenes = defaultDayScenes;
        motionSensor = {
          name = "hue-ms-closet";
          maxIlluminance = 25;
          offCooldownSeconds = 5;
        };
      };
    }"""
    )
    rule = result["smind"]["services"]["mqtt-automations"]["rules"][
        "closet-motion-hue_ms_closet"
    ]
    _assert_handler_check_contains(rule, "motion-on", "< 25")
    _assert_handler_check_contains(rule, "motion-on", "5000")  # 5s in ms


def test_luminance_gate_can_be_disabled() -> None:
    result = _eval_define_rooms(
        """{
      darkroom = {
        groupName = "darkroom";
        id = 55;
        members = [ "0xffff/11" ];
        scenes = defaultDayScenes;
        motionSensor = {
          name = "hue-ms-darkroom";
          maxIlluminance = null;
        };
      };
    }"""
    )
    rule = result["smind"]["services"]["mqtt-automations"]["rules"][
        "darkroom-motion-hue_ms_darkroom"
    ]
    check = rule["handlers"]["motion-on"]["check"]
    assert "illuminance" not in check, (
        f"maxIlluminance=null should remove the luminance clause; "
        f"actual check: {check!r}"
    )


# ---------- multi-sensor ----------


def test_multi_sensor_generates_rule_per_sensor() -> None:
    result = _eval_define_rooms(
        """{
      big-hall = {
        groupName = "big hall";
        id = 56;
        members = [ "0x1111/11" ];
        scenes = defaultDayScenes;
        motionSensor.names = [ "hue-ms-hall-a" "hue-ms-hall-b" "hue-ms-hall-c" ];
      };
    }"""
    )
    rules = result["smind"]["services"]["mqtt-automations"]["rules"]
    assert set(rules) == {
        "big-hall-motion-hue_ms_hall_a",
        "big-hall-motion-hue_ms_hall_b",
        "big-hall-motion-hue_ms_hall_c",
    }
    # All three rules share the same cache resource
    labels = {r["cacheLabel"] for r in rules.values()}
    assert labels == {"room_big_hall"}, f"expected one shared cacheLabel, got {labels}"


def test_multi_sensor_motion_off_checks_other_sensors() -> None:
    result = _eval_define_rooms(
        """{
      big-hall = {
        groupName = "big hall";
        id = 57;
        members = [ "0x2222/11" ];
        scenes = defaultDayScenes;
        motionSensor.names = [ "hue-ms-a" "hue-ms-b" ];
      };
    }"""
    )
    rules = result["smind"]["services"]["mqtt-automations"]["rules"]
    # Sensor A's motion-off should guard on motion_hue_ms_b != "1"
    _assert_handler_check_contains(
        rules["big-hall-motion-hue_ms_a"],
        "motion-off",
        'meta("motion_hue_ms_b")',
    )
    # And vice-versa
    _assert_handler_check_contains(
        rules["big-hall-motion-hue_ms_b"],
        "motion-off",
        'meta("motion_hue_ms_a")',
    )
    # Neither should check its own flag — that's about to change in
    # the same rule's preDispatch, so self-check would be wrong
    assert (
        'meta("motion_hue_ms_a")'
        not in rules["big-hall-motion-hue_ms_a"]["handlers"]["motion-off"]["check"]
    )


def test_multi_sensor_pre_dispatch_updates_own_flag() -> None:
    """Every motion rule must have a preDispatch step that unconditionally
    writes motion_<self> based on `this.occupancy`. Without it, a sensor
    whose motion-on was short-circuited never records its own state and
    later motion-off from another sensor wrongly sees the gap as
    "inactive"."""
    result = _eval_define_rooms(
        """{
      big-hall = {
        groupName = "big hall";
        id = 58;
        members = [ "0x3333/11" ];
        scenes = defaultDayScenes;
        motionSensor.names = [ "hue-ms-a" "hue-ms-b" ];
      };
    }"""
    )
    rules = result["smind"]["services"]["mqtt-automations"]["rules"]
    for rule_name, expected_key in [
        ("big-hall-motion-hue_ms_a", "motion_hue_ms_a"),
        ("big-hall-motion-hue_ms_b", "motion_hue_ms_b"),
    ]:
        pre = rules[rule_name].get("preDispatch", [])
        assert pre, f"{rule_name} has no preDispatch"
        # Expect a mapping + a cache.set targeting the sensor's own key
        cache_set = next(
            (p for p in pre if "cache" in p and p["cache"].get("operator") == "set"),
            None,
        )
        assert cache_set is not None, (
            f"{rule_name} preDispatch is missing a cache.set: {pre}"
        )
        assert cache_set["cache"]["key"] == expected_key


# ---------- hue-setup ----------


def test_hue_setup_groups_contain_members_and_scenes() -> None:
    """Members written as friendly names round-trip into the rendered
    hue-setup config unchanged. The mapping is supplied explicitly so
    the assertion can compare exact strings."""
    result = _eval_define_rooms(
        """{
      study = {
        groupName = "study";
        id = 60;
        members = [ "lamp-study-1/11" "lamp-study-2/11" ];
        switch = "hue-s-study";
        scenes = defaultDayScenes;
      };
    }""",
        address_by_name={
            "lamp-study-1": "0x4444",
            "lamp-study-2": "0x5555",
            "hue-s-study": "0xff01",
        },
    )
    groups = result["smind"]["services"]["hue-setup"]["config"]["groups"]
    assert "study" in groups
    study = groups["study"]
    assert study["id"] == 60
    assert study["members"] == ["lamp-study-1/11", "lamp-study-2/11"]
    # Three default scenes
    assert len(study["scenes"]) == 3
    scene_ids = sorted(s["id"] for s in study["scenes"])
    assert scene_ids == [1, 2, 3]


def test_hue_setup_devices_emits_motion_sensor_options() -> None:
    """Every motion sensor gets a devices entry with the canonical
    three options: occupancy_timeout, motion_sensitivity, led_indication.
    Multi-sensor rooms emit one entry per sensor with identical values."""
    result = _eval_define_rooms(
        """{
      hall = {
        groupName = "hall";
        id = 61;
        members = [ "0x6666/11" ];
        scenes = defaultDayScenes;
        motionSensor = {
          names = [ "hue-ms-hall-a" "hue-ms-hall-b" ];
          occupancyTimeoutSeconds = 75;
          sensitivity = "high";
          ledIndication = false;
        };
      };
    }"""
    )
    devices = result["smind"]["services"]["hue-setup"]["config"]["devices"]
    assert set(devices) == {"hue-ms-hall-a", "hue-ms-hall-b"}
    for name in ["hue-ms-hall-a", "hue-ms-hall-b"]:
        assert devices[name]["options"] == {
            "occupancy_timeout": 75,
            "motion_sensitivity": "high",
            "led_indication": False,
        }


# ---------- validation errors ----------


def _eval_expect_error(
    rooms_nix: str,
    *,
    address_by_name: dict[str, str] | None = None,
) -> str:
    """Evaluate the given rooms block and expect nix eval to fail.
    Returns the stderr text for assertions."""
    if address_by_name is None:
        address_by_name = _auto_address_by_name(rooms_nix)
    addr_nix = _render_address_by_name_nix(address_by_name)
    expr = f"""
let
  pkgs = import <nixpkgs> {{ }};
  lib = pkgs.lib;
  tools = import {TOOLS_PATH} {{ inherit lib; }};
  inherit (tools) defaultDayScenes;
in
tools.defineRooms {{
  addressByName = {addr_nix};
  rooms = {rooms_nix};
}}
"""
    result = subprocess.run(
        ["nix", "eval", "--impure", "--json", "--expr", expr],
        capture_output=True,
        text=True,
        env={**os.environ, "NIX_CONFIG": "experimental-features = nix-command flakes"},
    )
    assert result.returncode != 0, (
        f"expected nix eval to fail, but it succeeded with stdout: {result.stdout}"
    )
    return result.stderr


def test_validation_duplicate_group_id() -> None:
    err = _eval_expect_error(
        """{
      a = {
        groupName = "a"; id = 1; members = [ "0x1/11" ];
        switch = "hue-s-a"; scenes = defaultDayScenes;
      };
      b = {
        groupName = "b"; id = 1; members = [ "0x2/11" ];
        switch = "hue-s-b"; scenes = defaultDayScenes;
      };
    }"""
    )
    assert "duplicate group id" in err


def test_validation_requires_control_source() -> None:
    err = _eval_expect_error(
        """{
      orphan = {
        groupName = "orphan"; id = 1; members = [ "0x1/11" ];
        scenes = defaultDayScenes;
      };
    }"""
    )
    assert "neither `switch` nor `motionSensor`" in err


def test_validation_catches_shared_bulb_scene_conflict() -> None:
    err = _eval_expect_error(
        """{
      room-a = {
        groupName = "room-a"; id = 1; members = [ "shared-bulb/11" ];
        switch = "hue-s-a";
        scenes = [
          { id = 1; name = "bright"; state = "ON"; brightness = 254; color_temp = 250; transition = 0.5; }
        ];
      };
      room-b = {
        groupName = "room-b"; id = 2; members = [ "shared-bulb/11" ];
        switch = "hue-s-b";
        scenes = [
          { id = 1; name = "dim"; state = "ON"; brightness = 100; color_temp = 400; transition = 0.5; }
        ];
      };
    }"""
    )
    assert "per-bulb scene conflicts" in err
    assert "shared-bulb/11" in err


# ---------- addressByName / device reference resolution ----------


def test_address_by_name_translates_hardware_id_to_friendly() -> None:
    """A room that references a bulb by its `0x...` hardware id has
    that reference rewritten to the canonical friendly name in the
    rendered hue-setup config. The bento source/target topics are
    derived from the friendly form too."""
    result = _eval_define_rooms(
        """{
      study = {
        groupName = "study";
        id = 60;
        members = [ "0x1234abcd/11" ];
        switch = "0xff00aabb";
        scenes = defaultDayScenes;
      };
    }""",
        address_by_name={
            "lamp-study": "0x1234abcd",
            "hue-s-study": "0xff00aabb",
        },
    )
    study = result["smind"]["services"]["hue-setup"]["config"]["groups"]["study"]
    assert study["members"] == ["lamp-study/11"]
    rule = result["smind"]["services"]["mqtt-automations"]["rules"]["study-switch"]
    # The bento source topic uses the friendly name, not the 0x form,
    # because z2m only publishes /action under the friendly_name path.
    assert rule["source"] == "zigbee2mqtt/hue-s-study/action"


def test_address_by_name_inverse_threaded_into_hue_setup_config() -> None:
    """The inverse mapping (ieee → friendly) is rendered into
    `hue-setup.config.name_by_address` so the runtime rename phase
    has the same source of truth that drove the build-time
    translation."""
    result = _eval_define_rooms(
        """{
      study = {
        groupName = "study";
        id = 60;
        members = [ "lamp-a/11" ];
        switch = "hue-s-study";
        scenes = defaultDayScenes;
      };
    }""",
        address_by_name={
            "lamp-a": "0x0000000000000aaa",
            "hue-s-study": "0x0000000000000bbb",
        },
    )
    name_by_address = result["smind"]["services"]["hue-setup"]["config"]["name_by_address"]
    assert name_by_address == {
        "0x0000000000000aaa": "lamp-a",
        "0x0000000000000bbb": "hue-s-study",
    }


def test_validation_unknown_friendly_name_in_members() -> None:
    """A friendly name in `members` that isn't in `addressByName`
    fails the build with a precise error message."""
    err = _eval_expect_error(
        """{
      study = {
        groupName = "study"; id = 1; members = [ "lamp-mystery/11" ];
        switch = "hue-s-study"; scenes = defaultDayScenes;
      };
    }""",
        address_by_name={
            "hue-s-study": "0xff01",
            # lamp-mystery deliberately omitted
        },
    )
    assert "lamp-mystery" in err
    assert "addressByName" in err


def test_validation_unknown_hardware_id_in_members() -> None:
    """A `0x...` hardware id in `members` that isn't in `addressByName`
    fails the build with a precise error message."""
    err = _eval_expect_error(
        """{
      study = {
        groupName = "study"; id = 1; members = [ "0xdeadbeef/11" ];
        switch = "hue-s-study"; scenes = defaultDayScenes;
      };
    }""",
        address_by_name={
            "hue-s-study": "0xff01",
            # 0xdeadbeef deliberately omitted
        },
    )
    assert "0xdeadbeef" in err
    assert "addressByName" in err


def test_validation_unknown_switch_friendly_name() -> None:
    """A switch reference that isn't in addressByName also fails."""
    err = _eval_expect_error(
        """{
      study = {
        groupName = "study"; id = 1; members = [ "lamp-a/11" ];
        switch = "hue-s-mystery"; scenes = defaultDayScenes;
      };
    }""",
        address_by_name={"lamp-a": "0xaaaa"},
    )
    assert "hue-s-mystery" in err


def test_validation_unknown_motion_sensor_name() -> None:
    """A motionSensor.name that isn't in addressByName also fails."""
    err = _eval_expect_error(
        """{
      study = {
        groupName = "study"; id = 1; members = [ "lamp-a/11" ];
        motionSensor = { name = "hue-ms-mystery"; };
        scenes = defaultDayScenes;
      };
    }""",
        address_by_name={"lamp-a": "0xaaaa"},
    )
    assert "hue-ms-mystery" in err


def test_validation_duplicate_address_in_address_by_name() -> None:
    """Two friendly names mapping to the same hardware id is a
    typo/paste-error signal — surfaced as a build error."""
    err = _eval_expect_error(
        """{
      study = {
        groupName = "study"; id = 1; members = [ "lamp-a/11" ];
        switch = "hue-s-study"; scenes = defaultDayScenes;
      };
    }""",
        address_by_name={
            "lamp-a": "0xaaaa",
            "lamp-b": "0xaaaa",  # duplicate ieee
            "hue-s-study": "0xff01",
        },
    )
    assert "must be unique per device" in err
