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

LOG = logging.getLogger("hoymiles_mqtt_bridge")

# Re-detect DTU encryption parameters every N polls. The rolling `enc_rand` is
# stable across short windows but can rotate; if we keep using a stale value
# the DTU silently returns junk decryption.
ENCRYPTION_RECHECK_EVERY = 30


@dataclasses.dataclass(frozen=True)
class Endpoint:
    name: str
    host: str


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


# Per-inverter (single-phase grid section). HMS-800W-2T and HMS-2000-4T both
# present sgs_data, not tgs_data — they are single-phase microinverters.
INVERTER_SENSORS: tuple[SensorSpec, ...] = (
    SensorSpec("active_power", "Active Power", "W", "power", "measurement", 0.1),
    SensorSpec("reactive_power", "Reactive Power", "var", "reactive_power", "measurement", 0.1),
    SensorSpec("voltage", "Grid Voltage", "V", "voltage", "measurement", 0.1),
    SensorSpec("current", "Grid Current", "A", "current", "measurement", 0.01),
    SensorSpec("frequency", "Grid Frequency", "Hz", "frequency", "measurement", 0.01),
    SensorSpec("power_factor", "Power Factor", None, "power_factor", "measurement", 0.1),
    SensorSpec("temperature", "Temperature", "°C", "temperature", "measurement", 0.1),
    SensorSpec("warning_number", "Warning Count", None, None, "measurement"),
    SensorSpec("link_status", "Link Status", None, None, "measurement"),
)

# Per-PV-port (DC side).
PORT_SENSORS: tuple[SensorSpec, ...] = (
    SensorSpec("voltage", "DC Voltage", "V", "voltage", "measurement", 0.1),
    SensorSpec("current", "DC Current", "A", "current", "measurement", 0.01),
    SensorSpec("power", "DC Power", "W", "power", "measurement", 0.1),
    SensorSpec("energy_total", "Total Energy", "Wh", "energy", "total_increasing"),
    SensorSpec("energy_daily", "Daily Energy", "Wh", "energy", "total_increasing"),
    SensorSpec("error_code", "Error Code", None, None, "measurement"),
)

# DTU-aggregate sensors.
DTU_SENSORS: tuple[SensorSpec, ...] = (
    SensorSpec("dtu_power", "Total Power", "W", "power", "measurement", 0.1),
    SensorSpec("dtu_daily_energy", "Total Daily Energy", "Wh", "energy", "total_increasing"),
)


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


def parse_endpoints(spec: str) -> list[Endpoint]:
    """`HOYMILES_ENDPOINTS` is `name=host[,name=host...]`."""
    out: list[Endpoint] = []
    for entry in spec.split(","):
        entry = entry.strip()
        if not entry:
            continue
        if "=" not in entry:
            sys.exit(f"invalid endpoint spec {entry!r}: expected name=host")
        name, host = entry.split("=", 1)
        out.append(Endpoint(name=name.strip(), host=host.strip()))
    if not out:
        sys.exit("HOYMILES_ENDPOINTS produced no endpoints")
    return out


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
    poll_count: int = 0
    discovery_published: bool = False
    last_known_inverters: dict[str, dict[str, Any]] = dataclasses.field(default_factory=dict)


