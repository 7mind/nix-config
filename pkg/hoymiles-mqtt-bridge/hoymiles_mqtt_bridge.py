"""
Hoymiles → MQTT bridge with Home Assistant discovery.

Polls one or more Hoymiles DTU endpoints (HMS-W series with embedded DTU, or
external DTU sticks like DTU-WLite-S / DTU-Pro) over the local protobuf
protocol via the `hoymiles-wifi` library, and publishes inverter / port /
DTU readings to MQTT in a Home-Assistant-discoverable shape.

Design notes:

* One asyncio task per DTU. Failures of one DTU don't stall the others.
* HA discovery topics are republished on every successful first poll after a
  reconnect (covers HA restarts and discovery-cleared topics).
* MQTT availability is per-DTU (`avty_t` references the per-DTU topic), so a
  dead DTU shows its devices as "Unavailable" in HA without affecting the
  other DTU.
* Encryption is auto-detected and re-checked periodically — Hoymiles rotates
  the random key, and stale `enc_rand` returns garbage frames.
* Numeric scaling matches `ha-hoymiles-wifi`'s `conversion_factor` table.
"""

from __future__ import annotations

import argparse
import asyncio
import dataclasses
import datetime
import json
import logging
import os
import signal
import sys
from typing import Any

import aiomqtt
from hoymiles_wifi.dtu import DTU
from hoymiles_wifi.hoymiles import (
    generate_dtu_version_string,
    generate_inverter_serial_number,
    generate_sw_version_string,
    get_dtu_model_name,
    get_inverter_model_name,
    is_encrypted_dtu,
)

# Empirical: protobuf reports inverter SNs as int64 in sgs/pv records but
# the DTU's own SN at the parent message level is already a string.

LOG = logging.getLogger("hoymiles_mqtt_bridge")

# Re-detect DTU encryption parameters every N polls. The rolling `enc_rand` is
# stable across short windows but can rotate; if we keep using a stale value
# the DTU silently returns junk decryption.
ENCRYPTION_RECHECK_EVERY = 30


@dataclasses.dataclass(frozen=True)
class Endpoint:
    name: str
    host: str
    # When True, a run of failed polls flips the DTU into "stale mode" rather
    # than marking its sensors Unavailable. Useful for DTUs that power down
    # with the inverter (e.g. HMS-800W-2T's embedded DTU drops WiFi at night).
    stale_mode: bool = False
    # When True, per-port `energy_daily` is clamped to its running per-day max
    # so a mid-day drop to 0 (seen on DTU-WLite-S after sundown) doesn't look
    # like a counter reset to HA's total_increasing state_class. The held max
    # resets at local midnight, after which the DTU's fresh 0 is accepted.
    hold_daily_energy: bool = False


# Sensor stale-mode behavior. See STALE_BEHAVIOR_* constants.
# - "unavailable": sensor uses the primary DTU availability topic and goes
#   Unavailable in HA while the DTU is stale.
# - "zero":        sensor uses the persistent availability topic, stays
#   online, and gets force-zeroed on entry to stale mode.
# - "preserve":    sensor uses the persistent availability topic, stays
#   online, and keeps its last-known value through the stale window.
STALE_BEHAVIOR_UNAVAILABLE = "unavailable"
STALE_BEHAVIOR_ZERO = "zero"
STALE_BEHAVIOR_PRESERVE = "preserve"


@dataclasses.dataclass(frozen=True)
class SensorSpec:
    """Describes how to publish one numeric field as an HA sensor."""

    key: str
    name: str
    unit: str | None
    device_class: str | None
    state_class: str | None
    factor: float = 1.0
    icon: str | None = None
    stale_behavior: str = STALE_BEHAVIOR_UNAVAILABLE


# Per-inverter (single-phase grid section). HMS-800W-2T and HMS-2000-4T both
# present sgs_data, not tgs_data — they are single-phase microinverters.
INVERTER_SENSORS: tuple[SensorSpec, ...] = (
    SensorSpec("active_power", "Active Power", "W", "power", "measurement", 0.1,
               stale_behavior=STALE_BEHAVIOR_ZERO),
    SensorSpec("reactive_power", "Reactive Power", "var", "reactive_power", "measurement", 0.1),
    SensorSpec("voltage", "Grid Voltage", "V", "voltage", "measurement", 0.1),
    SensorSpec("current", "Grid Current", "A", "current", "measurement", 0.01),
    SensorSpec("frequency", "Grid Frequency", "Hz", "frequency", "measurement", 0.01),
    SensorSpec("power_factor", "Power Factor", None, "power_factor", "measurement", 0.1),
    SensorSpec("temperature", "Temperature", "°C", "temperature", "measurement", 0.1),
    SensorSpec("warning_number", "Warning Count", None, None, "measurement"),
    SensorSpec("link_status", "Link Status", None, None, "measurement"),
    SensorSpec("modulation_index_signal", "Modulation Index", None, None, "measurement"),
)

# Per-PV-port (DC side).
PORT_SENSORS: tuple[SensorSpec, ...] = (
    SensorSpec("voltage", "DC Voltage", "V", "voltage", "measurement", 0.1),
    SensorSpec("current", "DC Current", "A", "current", "measurement", 0.01),
    SensorSpec("power", "DC Power", "W", "power", "measurement", 0.1,
               stale_behavior=STALE_BEHAVIOR_ZERO),
    # Protobuf reports energies as integer Wh; we publish as kWh so HA
    # charts/cards read naturally and the recorder stays precise enough
    # (the 0.001 factor + round-to-4 in _scale() preserves 0.1 Wh resolution).
    SensorSpec("energy_total", "Total Energy", "kWh", "energy", "total_increasing", 0.001,
               stale_behavior=STALE_BEHAVIOR_PRESERVE),
    SensorSpec("energy_daily", "Daily Energy", "kWh", "energy", "total_increasing", 0.001,
               stale_behavior=STALE_BEHAVIOR_PRESERVE),
    SensorSpec("error_code", "Error Code", None, None, "measurement"),
)

