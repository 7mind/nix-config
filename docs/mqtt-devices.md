# Supported MQTT Devices

All devices are managed by the `mqtt-controller` and provisioned via zigbee2mqtt or Z-Wave JS UI.

## Zigbee Devices

### Lights

Philips Hue bulbs. Generic `light` kind — the controller treats all Hue bulbs uniformly (scene-based brightness/color control via zigbee2mqtt groups).

| Prefix | Manufacturer | Protocol |
|--------|-------------|----------|
| `hue-l-` | Philips / Signify | Zigbee |

### Wall Switches (Hue Dimmer)

4-button wall-mount remote. Exposes `on_press_release`, `off_press_release`, `up_press_release`, `down_press_release` actions. Used for room scene cycling (on/off + brightness up/down).

| Prefix | Model | zigbee2mqtt docs |
|--------|-------|-----------------|
| `hue-s-` | Philips RWL022 | [RWL022](https://www.zigbee2mqtt.io/devices/RWL022.html) |

### Tap Switches

#### Hue Tap (energy-harvesting, ZGPSWITCH)

4-button battery-free tap switch. Each button can bind to a different room. Sends `press_1` .. `press_4` actions.

| Prefix | Model | zigbee2mqtt docs |
|--------|-------|-----------------|
| `hue-ts-` | Philips 8718696743133 (ZGPSWITCH) | [8718696743133](https://www.zigbee2mqtt.io/devices/8718696743133.html) |

#### Sonoff Wireless Switch (4-button)

4-button Zigbee wireless switch. Sends `single_button_N` and `double_button_N` actions (N=1..4). Referred to as "orb switch" in the codebase.

| Prefix | Manufacturer | zigbee2mqtt docs |
|--------|-------------|-----------------|
| `sonoff-ts-` | Sonoff | [Sonoff supported devices](https://www.zigbee2mqtt.io/supported-devices/#v=Sonoff) |

### Motion Sensors

Philips Hue motion sensor with occupancy, illuminance, and temperature. Configurable `occupancy_timeout_seconds` (default 60s) and optional `max_illuminance` gate (suppresses motion-on above threshold).

| Prefix | Manufacturer | zigbee2mqtt docs |
|--------|-------------|-----------------|
| `hue-ms-` | Philips / Signify | [Philips motion sensors](https://www.zigbee2mqtt.io/supported-devices/#v=Philips&e=occupancy) |

### TRVs (Thermostatic Radiator Valves)

Bosch BTH-RA. Setpoint range 5.0--30.0 C, driven by temperature schedules. Internal PID controller manages valve position. Reports `running_state` (Idle/Heat), `pi_heating_demand` (0--100), `local_temperature`, and battery level.

| Prefix | Model | zigbee2mqtt docs |
|--------|-------|-----------------|
| `bosch-trv-` | Bosch BTH-RA | [BTH-RA](https://www.zigbee2mqtt.io/devices/BTH-RA.html) |

### Wall Thermostats (Relay)

Bosch BTH-RM230Z 230V wall thermostat used as a relay for floor heating circuits. Provisioned with `heater_type: manual_control`, controlled via `state: ON/OFF`. Must be in `operating_mode: manual`.

| Prefix | Model | zigbee2mqtt docs |
|--------|-------|-----------------|
| `bosch-wt-` | Bosch BTH-RM230Z | [BTH-RM230Z](https://www.zigbee2mqtt.io/devices/BTH-RM230Z.html) |

### Zigbee Plugs

| Variant | Model | Capabilities | zigbee2mqtt docs |
|---------|-------|-------------|-----------------|
| `sonoff-power` | Sonoff S31ZB / S40ZBTPB | on-off, power, energy | [S31ZB](https://www.zigbee2mqtt.io/devices/S31ZB.html), [S40ZBTPB](https://www.zigbee2mqtt.io/devices/S40ZBTPB.html) |
| `sonoff-basic` | Sonoff ZBMINIL2 | on-off | [ZBMINIL2](https://www.zigbee2mqtt.io/devices/ZBMINIL2.html) |
| `ikea-outlet` | IKEA TRADFRI | on-off | [IKEA outlets](https://www.zigbee2mqtt.io/supported-devices/#v=IKEA&e=state) |
| `tuya-power` | Tuya smart plug | on-off, power, energy, voltage, current | [Tuya plugs](https://www.zigbee2mqtt.io/supported-devices/#v=Tuya&e=power) |

Plug prefix: `sonoff-p-`, `ikea-p-`, `tuya-p-`.

## Z-Wave Devices

All Z-Wave devices communicate through Z-Wave JS UI with separate MQTT topics per command class.

### Z-Wave Plugs

| Variant | Model | Capabilities | Z-Wave JS docs |
|---------|-------|-------------|---------------|
| `neo-nas-wr01ze` | Neo Electronics NAS-WR01ZE | on-off, power, energy | [Z-Wave JS device database](https://devices.zwave-js.io/) |

Plug prefix: `zneo-p-`.

Known firmware bug: NAS-WR01ZE randomly sets bit 31 in 4-byte meter report mantissa, producing large negative power values. The controller (and a nixpkgs overlay patch on `zwave-js-ui`) masks off the MSB when the parsed value is implausibly negative.

## Capability Reference

| Capability | Description | Plug variants |
|-----------|-------------|---------------|
| `on-off` | Binary switch control | all |
| `power` | Real-time power (watts) | `sonoff-power`, `tuya-power`, `neo-nas-wr01ze` |
| `energy` | Cumulative energy (kWh) | `sonoff-power`, `tuya-power`, `neo-nas-wr01ze` |
| `voltage` | Mains voltage | `tuya-power` |
| `current` | Current draw (amps) | `tuya-power` |