async def refresh_encryption(rt: DtuRuntime) -> None:
    """Detect (or re-detect) encryption and rotate `enc_rand` if needed."""
    info = await rt.dtu.async_app_information_data()
    if info is None:
        # AppInfo failure is not fatal here — async_get_real_data_new will
        # also tell us if the DTU is offline. Just leave settings as-is.
        return
    rt.dtu_sn = generate_inverter_serial_number(info.dtu_info.dtu_sn)
    rt.dtu_model = get_dtu_model_name(info.dtu_info.dtu_hw_version)
    rt.dtu_sw = generate_dtu_version_string(info.dtu_info.dtu_sw_version)
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
    """
    dtu_state = {
        "dtu_power": _scale(DTU_SENSORS[0], real.dtu_power),
        "dtu_daily_energy": _scale(DTU_SENSORS[1], real.dtu_daily_energy),
    }
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

    return dtu_state, inverters


def discovery_messages(rt: DtuRuntime, inverters: dict[str, dict[str, Any]],
                       discovery_prefix: str, base_topic: str) -> list[tuple[str, dict[str, Any]]]:
    """Produce all HA-discovery topic/payload pairs for this DTU + inverters."""
    assert rt.dtu_sn is not None, "discovery requires DTU SN"
    dtu_avail = f"{base_topic}/{rt.dtu_sn}/availability"
    dtu_state_topic = f"{base_topic}/{rt.dtu_sn}/state"
    dtu_dev = _device_block(
        identifiers=f"hoymiles_dtu_{rt.dtu_sn}",
        name=f"Hoymiles DTU {rt.endpoint.name} ({rt.dtu_sn})",
        model=rt.dtu_model,
        sw_version=rt.dtu_sw,
    )

    out: list[tuple[str, dict[str, Any]]] = []
    for spec in DTU_SENSORS:
        uid = f"hoymiles_{rt.dtu_sn}_{spec.key}"
        topic = f"{discovery_prefix}/sensor/{uid}/config"
        out.append((topic, _discovery_payload(
            unique_id=uid,
            name=spec.name,
            state_topic=dtu_state_topic,
            availability_topic=dtu_avail,
            value_template=f"{{{{ value_json.{spec.key} }}}}",
            spec=spec,
            device=dtu_dev,
        )))

    for inv_sn, inv_state in inverters.items():
        inv_dev = _device_block(
            identifiers=f"hoymiles_inv_{inv_sn}",
            name=f"Hoymiles Inverter {inv_sn}",
            model=None,
            sw_version=inv_state.get("firmware_version"),
            via_device=f"hoymiles_dtu_{rt.dtu_sn}",
        )
        inv_state_topic = f"{base_topic}/{rt.dtu_sn}/inverter/{inv_sn}/state"

        for spec in INVERTER_SENSORS:
            uid = f"hoymiles_{inv_sn}_{spec.key}"
            topic = f"{discovery_prefix}/sensor/{uid}/config"
            out.append((topic, _discovery_payload(
                unique_id=uid,
                name=spec.name,
                state_topic=inv_state_topic,
                availability_topic=dtu_avail,
                value_template=f"{{{{ value_json.{spec.key} }}}}",
                spec=spec,
                device=inv_dev,
            )))

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
            for spec in PORT_SENSORS:
                field = f"port_{port}_{spec.key}"
                if field not in inv_state:
                    continue
                uid = f"hoymiles_{inv_sn}_port_{port}_{spec.key}"
                topic = f"{discovery_prefix}/sensor/{uid}/config"
                out.append((topic, _discovery_payload(
                    unique_id=uid,
                    name=spec.name,
                    state_topic=inv_state_topic,
                    availability_topic=dtu_avail,
                    value_template=f"{{{{ value_json.{field} }}}}",
                    spec=spec,
                    device=port_dev,
                )))

    return out


# --- DTU task ----------------------------------------------------------------


async def publish(client: aiomqtt.Client, topic: str, payload: Any, *, retain: bool = False) -> None:
    if isinstance(payload, (dict, list)):
        body = json.dumps(payload, separators=(",", ":"))
    else:
        body = str(payload)
    await client.publish(topic, body, retain=retain)


async def poll_dtu(rt: DtuRuntime, client: aiomqtt.Client, *,
                   discovery_prefix: str, base_topic: str,
                   interval: float) -> None:
    """Long-running per-DTU polling loop."""
    dtu_offline_published = False

    while True:
        try:
            if rt.poll_count % ENCRYPTION_RECHECK_EVERY == 0:
                await refresh_encryption(rt)

            real = await rt.dtu.async_get_real_data_new()
            rt.poll_count += 1

            if real is None:
                if not dtu_offline_published and rt.dtu_sn:
                    await publish(client, f"{base_topic}/{rt.dtu_sn}/availability",
                                  "offline", retain=True)
                    dtu_offline_published = True
                LOG.warning("[%s] no data (DTU offline?)", rt.endpoint.name)
                await asyncio.sleep(interval)
                continue

            if rt.dtu_sn is None:
                # Fall back to the SN the data carries; refresh_encryption
                # would normally set it.
                rt.dtu_sn = generate_inverter_serial_number(real.device_serial_number)

            dtu_state, inverters = build_state_payload(real)

            if not rt.discovery_published:
                for topic, payload in discovery_messages(
                    rt, inverters, discovery_prefix, base_topic
                ):
                    await publish(client, topic, payload, retain=True)
                rt.discovery_published = True
                LOG.info("[%s] published discovery for DTU=%s, %d inverter(s)",
                         rt.endpoint.name, rt.dtu_sn, len(inverters))

            await publish(client, f"{base_topic}/{rt.dtu_sn}/availability",
                          "online", retain=True)
            dtu_offline_published = False

            await publish(client, f"{base_topic}/{rt.dtu_sn}/state", dtu_state, retain=True)
            for inv_sn, inv_state in inverters.items():
                await publish(
                    client,
                    f"{base_topic}/{rt.dtu_sn}/inverter/{inv_sn}/state",
                    inv_state, retain=True,
                )
            rt.last_known_inverters = inverters

        except aiomqtt.MqttError:
            # Bubble up so the outer reconnect loop reconnects MQTT.
            raise
        except asyncio.CancelledError:
            raise
        except Exception:
            LOG.exception("[%s] poll iteration failed", rt.endpoint.name)

        await asyncio.sleep(interval)


# --- Top-level orchestration -------------------------------------------------


async def run() -> None:
    parser = argparse.ArgumentParser(description="Hoymiles → MQTT bridge")
    parser.add_argument("--log-level", default=env("LOG_LEVEL", "INFO"))
    args = parser.parse_args()
    setup_logging(args.log_level)

    endpoints = parse_endpoints(env("HOYMILES_ENDPOINTS", required=True))
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

                # Force discovery republish on each broker reconnect.
                for rt in runtimes:
                    rt.discovery_published = False

                async with asyncio.TaskGroup() as tg:
                    for rt in runtimes:
                        tg.create_task(poll_dtu(
                            rt, client,
                            discovery_prefix=discovery_prefix,
                            base_topic=base_topic,
                            interval=poll_interval,
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
    stop = loop.create_future()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, lambda: stop.cancel() if not stop.done() else None)

    task = loop.create_task(run())
    try:
        loop.run_until_complete(task)
    except (KeyboardInterrupt, asyncio.CancelledError):
        pass
    finally:
        task.cancel()
        loop.run_until_complete(asyncio.gather(task, return_exceptions=True))
        loop.close()


if __name__ == "__main__":
    main()