# DTU-aggregate sensors. We compute these from per-port sums (the embedded
# DTU on HMS-W inverters returns zero for its own dtu_power / dtu_daily_energy
# fields — only standalone DTU sticks aggregate). All values are pre-scaled
# floats by the time they land in the MQTT payload, so factor=1.0 here.
DTU_SENSORS: tuple[SensorSpec, ...] = (
    SensorSpec("dtu_power", "Total Power", "W", "power", "measurement",
               stale_behavior=STALE_BEHAVIOR_ZERO),
    SensorSpec("dtu_daily_energy", "Total Daily Energy", "kWh", "energy", "total_increasing",
               stale_behavior=STALE_BEHAVIOR_PRESERVE),
    SensorSpec("dtu_total_energy", "Total Lifetime Energy", "kWh", "energy", "total_increasing",
               stale_behavior=STALE_BEHAVIOR_PRESERVE),
    # Raw vendor value; scale varies with firmware (0-99 on WiFi, dBm-ish on
    # SIM). Left unit-less — HA will graph it as a plain number.
    SensorSpec("signal_strength", "Signal Strength", None, None, "measurement"),
)

# Cross-DTU "installation" device: same shape as DTU sensors but summed across
# every DTU/inverter/port the bridge knows about.
INSTALLATION_SENSORS: tuple[SensorSpec, ...] = (
    SensorSpec("current_power", "Total Power", "W", "power", "measurement",
               stale_behavior=STALE_BEHAVIOR_ZERO),
    SensorSpec("daily_energy", "Total Daily Energy", "kWh", "energy", "total_increasing",
               stale_behavior=STALE_BEHAVIOR_PRESERVE),
    SensorSpec("total_energy", "Total Lifetime Energy", "kWh", "energy", "total_increasing",
               stale_behavior=STALE_BEHAVIOR_PRESERVE),
)
INSTALLATION_DEVICE_ID = "hoymiles_installation"


def setup_logging(level: str) -> None:
    logging.basicConfig(
        level=getattr(logging, level.upper()),
        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
    )


def env(key: str, default: str | None = None, *, required: bool = False) -> str | None:
    value = os.environ.get(key, default)
    if required and not value:
        sys.exit(f"missing required env var: {key}")
    return value


def parse_endpoints(spec: str, stale_names: set[str],
                    hold_daily_names: set[str]) -> list[Endpoint]:
    """`HOYMILES_ENDPOINTS` is `name=host[,name=host...]`."""
    out: list[Endpoint] = []
    for entry in spec.split(","):
        entry = entry.strip()
        if not entry:
            continue
        if "=" not in entry:
            sys.exit(f"invalid endpoint spec {entry!r}: expected name=host")
        name, host = entry.split("=", 1)
        name = name.strip()
        out.append(Endpoint(name=name, host=host.strip(),
                            stale_mode=name in stale_names,
                            hold_daily_energy=name in hold_daily_names))
    if not out:
        sys.exit("HOYMILES_ENDPOINTS produced no endpoints")
    known = {e.name for e in out}
    unknown = stale_names - known
    if unknown:
        sys.exit(f"HOYMILES_STALE_ENDPOINTS references unknown endpoint(s): "
                 f"{sorted(unknown)}")
    unknown = hold_daily_names - known
    if unknown:
        sys.exit(f"HOYMILES_HOLD_DAILY_ENERGY_ENDPOINTS references unknown "
                 f"endpoint(s): {sorted(unknown)}")
    return out


def parse_name_list(spec: str | None) -> set[str]:
    if not spec:
        return set()
    return {s.strip() for s in spec.split(",") if s.strip()}


# --- HA discovery payload helpers --------------------------------------------


def _device_block(*, identifiers: str, name: str, model: str | None,
                  sw_version: str | None, manufacturer: str = "Hoymiles",
                  via_device: str | None = None) -> dict[str, Any]:
    block: dict[str, Any] = {
        "ids": [identifiers],
        "name": name,
        "mf": manufacturer,
    }
    if model:
        block["mdl"] = model
    if sw_version:
        block["sw"] = sw_version
    if via_device:
        block["via_device"] = via_device
    return block


def _binary_sensor_payload(*, unique_id: str, name: str, state_topic: str,
                           availability_topic: str, value_template: str,
                           device_class: str | None, device: dict[str, Any],
                           diagnostic: bool = False) -> dict[str, Any]:
    """HA MQTT-discovery payload for a binary_sensor.

    `value_template` must render to the literal `ON` or `OFF`.
    """
    payload: dict[str, Any] = {
        "uniq_id": unique_id,
        "name": name,
        "stat_t": state_topic,
        "val_tpl": value_template,
        "pl_on": "ON",
        "pl_off": "OFF",
        "avty_t": availability_topic,
        "dev": device,
    }
    if device_class is not None:
        payload["dev_cla"] = device_class
    if diagnostic:
        payload["ent_cat"] = "diagnostic"
    return payload


