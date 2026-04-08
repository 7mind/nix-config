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


_TYPE_PREFIXES = {
    "light": "hue-l-",
    "switch": "hue-s-",
    "tap": "hue-ts-",
    "motion-sensor": "hue-ms-",
}


def _infer_type_from_name(name: str) -> str:
    """Reverse the prefix convention to guess a device's type from
    its friendly_name. Used by the auto-mapper so test snippets can
    just write `device = "hue-l-foo"` without spelling out the type.

    Order matters: longer prefixes are checked first because
    `hue-ts-` would match `hue-s-` if the latter were checked first.
    """
    for type_name, prefix in sorted(
        _TYPE_PREFIXES.items(), key=lambda kv: -len(kv[1])
    ):
        if name.startswith(prefix):
            return type_name
    return "light"  # default — most synthetic test refs are bulbs


def _auto_devices_by_address(rooms_nix: str) -> dict[str, dict[str, str]]:
    """Synthesize a `devicesByAddress` catalog that covers every device
    reference present in the given rooms snippet.

    `defineRooms` now requires every reference (in `members`,
    `switches[*].device`, `motionSensor.device(s)`) to resolve
    through an explicit catalog of `{ type; name; }` keyed by ieee.
    Auto-generating one from the snippet keeps tests ergonomic.

    For each friendly_name reference, the type is inferred from its
    `hue-l-`/`hue-s-`/`hue-ts-`/`hue-ms-` prefix. Refs that don't
    match any prefix default to `light`.

    For each 0x... reference, a synthetic friendly_name is invented
    with the `hue-l-` prefix so prefix validation passes for the
    default `light` type.
    """
    member_re = re.compile(r'"([^"\s/]+)/\d+"')
    # Only match `device = "..."` device refs. Scene blocks have
    # `name = "..."` fields too, and matching them would pollute the
    # auto-mapper with scene names that aren't devices at all.
    name_assign_re = re.compile(r'device\s*=\s*"([^"]+)"')
    names_list_re = re.compile(r'devices\s*=\s*\[\s*((?:"[^"]+"\s*)+)\]')

    refs: set[str] = set()
    refs.update(member_re.findall(rooms_nix))
    refs.update(name_assign_re.findall(rooms_nix))
    for names_block in names_list_re.findall(rooms_nix):
        refs.update(re.findall(r'"([^"]+)"', names_block))

    catalog: dict[str, dict[str, str]] = {}
    synth_bulb_counter = 0
    synth_ieee_counter = 0
    for ref in sorted(refs):
        if ref.startswith("0x"):
            synth_name = f"hue-l-_synth_bulb_{synth_bulb_counter}"
            synth_bulb_counter += 1
            catalog[ref] = {"type": "light", "name": synth_name}
        else:
            synth_addr = f"0xfe00000000{synth_ieee_counter:06x}"
            synth_ieee_counter += 1
            catalog[synth_addr] = {
                "type": _infer_type_from_name(ref),
                "name": ref,
            }
    return catalog


def _render_devices_by_address_nix(
    devices: dict[str, dict[str, str]],
) -> str:
    """Render a Python catalog as a Nix attrset literal in the
    `{ ieee = { type; name; }; ... }` form. Device-id strings never
    contain quotes so a naive renderer is sufficient."""
    entries = " ".join(
        f'"{ieee}" = {{ type = "{d["type"]}"; name = "{d["name"]}"; }};'
        for ieee, d in sorted(devices.items())
    )
    return "{ " + entries + " }"


def _eval_define_rooms(
    rooms_nix: str,
    *,
    devices_by_address: dict[str, dict[str, str]] | None = None,
) -> dict[str, Any]:
    """Evaluate `defineRooms { devicesByAddress = ...; rooms = ...; }`
    with the given rooms snippet and return the JSON-decoded result.

    `devices_by_address` defaults to an auto-extracted catalog
    covering every device reference in `rooms_nix`, with types
    inferred from the friendly_name prefix convention. Tests that
    want to verify a specific catalog (or trigger a validation
    error) pass their own.
    """
    if devices_by_address is None:
        devices_by_address = _auto_devices_by_address(rooms_nix)
    devices_nix = _render_devices_by_address_nix(devices_by_address)
    expr = f"""
let
  pkgs = import <nixpkgs> {{ }};
  lib = pkgs.lib;
  tools = import {TOOLS_PATH} {{ inherit lib; }};
  inherit (tools) defaultScheduledScenes defaultDayScenes;
in
tools.defineRooms {{
  devicesByAddress = {devices_nix};
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
        switches = [ { device = "hue-s-study"; } ];
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
        motionSensor.device = "hue-ms-cellar";
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
        switches = [ { device = "hue-s-living-room"; } ];
        motionSensor.device = "hue-ms-living-room";
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
        motionSensor.device = "hue-ms-hall";
      };
    }"""
    )
    rule = result["smind"]["services"]["mqtt-automations"]["rules"][
        "hall-motion-hue_ms_hall"
    ]
    _assert_handler_check_contains(rule, "motion-on", "this.occupancy == true")
    _assert_handler_check_contains(rule, "motion-on", "this.illuminance")
    _assert_handler_check_contains(rule, "motion-on", '(meta("lights_state")')
    # Default maxIlluminance is 50
    _assert_handler_check_contains(rule, "motion-on", "< 50")
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
          device = "hue-ms-closet";
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
          device = "hue-ms-darkroom";
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
        motionSensor.devices = [ "hue-ms-hall-a" "hue-ms-hall-b" "hue-ms-hall-c" ];
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
        motionSensor.devices = [ "hue-ms-a" "hue-ms-b" ];
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
        motionSensor.devices = [ "hue-ms-a" "hue-ms-b" ];
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
        members = [ "hue-l-study-1/11" "hue-l-study-2/11" ];
        switches = [ { device = "hue-s-study"; } ];
        scenes = defaultDayScenes;
      };
    }""",
        devices_by_address={
            "0x4444": {"type": "light", "name": "hue-l-study-1"},
            "0x5555": {"type": "light", "name": "hue-l-study-2"},
            "0xff01": {"type": "switch", "name": "hue-s-study"},
        },
    )
    groups = result["smind"]["services"]["hue-setup"]["config"]["groups"]
    assert "study" in groups
    study = groups["study"]
    assert study["id"] == 60
    assert study["members"] == ["hue-l-study-1/11", "hue-l-study-2/11"]
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
          devices = [ "hue-ms-hall-a" "hue-ms-hall-b" ];
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
    devices_by_address: dict[str, dict[str, str]] | None = None,
) -> str:
    """Evaluate the given rooms block and expect nix eval to fail.
    Returns the stderr text for assertions."""
    if devices_by_address is None:
        devices_by_address = _auto_devices_by_address(rooms_nix)
    devices_nix = _render_devices_by_address_nix(devices_by_address)
    expr = f"""
let
  pkgs = import <nixpkgs> {{ }};
  lib = pkgs.lib;
  tools = import {TOOLS_PATH} {{ inherit lib; }};
  inherit (tools) defaultDayScenes;