def _button_payload(*, unique_id: str, name: str, command_topic: str,
                    availability_topic: str, device_class: str | None,
                    device: dict[str, Any]) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "uniq_id": unique_id,
        "name": name,
        "cmd_t": command_topic,
        "avty_t": availability_topic,
        "dev": device,
        "ent_cat": "config",
    }
    if device_class is not None:
        payload["dev_cla"] = device_class
    return payload


def _availability_topic_for(spec: SensorSpec, dtu_avail: str,
                            dtu_avail_persistent: str) -> str:
    """Map a sensor's stale_behavior to the correct availability topic."""
    if spec.stale_behavior == STALE_BEHAVIOR_UNAVAILABLE:
        return dtu_avail
    return dtu_avail_persistent


def _discovery_payload(*, unique_id: str, name: str, state_topic: str,
                       availability_topic: str, value_template: str,
                       spec: SensorSpec, device: dict[str, Any]) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "uniq_id": unique_id,
        "name": name,
        "stat_t": state_topic,
        "val_tpl": value_template,
        "avty_t": availability_topic,
        "dev": device,
    }
    if spec.unit is not None:
        payload["unit_of_meas"] = spec.unit
    if spec.device_class is not None:
        payload["dev_cla"] = spec.device_class
    if spec.state_class is not None:
        payload["stat_cla"] = spec.state_class
    if spec.icon is not None:
        payload["ic"] = spec.icon
    return payload


# --- Polling -----------------------------------------------------------------


@dataclasses.dataclass
class DtuRuntime:
    """Mutable per-DTU state we keep across polls."""

    endpoint: Endpoint
    dtu: DTU
    dtu_sn: str | None = None
    dtu_model: str | None = None
    dtu_sw: str | None = None
    signal_strength: int | None = None
    poll_count: int = 0
    # Set of (inverter_sn, port_number-or-None) pairs we've already emitted
    # HA-discovery messages for. None means "the inverter itself, not a port".
    # We re-publish discovery whenever a new pair appears so late-waking
    # inverters / ports get registered without a bridge restart.
    published_entities: set[tuple[str, int | None]] = dataclasses.field(default_factory=set)
    # Last per-inverter state dict (flat shape from build_state_payload's
    # second return value). Read cross-task by compute_installation_state, so
    # it MUST default to {} — sibling DTUs that haven't finished their first
    # poll yet would otherwise have no attribute to sum.
    last_known_inverters: dict[str, dict[str, Any]] = dataclasses.field(default_factory=dict)
    dtu_discovery_published: bool = False
    response_shape_logged: bool = False
    # Count of consecutive failed polls since the last success. Drives the
    # stale-mode transition when `endpoint.stale_mode` is enabled.
    consecutive_failures: int = 0
    # True while the DTU is in stale mode (failures >= threshold). Cleared on
    # the next successful poll.
    is_stale: bool = False
    # Set when a non-stale-mode DTU has already had its availability flipped
    # offline during the current outage. Prevents re-publishing the retained
    # offline message every poll while the DTU stays down.
    offline_published: bool = False
    # Per-(inverter_sn, port) running max of `energy_daily` within the current
    # local day. Populated only when `endpoint.hold_daily_energy` is set.
    held_daily_energy: dict[tuple[str, int], float] = dataclasses.field(default_factory=dict)
    # Local-date stamp (YYYY-MM-DD) pinning `held_daily_energy`. Crossing into
    # a new day clears the table and lets the DTU's fresh 0 flow through.
    held_day: str | None = None
    # True after a hold override has been applied at least once today. Used to
    # log the transition into the hold window once per day.
    hold_active_today: bool = False


async def refresh_encryption(rt: DtuRuntime) -> None:
    """Detect (or re-detect) encryption and rotate `enc_rand` if needed."""
    info = await rt.dtu.async_app_information_data()
    if info is None:
        # AppInfo failure is not fatal here — async_get_real_data_new will
        # also tell us if the DTU is offline. Just leave settings as-is.
        return
    rt.dtu_sn = info.dtu_serial_number
    rt.dtu_model = get_dtu_model_name(rt.dtu_sn)
    rt.dtu_sw = generate_dtu_version_string(info.dtu_info.dtu_sw_version)
    # signal_strength is reported as a positive integer on a vendor-specific
    # scale (typically 0-99 for WiFi, dBm-like for SIM). Pass through raw and
    # let HA graph it.
    rt.signal_strength = int(info.dtu_info.signal_strength)
    if info.dtu_info.dfs and is_encrypted_dtu(info.dtu_info.dfs):
        new_rand = info.dtu_info.enc_rand
        if not rt.dtu.is_encrypted or rt.dtu.enc_rand != new_rand:
            LOG.info("[%s] enabling encrypted comms (key rotated)", rt.endpoint.name)
            rt.dtu.is_encrypted = True
            rt.dtu.enc_rand = new_rand
    else:
        if rt.dtu.is_encrypted:
            LOG.info("[%s] DTU stopped reporting encryption", rt.endpoint.name)
        rt.dtu.is_encrypted = False
        rt.dtu.enc_rand = b""


def _scale(spec: SensorSpec, raw: int) -> float | int:
    if spec.factor == 1.0:
        return raw
    return round(raw * spec.factor, 4)


def build_state_payload(real: Any) -> tuple[dict[str, Any], dict[str, dict[str, Any]]]:
    """Return (dtu_state, {inverter_sn: inverter_state}).

    Each inverter_state is a flat JSON object with fields matching the keys in
    `INVERTER_SENSORS` plus `port_<n>_<key>` for each port from PORT_SENSORS.

    DTU totals are computed from per-port sums (more reliable than the DTU's
    own `dtu_power`/`dtu_daily_energy`, which the embedded DTU on HMS-W
    inverters leaves at zero).
    """
    inverters: dict[str, dict[str, Any]] = {}
    for sgs in real.sgs_data:
        sn = generate_inverter_serial_number(sgs.serial_number)
        inv_state: dict[str, Any] = {}
        for spec in INVERTER_SENSORS:
            inv_state[spec.key] = _scale(spec, getattr(sgs, spec.key))
        inv_state["firmware_version"] = generate_sw_version_string(sgs.firmware_version)
        inverters[sn] = inv_state

    # Attach port data to the parent inverter (matched by serial number).
    for pv in real.pv_data:
        parent_sn = generate_inverter_serial_number(pv.serial_number)
        if parent_sn not in inverters:
            # Port without a corresponding inverter row — keep it under a
            # synthetic entry so we don't drop data.
            inverters[parent_sn] = {}
        port = pv.port_number
        for spec in PORT_SENSORS:
            inverters[parent_sn][f"port_{port}_{spec.key}"] = _scale(
                spec, getattr(pv, spec.key)
            )

    dtu_state = _compute_dtu_totals(real, inverters)
    return dtu_state, inverters


def _sum_port_field(inverters: dict[str, dict[str, Any]], suffix: str) -> float:
    total = 0.0
    for inv in inverters.values():
        for k, v in inv.items():
            if k.startswith("port_") and k.endswith(f"_{suffix}"):
                total += float(v)
    return total


def _dtu_totals_from_ports(inverters: dict[str, dict[str, Any]]) -> dict[str, Any]:
    # Ports already publish kWh (factor 0.001); sum preserves that unit.
    # 3-decimal rounding keeps ~1 Wh resolution and avoids drift-induced
    # TOTAL_INCREASING resets in HA.
    return {
        "dtu_power": round(_sum_port_field(inverters, "power"), 2),
        "dtu_daily_energy": round(_sum_port_field(inverters, "energy_daily"), 3),
        "dtu_total_energy": round(_sum_port_field(inverters, "energy_total"), 3),
    }


def _compute_dtu_totals(real: Any, inverters: dict[str, dict[str, Any]]
                        ) -> dict[str, Any]:
    """Compute DTU-level aggregates from port sums, with DTU-reported values
    as fallback when no port data is available."""
    has_ports = any(
        any(k.startswith("port_") for k in inv) for inv in inverters.values()
    )
    if has_ports:
        return _dtu_totals_from_ports(inverters)
    # Fallback: trust the DTU. dtu_power is scaled (factor 0.1), energies
    # are raw Wh from protobuf — divide by 1000 to match our kWh unit.
    return {
        "dtu_power": round(real.dtu_power * 0.1, 2),
        "dtu_daily_energy": round(real.dtu_daily_energy / 1000.0, 3),
        "dtu_total_energy": 0,
    }


# Classification tables for stale-mode projection: {sensor_key: behavior}.
_INVERTER_STALE_BEHAVIOR = {s.key: s.stale_behavior for s in INVERTER_SENSORS}
_PORT_STALE_BEHAVIOR = {s.key: s.stale_behavior for s in PORT_SENSORS}


def _apply_daily_energy_hold(rt: DtuRuntime,
                             inverters: dict[str, dict[str, Any]]) -> None:
    """Clamp per-port `energy_daily` to its running per-day max.

    The DTU-WLite-S stick reports accurate daily energy during daylight but
    zeroes the counter after sundown while staying online. HA's
    total_increasing state_class treats that drop as a counter reset, losing
    the day's accumulated total. We pin each port's published value to the
    max we've seen since local midnight; at day rollover the table clears and
    the DTU's fresh 0 is accepted as the start of a new day.
    """
    today = datetime.date.today().isoformat()
    if rt.held_day != today:
        rt.held_day = today
        rt.held_daily_energy.clear()
        rt.hold_active_today = False

    override_this_poll = False
    for inv_sn, inv_state in inverters.items():
        for key, value in list(inv_state.items()):
            if not (key.startswith("port_") and key.endswith("_energy_daily")):
                continue
            # Port key format is `port_<n>_energy_daily`.
            port_num = int(key.split("_")[1])
            slot = (inv_sn, port_num)
            current = float(value)
            held = rt.held_daily_energy.get(slot)
            if held is None or current >= held:
                rt.held_daily_energy[slot] = current
            else:
                inv_state[key] = held
                override_this_poll = True

    if override_this_poll and not rt.hold_active_today:
        rt.hold_active_today = True
        LOG.info("[%s] daily-energy hold engaged for %s (DTU reset detected)",
                 rt.endpoint.name, today)


def _staleify_inverter_state(state: dict[str, Any]) -> dict[str, Any]:
    """Project the last-known inverter state to the "stale" form.

    `zero`-behavior fields become 0; `preserve`-behavior fields keep their
    last-known value; `unavailable`-behavior fields are kept as-is in the JSON
    (HA hides them via the offline availability topic).
    """
    out: dict[str, Any] = {}
    for key, value in state.items():
        if key.startswith("port_"):
            # port_<n>_<sensor_key>
            _, _, sensor_key = key.partition("_")
            _, _, sensor_key = sensor_key.partition("_")
            behavior = _PORT_STALE_BEHAVIOR.get(sensor_key)
        else:
            behavior = _INVERTER_STALE_BEHAVIOR.get(key)
        if behavior == STALE_BEHAVIOR_ZERO:
            out[key] = 0
        else:
            out[key] = value
    return out