in
tools.defineRooms {{
  devicesByAddress = {devices_nix};
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
        switches = [ { device = "hue-s-a"; } ]; scenes = defaultDayScenes;
      };
      b = {
        groupName = "b"; id = 1; members = [ "0x2/11" ];
        switches = [ { device = "hue-s-b"; } ]; scenes = defaultDayScenes;
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
    assert "neither `switches` nor `motionSensor`" in err


def test_validation_catches_shared_bulb_scene_conflict() -> None:
    err = _eval_expect_error(
        """{
      room-a = {
        groupName = "room-a"; id = 1; members = [ "hue-l-shared/11" ];
        switches = [ { device = "hue-s-a"; } ];
        scenes = [
          { id = 1; name = "bright"; state = "ON"; brightness = 254; color_temp = 250; transition = 0.5; }
        ];
      };
      room-b = {
        groupName = "room-b"; id = 2; members = [ "hue-l-shared/11" ];
        switches = [ { device = "hue-s-b"; } ];
        scenes = [
          { id = 1; name = "dim"; state = "ON"; brightness = 100; color_temp = 400; transition = 0.5; }
        ];
      };
    }"""
    )
    assert "per-bulb scene conflicts" in err
    assert "hue-l-shared/11" in err


# ---------- addressByName / device reference resolution ----------


def test_devices_by_address_translates_hardware_id_to_friendly() -> None:
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
        switches = [ { device = "0xff00aabb"; } ];
        scenes = defaultDayScenes;
      };
    }""",
        devices_by_address={
            "0x1234abcd": {"type": "light", "name": "hue-l-study"},
            "0xff00aabb": {"type": "switch", "name": "hue-s-study"},
        },
    )
    study = result["smind"]["services"]["hue-setup"]["config"]["groups"]["study"]
    assert study["members"] == ["hue-l-study/11"]
    rule = result["smind"]["services"]["mqtt-automations"]["rules"]["study-switch"]
    # The bento source topic uses the friendly name, not the 0x form,
    # because z2m only publishes /action under the friendly_name path.
    assert rule["source"] == "zigbee2mqtt/hue-s-study/action"


def test_devices_by_address_inverse_threaded_into_hue_setup_config() -> None:
    """The catalog's name_by_address (ieee → friendly) is rendered
    into `hue-setup.config.name_by_address` so the runtime rename
    phase has the same source of truth that drove the build-time
    translation."""
    result = _eval_define_rooms(
        """{
      study = {
        groupName = "study";
        id = 60;
        members = [ "hue-l-a/11" ];
        switches = [ { device = "hue-s-study"; } ];
        scenes = defaultDayScenes;
      };
    }""",
        devices_by_address={
            "0x0000000000000aaa": {"type": "light", "name": "hue-l-a"},
            "0x0000000000000bbb": {"type": "switch", "name": "hue-s-study"},
        },
    )
    name_by_address = result["smind"]["services"]["hue-setup"]["config"]["name_by_address"]
    assert name_by_address == {
        "0x0000000000000aaa": "hue-l-a",
        "0x0000000000000bbb": "hue-s-study",
    }


def test_validation_unknown_friendly_name_in_members() -> None:
    """A friendly name in `members` that isn't in `devicesByAddress`
    fails the build with a precise error message."""
    err = _eval_expect_error(
        """{
      study = {
        groupName = "study"; id = 1; members = [ "hue-l-mystery/11" ];
        switches = [ { device = "hue-s-study"; } ]; scenes = defaultDayScenes;
      };
    }""",
        devices_by_address={
            "0xff01": {"type": "switch", "name": "hue-s-study"},
            # hue-l-mystery deliberately omitted
        },
    )
    assert "hue-l-mystery" in err
    assert "devicesByAddress" in err


def test_validation_unknown_hardware_id_in_members() -> None:
    """A `0x...` hardware id in `members` that isn't in
    `devicesByAddress` fails the build with a precise error
    message."""
    err = _eval_expect_error(
        """{
      study = {
        groupName = "study"; id = 1; members = [ "0xdeadbeef/11" ];
        switches = [ { device = "hue-s-study"; } ]; scenes = defaultDayScenes;
      };
    }""",
        devices_by_address={
            "0xff01": {"type": "switch", "name": "hue-s-study"},
            # 0xdeadbeef deliberately omitted
        },
    )
    assert "0xdeadbeef" in err
    assert "devicesByAddress" in err


def test_validation_unknown_switch_friendly_name() -> None:
    """A switch reference that isn't in devicesByAddress also fails."""
    err = _eval_expect_error(
        """{
      study = {
        groupName = "study"; id = 1; members = [ "hue-l-a/11" ];
        switches = [ { device = "hue-s-mystery"; } ]; scenes = defaultDayScenes;
      };
    }""",
        devices_by_address={
            "0xaaaa": {"type": "light", "name": "hue-l-a"},
        },
    )
    assert "hue-s-mystery" in err