def compute_installation_state(runtimes: list["DtuRuntime"]) -> dict[str, Any]:
    """Sum power/energy across every DTU's last-known per-port data.

    We use last-known (rather than current-only) so a transient DTU dropout
    doesn't make the total dip — important because daily/lifetime energies are
    declared TOTAL_INCREASING and HA treats a drop as a counter reset.
    """
    current_power = 0.0
    daily_energy = 0.0
    total_energy = 0.0
    for rt in runtimes:
        current_power += _sum_port_field(rt.last_known_inverters, "power")
        daily_energy += _sum_port_field(rt.last_known_inverters, "energy_daily")
        total_energy += _sum_port_field(rt.last_known_inverters, "energy_total")
    return {
        "current_power": round(current_power, 2),
        "daily_energy": round(daily_energy, 3),
        "total_energy": round(total_energy, 3),
    }


def discovery_messages(rt: DtuRuntime, inverters: dict[str, dict[str, Any]],
                       discovery_prefix: str, base_topic: str
                       ) -> dict[tuple[str, int | None], list[tuple[str, dict[str, Any]]]]:
    """Group HA-discovery messages by entity key (inverter_sn, port-or-None).

    The DTU itself is keyed under (rt.dtu_sn, -1) so it's distinct from any
    inverter+port pair (port numbers from the DTU are >=1).
    """
    assert rt.dtu_sn is not None, "discovery requires DTU SN"
    dtu_avail = f"{base_topic}/{rt.dtu_sn}/availability"
    dtu_avail_persistent = f"{base_topic}/{rt.dtu_sn}/availability_persistent"
    dtu_state_topic = f"{base_topic}/{rt.dtu_sn}/state"
    dtu_dev = _device_block(
        identifiers=f"hoymiles_dtu_{rt.dtu_sn}",
        name=f"Hoymiles DTU {rt.endpoint.name} ({rt.dtu_sn})",
        model=rt.dtu_model,
        sw_version=rt.dtu_sw,
    )

    grouped: dict[tuple[str, int | None], list[tuple[str, dict[str, Any]]]] = {}

    dtu_msgs: list[tuple[str, dict[str, Any]]] = []
    for spec in DTU_SENSORS:
        uid = f"hoymiles_{rt.dtu_sn}_{spec.key}"
        topic = f"{discovery_prefix}/sensor/{uid}/config"
        dtu_msgs.append((topic, _discovery_payload(
            unique_id=uid,
            name=spec.name,
            state_topic=dtu_state_topic,
            availability_topic=_availability_topic_for(spec, dtu_avail, dtu_avail_persistent),
            value_template=f"{{{{ value_json.{spec.key} }}}}",
            spec=spec,
            device=dtu_dev,
        )))
    # DTU restart button. `cmd_t` is per-DTU so the bridge can route to the
    # right runtime without parsing argv.
    restart_topic = f"{base_topic}/{rt.dtu_sn}/command/restart"
    restart_uid = f"hoymiles_{rt.dtu_sn}_restart"
    dtu_msgs.append((
        f"{discovery_prefix}/button/{restart_uid}/config",
        _button_payload(
            unique_id=restart_uid,
            name="Restart DTU",
            command_topic=restart_topic,
            availability_topic=dtu_avail,
            device_class="restart",
            device=dtu_dev,
        ),
    ))
    grouped[(rt.dtu_sn, -1)] = dtu_msgs

    for inv_sn, inv_state in inverters.items():
        inv_dev = _device_block(
            identifiers=f"hoymiles_inv_{inv_sn}",
            name=f"Hoymiles Inverter {inv_sn}",
            model=get_inverter_model_name(inv_sn) or None,
            sw_version=inv_state.get("firmware_version"),
            via_device=f"hoymiles_dtu_{rt.dtu_sn}",
        )
        inv_state_topic = f"{base_topic}/{rt.dtu_sn}/inverter/{inv_sn}/state"
        inv_msgs: list[tuple[str, dict[str, Any]]] = []

        for spec in INVERTER_SENSORS:
            uid = f"hoymiles_{inv_sn}_{spec.key}"
            topic = f"{discovery_prefix}/sensor/{uid}/config"
            inv_msgs.append((topic, _discovery_payload(
                unique_id=uid,
                name=spec.name,
                state_topic=inv_state_topic,
                availability_topic=_availability_topic_for(spec, dtu_avail, dtu_avail_persistent),
                value_template=f"{{{{ value_json.{spec.key} }}}}",
                spec=spec,
                device=inv_dev,
            )))
        # Binary derivative of link_status. We deliberately do NOT expose a
        # "problem" binary based on `warning_number` — empirically it's a
        # cumulative warning counter, not a currently-active-problem flag, so
        # once the inverter ever hiccups the sensor sticks ON forever.
        # Upstream ha-hoymiles-wifi exposes warning_number as a plain numeric
        # sensor for the same reason.
        link_uid = f"hoymiles_{inv_sn}_connected"
        inv_msgs.append((
            f"{discovery_prefix}/binary_sensor/{link_uid}/config",
            _binary_sensor_payload(
                unique_id=link_uid,
                name="Connected",
                state_topic=inv_state_topic,
                availability_topic=dtu_avail,
                value_template=("{{ 'ON' if (value_json.link_status | int(0)) "
                                "> 0 else 'OFF' }}"),
                device_class="connectivity",
                device=inv_dev,
                diagnostic=True,
            ),
        ))
        # Stale indicator. Uses the persistent availability topic so it can
        # report "ON" (stale) while the DTU is unreachable — the whole point.
        stale_uid = f"hoymiles_{inv_sn}_stale"
        inv_msgs.append((
            f"{discovery_prefix}/binary_sensor/{stale_uid}/config",
            _binary_sensor_payload(
                unique_id=stale_uid,
                name="Stale",
                state_topic=inv_state_topic,
                availability_topic=dtu_avail_persistent,
                value_template="{{ 'ON' if value_json.stale else 'OFF' }}",
                device_class="problem",
                device=inv_dev,
                diagnostic=True,
            ),
        ))
        grouped[(inv_sn, None)] = inv_msgs

        # Port sensors: one device per port keeps the HA UI clean and lets
        # users disable individual ports if they're not populated.
        ports = sorted({int(k.split("_")[1]) for k in inv_state if k.startswith("port_")})
        for port in ports:
            port_dev = _device_block(
                identifiers=f"hoymiles_inv_{inv_sn}_port_{port}",
                name=f"Hoymiles Inverter {inv_sn} Port {port}",
                model=None,
                sw_version=None,
                via_device=f"hoymiles_inv_{inv_sn}",
            )
            port_msgs: list[tuple[str, dict[str, Any]]] = []
            for spec in PORT_SENSORS:
                field = f"port_{port}_{spec.key}"
                if field not in inv_state:
                    continue
                uid = f"hoymiles_{inv_sn}_port_{port}_{spec.key}"
                topic = f"{discovery_prefix}/sensor/{uid}/config"
                port_msgs.append((topic, _discovery_payload(
                    unique_id=uid,
                    name=spec.name,
                    state_topic=inv_state_topic,
                    availability_topic=_availability_topic_for(spec, dtu_avail, dtu_avail_persistent),
                    value_template=f"{{{{ value_json.{field} }}}}",
                    spec=spec,
                    device=port_dev,
                )))
            grouped[(inv_sn, port)] = port_msgs

    return grouped