def test_validation_unknown_motion_sensor_device() -> None:
    """A motionSensor.device that isn't in devicesByAddress also fails."""
    err = _eval_expect_error(
        """{
      study = {
        groupName = "study"; id = 1; members = [ "hue-l-a/11" ];
        motionSensor = { device = "hue-ms-mystery"; };
        scenes = defaultDayScenes;
      };
    }""",
        devices_by_address={
            "0xaaaa": {"type": "light", "name": "hue-l-a"},
        },
    )
    assert "hue-ms-mystery" in err


def test_validation_duplicate_friendly_name_in_devices_by_address() -> None:
    """Two ieee entries claiming the same friendly_name is a
    typo/paste-error signal — surfaced as a build error. (Under the
    old schema this was the inverse: two friendly_names mapping to
    one ieee. The new schema is keyed by ieee, so the inverse is
    structurally impossible — Nix attrset keys are unique.)"""
    err = _eval_expect_error(
        """{
      study = {
        groupName = "study"; id = 1; members = [ "hue-l-a/11" ];
        switches = [ { device = "hue-s-study"; } ]; scenes = defaultDayScenes;
      };
    }""",
        devices_by_address={
            "0xaaaa": {"type": "light", "name": "hue-l-a"},
            "0xbbbb": {"type": "light", "name": "hue-l-a"},  # duplicate friendly
            "0xff01": {"type": "switch", "name": "hue-s-study"},
        },
    )
    assert "must be unique per device" in err


# ---------- multi-switch / tap-button bindings ----------


def test_multiple_wall_switches_in_one_room_generate_one_rule_each() -> None:
    """A room can list more than one wall switch (e.g. dual-entry
    rooms with one dimmer per door). Each entry produces its own
    bento rule keyed `<ruleName>-switch`. The current production
    config has at most one wall switch per room — this test exists
    so the renderer doesn't quietly drop additional entries."""
    result = _eval_define_rooms(
        """{
      hall = {
        groupName = "hall"; id = 70;
        members = [ "0x7000/11" ];
        switches = [
          { device = "hue-s-hall-front"; }
          { device = "hue-s-hall-back"; }
        ];
        scenes = defaultDayScenes;
      };
    }"""
    )
    rules = result["smind"]["services"]["mqtt-automations"]["rules"]
    # The current renderer collapses multiple entries onto the same
    # `<ruleName>-switch` key (attrset semantics — last write wins).
    # If you ever need true multi-switch support, this assertion is
    # the canary that flags it.
    assert "hall-switch" in rules


def test_tap_button_room_generates_tap_rule() -> None:
    """A room with a tap-button entry produces a `tap-<sanitize tapName>`
    bento rule subscribing to the tap's action topic. The rule has a
    pair of handlers (on/off) for the bound button."""
    result = _eval_define_rooms(
        """{
      kitchen-all = {
        groupName = "kitchen-all"; id = 71;
        members = [ "0x7100/11" ];
        switches = [
          { device = "hue-ts-kitchen"; button = 1; }
        ];
        scenes = defaultDayScenes;
      };
    }"""
    )
    rules = result["smind"]["services"]["mqtt-automations"]["rules"]
    assert "tap-hue_ts_kitchen" in rules
    rule = rules["tap-hue_ts_kitchen"]
    assert rule["source"] == "zigbee2mqtt/hue-ts-kitchen/action"
    # Tap-private cache resource so multiple buttons targeting different
    # rooms can share one bento rule.
    assert rule["cacheLabel"] == "tap_hue_ts_kitchen"
    # Per-room state key is loaded into metadata at pre-dispatch time.
    assert "state_room_kitchen_all" in rule["cacheReads"]
    # Two handlers for one button: on and off
    assert set(rule["handlers"]) == {
        "tap_kitchen_all_button_1_on",
        "tap_kitchen_all_button_1_off",
    }