# --- DTU task ----------------------------------------------------------------


def installation_discovery_messages(*, base_topic: str, discovery_prefix: str
                                    ) -> list[tuple[str, dict[str, Any]]]:
    state_topic = f"{base_topic}/installation/state"
    avail_topic = f"{base_topic}/bridge/availability"
    device = _device_block(
        identifiers=INSTALLATION_DEVICE_ID,
        name="Hoymiles Installation",
        model=None,
        sw_version=None,
    )
    out: list[tuple[str, dict[str, Any]]] = []
    for spec in INSTALLATION_SENSORS:
        uid = f"{INSTALLATION_DEVICE_ID}_{spec.key}"
        out.append((
            f"{discovery_prefix}/sensor/{uid}/config",
            _discovery_payload(
                unique_id=uid,
                name=spec.name,
                state_topic=state_topic,
                availability_topic=avail_topic,
                value_template=f"{{{{ value_json.{spec.key} }}}}",
                spec=spec,
                device=device,
            ),
        ))
    return out


async def dispatch_commands(client: aiomqtt.Client, runtimes: list[DtuRuntime],
                            *, base_topic: str) -> None:
    """Subscribe to `<base>/+/command/+` and dispatch supported commands."""
    topic_filter = f"{base_topic}/+/command/+"
    await client.subscribe(topic_filter)
    LOG.info("subscribed to command topic %s", topic_filter)

    async for msg in client.messages:
        topic = str(msg.topic)
        # hoymiles/<dtu_sn>/command/<action>
        parts = topic.split("/")
        if len(parts) != 4 or parts[0] != base_topic or parts[2] != "command":
            LOG.warning("ignoring unexpected command topic: %s", topic)
            continue
        dtu_sn, action = parts[1], parts[3]
        rt = next((r for r in runtimes if r.dtu_sn == dtu_sn), None)
        if rt is None:
            LOG.warning("command for unknown DTU %s", dtu_sn)
            continue
        try:
            if action == "restart":
                LOG.info("[%s] restart-DTU command received", rt.endpoint.name)
                await rt.dtu.async_restart_dtu()
            else:
                LOG.warning("[%s] unknown action %r", rt.endpoint.name, action)
        except Exception:
            LOG.exception("[%s] command %r failed", rt.endpoint.name, action)


async def publish(client: aiomqtt.Client, topic: str, payload: Any, *, retain: bool = False) -> None:
    if isinstance(payload, (dict, list)):
        body = json.dumps(payload, separators=(",", ":"))
    else:
        body = str(payload)
    await client.publish(topic, body, retain=retain)