def test_tap_button_handlers_check_action_and_state() -> None:
    """The on handler fires when the press matches AND the room's
    state key is empty. The off handler is the symmetric inverse."""
    result = _eval_define_rooms(
        """{
      kitchen-all = {
        groupName = "kitchen-all"; id = 72;
        members = [ "0x7200/11" ];
        switches = [
          { device = "hue-ts-kitchen"; button = 1; }
        ];
        scenes = defaultDayScenes;
      };
    }"""
    )
    rule = result["smind"]["services"]["mqtt-automations"]["rules"][
        "tap-hue_ts_kitchen"
    ]
    on = rule["handlers"]["tap_kitchen_all_button_1_on"]
    off = rule["handlers"]["tap_kitchen_all_button_1_off"]

    assert 'content().string() == "press_1"' in on["check"]
    assert '(meta("state_room_kitchen_all").or("")) == ""' in on["check"]
    assert 'content().string() == "press_1"' in off["check"]
    assert '(meta("state_room_kitchen_all").or("")) != ""' in off["check"]

    # The on handler must override the rule-level target via meta
    # out_topic so a single rule can publish to multiple rooms.
    assert 'meta out_topic = "zigbee2mqtt/kitchen-all/set"' in on["publishMapping"]
    # And recall the first scene of the active slot. defaultDayScenes
    # is a flat list whose first entry is scene id 1.
    assert '"scene_recall": 1' in on["publishMapping"]

    assert 'meta out_topic = "zigbee2mqtt/kitchen-all/set"' in off["publishMapping"]
    assert '"state": "OFF"' in off["publishMapping"]

    # cacheWrites flip the state key on each transition.
    assert on["cacheWrites"] == {"state_room_kitchen_all": "user"}
    assert off["cacheWrites"] == {"state_room_kitchen_all": ""}


def test_one_tap_with_multiple_rooms_generates_single_rule() -> None:
    """The whole reason tap rules group by tap device: bento's switch
    processor doesn't fall through, so multiple rules sharing the
    same source topic would silently leave only the first matching
    rule firing. All four kitchen buttons must end up as one rule."""
    result = _eval_define_rooms(
        """{
      kitchen-all = {
        groupName = "kitchen-all"; id = 80;
        members = [ "0x8000/11" ];
        switches = [ { device = "hue-ts-kitchen"; button = 1; } ];
        scenes = defaultDayScenes;
      };
      kitchen-cooker = {
        groupName = "kitchen-cooker"; id = 81;
        members = [ "0x8001/11" ];
        switches = [ { device = "hue-ts-kitchen"; button = 2; } ];
        scenes = defaultDayScenes;
      };
      kitchen-dining = {
        groupName = "kitchen-dining"; id = 82;
        members = [ "0x8002/11" ];
        switches = [ { device = "hue-ts-kitchen"; button = 3; } ];
        scenes = defaultDayScenes;
      };
      kitchen-empty = {
        groupName = "kitchen-empty"; id = 83;
        members = [ "0x8003/11" ];
        switches = [ { device = "hue-ts-kitchen"; button = 4; } ];
        scenes = defaultDayScenes;
      };
    }"""
    )
    rules = result["smind"]["services"]["mqtt-automations"]["rules"]
    # Exactly one rule for the entire tap, not four
    tap_rules = [n for n in rules if n.startswith("tap-")]
    assert tap_rules == ["tap-hue_ts_kitchen"]
    rule = rules["tap-hue_ts_kitchen"]
    # All four buttons present, on + off each
    handler_names = set(rule["handlers"])
    expected = {
        f"tap_{room}_button_{n}_{phase}"
        for room, n in [
            ("kitchen_all", 1),
            ("kitchen_cooker", 2),
            ("kitchen_dining", 3),
            ("kitchen_empty", 4),
        ]
        for phase in ("on", "off")
    }
    assert handler_names == expected
    # cacheReads covers every controlled room so each handler check
    # can branch on its own room's state.
    assert set(rule["cacheReads"]) == {
        "state_room_kitchen_all",
        "state_room_kitchen_cooker",
        "state_room_kitchen_dining",
        "state_room_kitchen_empty",
    }