async def poll_dtu(rt: DtuRuntime, client: aiomqtt.Client, *,
                   all_runtimes: list[DtuRuntime],
                   installation_lock: asyncio.Lock,
                   discovery_prefix: str, base_topic: str,
                   interval: float, stale_threshold: int) -> None:
    """Long-running per-DTU polling loop."""
    while True:
        try:
            if rt.poll_count % ENCRYPTION_RECHECK_EVERY == 0:
                await refresh_encryption(rt)

            real = await rt.dtu.async_get_real_data_new()
            rt.poll_count += 1

            if real is None:
                rt.consecutive_failures += 1
                await _handle_failed_poll(
                    rt, client, base_topic=base_topic,
                    all_runtimes=all_runtimes,
                    installation_lock=installation_lock,
                    stale_threshold=stale_threshold,
                )
                await asyncio.sleep(interval)
                continue

            rt.consecutive_failures = 0

            if rt.dtu_sn is None:
                # Fall back to the SN the data carries; refresh_encryption
                # would normally set it. device_serial_number is already a
                # string in the protobuf schema.
                rt.dtu_sn = real.device_serial_number

            if not rt.response_shape_logged:
                LOG.info(
                    "[%s] first response: sgs=%d tgs=%d pv=%d meter=%d rsd=%d "
                    "dtu_power=%d dtu_daily_energy=%d",
                    rt.endpoint.name,
                    len(real.sgs_data), len(real.tgs_data), len(real.pv_data),
                    len(real.meter_data), len(real.rsd_data),
                    real.dtu_power, real.dtu_daily_energy,
                )
                rt.response_shape_logged = True

            dtu_state, inverters = build_state_payload(real)
            if rt.endpoint.hold_daily_energy:
                _apply_daily_energy_hold(rt, inverters)
                # Recompute DTU totals from the (possibly-corrected) port
                # sums so dtu_daily_energy and the installation aggregate
                # follow the same held value.
                has_ports = any(
                    any(k.startswith("port_") for k in inv)
                    for inv in inverters.values()
                )
                if has_ports:
                    dtu_state.update(_dtu_totals_from_ports(inverters))
            dtu_state["stale"] = False
            for inv_state in inverters.values():
                inv_state["stale"] = False
            if rt.signal_strength is not None:
                dtu_state["signal_strength"] = rt.signal_strength

            grouped = discovery_messages(
                rt, inverters, discovery_prefix, base_topic
            )
            new_keys = [k for k in grouped if k not in rt.published_entities]
            for key in new_keys:
                for topic, payload in grouped[key]:
                    await publish(client, topic, payload, retain=True)
                rt.published_entities.add(key)
            if new_keys:
                LOG.info("[%s] published discovery for %d new entity-group(s) "
                         "(DTU=%s, total inverters=%d)",
                         rt.endpoint.name, len(new_keys), rt.dtu_sn, len(inverters))

            await publish(client, f"{base_topic}/{rt.dtu_sn}/availability",
                          "online", retain=True)
            await publish(client, f"{base_topic}/{rt.dtu_sn}/availability_persistent",
                          "online", retain=True)
            if rt.is_stale:
                LOG.info("[%s] DTU recovered from stale mode", rt.endpoint.name)
                rt.is_stale = False
            rt.offline_published = False

            await publish(client, f"{base_topic}/{rt.dtu_sn}/state", dtu_state, retain=True)
            for inv_sn, inv_state in inverters.items():
                await publish(
                    client,
                    f"{base_topic}/{rt.dtu_sn}/inverter/{inv_sn}/state",
                    inv_state, retain=True,
                )
            rt.last_known_inverters = inverters

            # Cross-DTU aggregation. Lock so two DTU tasks don't race on the
            # publish — the read of last_known_inverters from sibling tasks is
            # otherwise lock-free (single-line dict assignment above).
            async with installation_lock:
                inst_state = compute_installation_state(all_runtimes)
                await publish(client, f"{base_topic}/installation/state",
                              inst_state, retain=True)

        except aiomqtt.MqttError:
            # Bubble up so the outer reconnect loop reconnects MQTT.
            raise
        except asyncio.CancelledError:
            raise
        except Exception:
            LOG.exception("[%s] poll iteration failed", rt.endpoint.name)

        await asyncio.sleep(interval)


async def _handle_failed_poll(rt: DtuRuntime, client: aiomqtt.Client, *,
                              base_topic: str,
                              all_runtimes: list[DtuRuntime],
                              installation_lock: asyncio.Lock,
                              stale_threshold: int) -> None:
    """One failed poll. Decide between hard-offline and stale-mode behavior."""
    LOG.warning("[%s] no data (DTU offline?); consecutive failures=%d",
                rt.endpoint.name, rt.consecutive_failures)
    if rt.dtu_sn is None:
        # We've never seen a successful poll for this DTU; no SN means no
        # state/availability topics to publish to.
        return

    if rt.endpoint.stale_mode:
        if rt.consecutive_failures >= stale_threshold and not rt.is_stale:
            await _enter_stale_mode(
                rt, client, base_topic=base_topic,
                all_runtimes=all_runtimes,
                installation_lock=installation_lock,
            )
        # Below threshold or already stale: do nothing. Retained MQTT messages
        # keep HA on the last state; stale binary_sensor reflects reality.
        return

    # Non-stale DTU: current behavior — both availabilities flip offline on
    # the first failure of an outage. Subsequent failures short-circuit.
    if rt.offline_published:
        return
    await publish(client, f"{base_topic}/{rt.dtu_sn}/availability",
                  "offline", retain=True)
    await publish(client, f"{base_topic}/{rt.dtu_sn}/availability_persistent",
                  "offline", retain=True)
    rt.offline_published = True


async def _enter_stale_mode(rt: DtuRuntime, client: aiomqtt.Client, *,
                            base_topic: str,
                            all_runtimes: list[DtuRuntime],
                            installation_lock: asyncio.Lock) -> None:
    """Transition this DTU's entities into stale mode.

    Instantaneous fields (active_power, port power, dtu_power) are zeroed;
    energies are kept at their last-known values; everything else is hidden by
    flipping the primary availability topic to offline while the persistent
    availability topic stays online.
    """
    assert rt.dtu_sn is not None
    LOG.warning("[%s] entering stale mode after %d failed polls",
                rt.endpoint.name, rt.consecutive_failures)
    rt.is_stale = True

    stale_inverters = {
        sn: _staleify_inverter_state(state)
        for sn, state in rt.last_known_inverters.items()
    }
    for inv_state in stale_inverters.values():
        inv_state["stale"] = True

    stale_dtu_state: dict[str, Any] = _dtu_totals_from_ports(stale_inverters)
    if rt.signal_strength is not None:
        stale_dtu_state["signal_strength"] = rt.signal_strength
    stale_dtu_state["stale"] = True

    await publish(client, f"{base_topic}/{rt.dtu_sn}/availability",
                  "offline", retain=True)
    await publish(client, f"{base_topic}/{rt.dtu_sn}/availability_persistent",
                  "online", retain=True)

    await publish(client, f"{base_topic}/{rt.dtu_sn}/state",
                  stale_dtu_state, retain=True)
    for inv_sn, inv_state in stale_inverters.items():
        await publish(
            client,
            f"{base_topic}/{rt.dtu_sn}/inverter/{inv_sn}/state",
            inv_state, retain=True,
        )
    # Update our last-known so cross-DTU aggregation uses the stale projection
    # (zero power, preserved energies).
    rt.last_known_inverters = stale_inverters

    async with installation_lock:
        inst_state = compute_installation_state(all_runtimes)
        await publish(client, f"{base_topic}/installation/state",
                      inst_state, retain=True)


# --- Top-level orchestration -------------------------------------------------


async def run() -> None:
    parser = argparse.ArgumentParser(description="Hoymiles → MQTT bridge")
    parser.add_argument("--log-level", default=env("LOG_LEVEL", "INFO"))
    args = parser.parse_args()
    setup_logging(args.log_level)

    stale_names = parse_name_list(env("HOYMILES_STALE_ENDPOINTS"))
    hold_daily_names = parse_name_list(env("HOYMILES_HOLD_DAILY_ENERGY_ENDPOINTS"))
    stale_threshold = int(env("HOYMILES_STALE_THRESHOLD", "3"))
    if stale_threshold < 1:
        sys.exit("HOYMILES_STALE_THRESHOLD must be >= 1")
    endpoints = parse_endpoints(env("HOYMILES_ENDPOINTS", required=True),
                                stale_names, hold_daily_names)
    poll_interval = float(env("HOYMILES_POLL_INTERVAL", "30"))
    base_topic = env("MQTT_BASE_TOPIC", "hoymiles")
    discovery_prefix = env("HA_DISCOVERY_PREFIX", "homeassistant")
    mqtt_host = env("MQTT_HOST", required=True)
    mqtt_port = int(env("MQTT_PORT", "1883"))
    mqtt_user = env("MQTT_USER")
    mqtt_password = env("MQTT_PASSWORD")
    client_id = env("MQTT_CLIENT_ID", "hoymiles-mqtt-bridge")

    runtimes = [
        DtuRuntime(endpoint=ep, dtu=DTU(host=ep.host))
        for ep in endpoints
    ]

    LOG.info("starting bridge: %d endpoint(s), broker=%s:%d, interval=%.1fs",
             len(endpoints), mqtt_host, mqtt_port, poll_interval)

    # Outer reconnect loop. aiomqtt raises MqttError on broker disconnect; we
    # back off, reconnect, and re-publish discovery (because retained messages
    # may have been wiped from the broker, and HA may have restarted).
    backoff = 1.0
    while True:
        try:
            async with aiomqtt.Client(
                hostname=mqtt_host,
                port=mqtt_port,
                username=mqtt_user,
                password=mqtt_password,
                identifier=client_id,
                will=aiomqtt.Will(
                    topic=f"{base_topic}/bridge/availability",
                    payload="offline",
                    retain=True,
                ),
            ) as client:
                await publish(client, f"{base_topic}/bridge/availability",
                              "online", retain=True)

                # Installation discovery is independent of any single DTU.
                for topic, payload in installation_discovery_messages(
                    base_topic=base_topic, discovery_prefix=discovery_prefix,
                ):
                    await publish(client, topic, payload, retain=True)

                # Force discovery republish on each broker reconnect. Also
                # clear stale/offline latches so availability topics get
                # republished with their correct current value on the next
                # poll cycle (retained messages on the broker may have been
                # wiped).
                for rt in runtimes:
                    rt.published_entities.clear()
                    rt.is_stale = False
                    rt.offline_published = False

                installation_lock = asyncio.Lock()
                async with asyncio.TaskGroup() as tg:
                    tg.create_task(dispatch_commands(
                        client, runtimes, base_topic=base_topic,
                    ))
                    for rt in runtimes:
                        tg.create_task(poll_dtu(
                            rt, client,
                            all_runtimes=runtimes,
                            installation_lock=installation_lock,
                            discovery_prefix=discovery_prefix,
                            base_topic=base_topic,
                            interval=poll_interval,
                            stale_threshold=stale_threshold,
                        ))
            backoff = 1.0
        except* aiomqtt.MqttError as eg:
            for exc in eg.exceptions:
                LOG.warning("MQTT connection lost: %s; reconnecting in %.1fs", exc, backoff)
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 60.0)


def main() -> None:
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)

    task = loop.create_task(run())

    def _shutdown() -> None:
        # Cancelling the top-level task propagates through the aiomqtt context
        # manager and TaskGroup so child poll tasks exit cleanly.
        if not task.done():
            task.cancel()

    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, _shutdown)

    try:
        loop.run_until_complete(task)
    except (KeyboardInterrupt, asyncio.CancelledError):
        pass
    finally:
        loop.close()


if __name__ == "__main__":
    main()