def test_tap_handlers_publish_to_per_room_targets() -> None:
    """Each handler in the unified tap rule must override out_topic
    to its own room — otherwise the second binding would publish to
    the first binding's target."""
    result = _eval_define_rooms(
        """{
      kitchen-all = {
        groupName = "kitchen-all"; id = 90;
        members = [ "0x9000/11" ];
        switches = [ { device = "hue-ts-kitchen"; button = 1; } ];
        scenes = defaultDayScenes;
      };
      kitchen-cooker = {
        groupName = "kitchen-cooker"; id = 91;
        members = [ "0x9001/11" ];
        switches = [ { device = "hue-ts-kitchen"; button = 2; } ];
        scenes = defaultDayScenes;
      };
    }"""
    )
    handlers = result["smind"]["services"]["mqtt-automations"]["rules"][
        "tap-hue_ts_kitchen"
    ]["handlers"]
    assert (
        'meta out_topic = "zigbee2mqtt/kitchen-all/set"'
        in handlers["tap_kitchen_all_button_1_on"]["publishMapping"]
    )
    assert (
        'meta out_topic = "zigbee2mqtt/kitchen-cooker/set"'
        in handlers["tap_kitchen_cooker_button_2_on"]["publishMapping"]
    )


def test_validation_duplicate_tap_button() -> None:
    """A (tap, button) pair claimed by two rooms is a config error —
    the same physical press would have to drive two different rooms,
    which is exactly the conflict that grouping by tap is supposed
    to surface up front instead of silently."""
    err = _eval_expect_error(
        """{
      kitchen-all = {
        groupName = "kitchen-all"; id = 100;
        members = [ "0xaa00/11" ];
        switches = [ { device = "hue-ts-kitchen"; button = 1; } ];
        scenes = defaultDayScenes;
      };
      kitchen-other = {
        groupName = "kitchen-other"; id = 101;
        members = [ "0xaa01/11" ];
        switches = [ { device = "hue-ts-kitchen"; button = 1; } ];
        scenes = defaultDayScenes;
      };
    }"""
    )
    assert "duplicate tap button" in err
    assert "hue-ts-kitchen/1" in err


def test_validation_duplicate_wall_switch_across_rooms() -> None:
    """A wall switch device referenced by two rooms is a config
    error: the cycle handlers would fight each other."""
    err = _eval_expect_error(
        """{
      a = {
        groupName = "a"; id = 110;
        members = [ "0xb000/11" ];
        switches = [ { device = "hue-s-shared"; } ];
        scenes = defaultDayScenes;
      };
      b = {
        groupName = "b"; id = 111;
        members = [ "0xb001/11" ];
        switches = [ { device = "hue-s-shared"; } ];
        scenes = defaultDayScenes;
      };
    }"""
    )
    assert "duplicate wall switch friendly_name" in err


def test_validation_switches_entry_requires_device_field() -> None:
    """A switches entry must have a `device` field."""
    err = _eval_expect_error(
        """{
      a = {
        groupName = "a"; id = 120;
        members = [ "0xc000/11" ];
        switches = [
          { button = 1; }  # missing `device`
        ];
        scenes = defaultDayScenes;
      };
    }"""
    )
    assert "must specify `device" in err


def test_validation_tap_entry_requires_button() -> None:
    """A tap-typed device referenced from a switches entry must come
    with a `button = N` field — without it the renderer wouldn't
    know which button to bind."""
    err = _eval_expect_error(
        """{
      a = {
        groupName = "a"; id = 130;
        members = [ "0xd000/11" ];
        switches = [ { device = "hue-ts-foo"; } ];
        scenes = defaultDayScenes;
      };
    }""",
        devices_by_address={
            "0xd000": {"type": "light", "name": "hue-l-_synth_bulb_0"},
            "0xfeed00000000": {"type": "tap", "name": "hue-ts-foo"},
        },
    )
    assert "must specify `button = N`" in err


def test_validation_wall_switch_entry_rejects_button() -> None:
    """A wall-switch device referenced with a `button` field is a
    config error — buttons only make sense for taps."""
    err = _eval_expect_error(
        """{
      a = {
        groupName = "a"; id = 131;
        members = [ "0xd100/11" ];
        switches = [ { device = "hue-s-foo"; button = 1; } ];
        scenes = defaultDayScenes;
      };
    }""",
        devices_by_address={
            "0xd100": {"type": "light", "name": "hue-l-_synth_bulb_0"},
            "0xfeed00000000": {"type": "switch", "name": "hue-s-foo"},
        },
    )
    assert "must not specify `button`" in err


def test_tap_button_with_slotted_scenes_picks_active_slot() -> None:
    """For slotted scenes the on handler's publishMapping must contain
    the if/else slot chain so it picks the right scene at press time
    based on the current local hour. Same shape as the motion-on
    payload mapping."""
    result = _eval_define_rooms(
        """{
      kitchen-all = {
        groupName = "kitchen-all"; id = 140;
        members = [ "0xe000/11" ];
        switches = [ { device = "hue-ts-kitchen"; button = 1; } ];
        scenes = defaultScheduledScenes;
      };
    }"""
    )
    handlers = result["smind"]["services"]["mqtt-automations"]["rules"][
        "tap-hue_ts_kitchen"
    ]["handlers"]
    on_mapping = handlers["tap_kitchen_all_button_1_on"]["publishMapping"]
    # The slotted form has the bloblang time-of-day variable
    assert "timestamp_unix()" in on_mapping
    # And an if/else over the slot predicates
    assert "if " in on_mapping and "else" in on_mapping
    # Both day and night scene IDs are referenced
    assert '"scene_recall"' in on_mapping


# ---------- type-aware validation (devicesByAddress) ----------


def test_validation_friendly_name_must_match_type_prefix() -> None:
    """A typed entry whose friendly_name doesn't start with the
    convention prefix fails the build. Catches typos like
    `type = "light"; name = "hue-s-foo"`."""
    err = _eval_expect_error(
        """{
      study = {
        groupName = "study"; id = 1; members = [ "hue-l-foo/11" ];
        switches = [ { device = "hue-s-foo"; } ]; scenes = defaultDayScenes;
      };
    }""",
        devices_by_address={
            # Light entry with switch-shaped name → fails
            "0xaaaa": {"type": "light", "name": "hue-s-foo"},
            "0xbbbb": {"type": "switch", "name": "hue-s-foo"},
        },
    )
    assert "does not start with the required prefix" in err
    assert "hue-l-" in err


def test_validation_unknown_type_rejected() -> None:
    """A device with a type that isn't in the known set fails the
    build with a clear list of known types."""
    err = _eval_expect_error(
        """{
      study = {
        groupName = "study"; id = 1; members = [ "hue-l-a/11" ];
        switches = [ { device = "hue-s-a"; } ]; scenes = defaultDayScenes;
      };
    }""",
        devices_by_address={
            "0xaaaa": {"type": "light", "name": "hue-l-a"},
            "0xbbbb": {"type": "wall-plug", "name": "hue-s-a"},  # invalid type
        },
    )
    assert "unknown type 'wall-plug'" in err


def test_validation_unknown_type_skips_prefix_check() -> None:
    """The escape-hatch `unknown` type allows arbitrary friendly_names
    so devices can be parked in the catalog without committing to a
    role. The unknown device may not itself be referenced from any
    room, so this test only puts it alongside a normal entry."""
    result = _eval_define_rooms(
        """{
      study = {
        groupName = "study"; id = 1; members = [ "hue-l-a/11" ];
        switches = [ { device = "hue-s-a"; } ]; scenes = defaultDayScenes;
      };
    }""",
        devices_by_address={
            "0xaaaa": {"type": "light", "name": "hue-l-a"},
            "0xbbbb": {"type": "switch", "name": "hue-s-a"},
            # Free-form name, no prefix — would fail for any other type
            "0xcccc": {"type": "unknown", "name": "0xparked-device-x-3"},
        },
    )
    # Catalog includes the unknown device but rooms don't reference it
    name_by_address = result["smind"]["services"]["hue-setup"]["config"]["name_by_address"]
    assert name_by_address["0xcccc"] == "0xparked-device-x-3"


def test_validation_unknown_type_cannot_be_referenced() -> None:
    """A device of type `unknown` may not appear in any room
    reference position — that's the whole point of `unknown`."""
    err = _eval_expect_error(
        """{
      study = {
        groupName = "study"; id = 1; members = [ "0xparked-device/11" ];
        switches = [ { device = "hue-s-a"; } ]; scenes = defaultDayScenes;
      };
    }""",
        devices_by_address={
            "0xparked-device": {"type": "unknown", "name": "0xparked-device-1"},
            "0xbbbb": {"type": "switch", "name": "hue-s-a"},
        },
    )
    assert "type 'unknown'" in err
    assert "requires one of" in err


def test_validation_member_must_be_a_light() -> None:
    """A switch (or anything non-light) referenced in `members` is a
    config error — only lights belong in a group's member list."""
    err = _eval_expect_error(
        """{
      study = {
        groupName = "study"; id = 1; members = [ "hue-s-a/11" ];
        switches = [ { device = "hue-s-b"; } ]; scenes = defaultDayScenes;
      };
    }""",
        devices_by_address={
            "0xaaaa": {"type": "switch", "name": "hue-s-a"},
            "0xbbbb": {"type": "switch", "name": "hue-s-b"},
        },
    )
    assert "type 'switch'" in err
    assert "requires one of [light]" in err


def test_validation_switches_entry_rejects_a_light() -> None:
    """A light referenced in a switches entry is a config error —
    only switch and tap types are valid control devices."""
    err = _eval_expect_error(
        """{
      study = {
        groupName = "study"; id = 1; members = [ "hue-l-a/11" ];
        switches = [ { device = "hue-l-other"; } ]; scenes = defaultDayScenes;
      };
    }""",
        devices_by_address={
            "0xaaaa": {"type": "light", "name": "hue-l-a"},
            "0xbbbb": {"type": "light", "name": "hue-l-other"},
        },
    )
    assert "type 'light'" in err
    assert "requires one of [switch, tap]" in err


def test_validation_motion_sensor_rejects_a_light() -> None:
    """A light referenced as a motionSensor.device is a config
    error — only motion-sensor types are valid there."""
    err = _eval_expect_error(
        """{
      study = {
        groupName = "study"; id = 1; members = [ "hue-l-a/11" ];
        motionSensor = { device = "hue-l-other"; };
        scenes = defaultDayScenes;
      };
    }""",
        devices_by_address={
            "0xaaaa": {"type": "light", "name": "hue-l-a"},
            "0xbbbb": {"type": "light", "name": "hue-l-other"},
        },
    )
    assert "type 'light'" in err
    assert "requires one of [motion-sensor]" in err


def test_validation_dispatches_tap_vs_switch_by_resolved_type() -> None:
    """The renderer dispatches a switches entry to either a wall-
    switch (cycle) rule or a tap (toggle) rule based on the *type*
    of the resolved device. Same `{ device = ... }` shape, two
    different rule kinds in the output."""
    result = _eval_define_rooms(
        """{
      study = {
        groupName = "study"; id = 1; members = [ "hue-l-a/11" ];
        switches = [ { device = "hue-s-foo"; } ];
        scenes = defaultDayScenes;
      };
      kitchen = {
        groupName = "kitchen"; id = 2; members = [ "hue-l-b/11" ];
        switches = [ { device = "hue-ts-foo"; button = 1; } ];
        scenes = defaultDayScenes;
      };
    }""",
        devices_by_address={
            "0xaaaa": {"type": "light", "name": "hue-l-a"},
            "0xbbbb": {"type": "light", "name": "hue-l-b"},
            "0xcccc": {"type": "switch", "name": "hue-s-foo"},
            "0xdddd": {"type": "tap", "name": "hue-ts-foo"},
        },
    )
    rules = result["smind"]["services"]["mqtt-automations"]["rules"]
    # Cycle rule for the wall switch
    assert "study-switch" in rules
    assert rules["study-switch"]["source"] == "zigbee2mqtt/hue-s-foo/action"
    # Tap rule for the tap device
    assert "tap-hue_ts_foo" in rules
    assert rules["tap-hue_ts_foo"]["source"] == "zigbee2mqtt/hue-ts-foo/action"


