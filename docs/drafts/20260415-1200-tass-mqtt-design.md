# TASS-Based MQTT Controller Design

Design for rewriting the mqtt-controller using the TASS pattern.

## Architecture Overview

```
┌──────────────────────────────────────────────────────────┐
│                     Event Sources                        │
│  MQTT messages · Timers · WebSocket commands             │
└────────────────────────┬─────────────────────────────────┘
                         │ raw bytes
                         ▼
┌──────────────────────────────────────────────────────────┐
│                    Event Parsing                         │
│  mqtt/codec.rs: parse MQTT payloads → typed Events      │
│  (unchanged from current implementation)                 │
└────────────────────────┬─────────────────────────────────┘
                         │ Event enum
                         ▼
┌──────────────────────────────────────────────────────────┐
│              EventProcessor (pure function)               │
│                                                          │
│  Input:  Event + WorldState + Clock + Topology           │
│  Output: Vec<Effect> + mutated WorldState                │
│                                                          │
│  ┌─────────────┐ ┌────────────┐ ┌──────────────┐       │
│  │ light_logic │ │ plug_logic │ │ heating_logic│       │
│  └─────────────┘ └────────────┘ └──────────────┘       │
│  ┌──────────────┐ ┌───────────────┐ ┌────────────┐     │
│  │ motion_logic │ │ schedule_logic│ │ button_disp│     │
│  └──────────────┘ └───────────────┘ └────────────┘     │
└────────────────────────┬─────────────────────────────────┘
                         │ Vec<Effect>
                         ▼
┌──────────────────────────────────────────────────────────┐
│                   Effect Executor                        │
│  MQTT publish · WebSocket broadcast · HA discovery       │
│  (daemon.rs dispatches effects to MQTT bridge/web)       │
└──────────────────────────────────────────────────────────┘
```

## TASS Entity Types

### 1. LightZone

One per room/group. Represents a controllable light zone.

```rust
// --- Target ---
enum LightZoneTarget {
    Off,
    On { scene_id: u8, cycle_idx: usize },
}

enum LightZoneOwner {
    Unset,
    User,
    Motion,
    Schedule,
    WebUI,
    System,
}

// --- Actual ---
enum LightZoneActual {
    On,
    Off,
}

// --- Full entity ---
struct LightZoneEntity {
    target: TassTarget<LightZoneTarget>,  // value + phase + owner + timestamp
    actual: TassActual<LightZoneActual>,  // value + freshness + timestamp
    last_press_at: Option<Instant>,       // for cycle window (not TASS state)
    last_off_at: Option<Instant>,         // for motion cooldown (not TASS state)
}
```

**Why `last_press_at` and `last_off_at` are not in TASS**: These are event
timestamps used by business logic predicates (cycle window, cooldown). They
don't represent entity state — they're timing metadata for decision-making.

### 2. Plug

One per smart plug device.

```rust
// --- Target ---
enum PlugTarget {
    On,
    Off,
}

// --- Actual ---
struct PlugActual {
    on: bool,
    power: Option<f64>,  // watts, None if not yet reported
}

// --- Kill switch per-rule state ---
enum KillSwitchRuleState {
    Inactive,                    // rule not yet armed
    Armed,                       // power seen above threshold at least once
    Idle { since: Instant },     // power below threshold, holdoff running
    Suppressed,                  // fired, suppressed until power recovers
}

// --- Full entity ---
struct PlugEntity {
    target: TassTarget<PlugTarget>,
    actual: TassActual<PlugActual>,
    kill_switch_rules: BTreeMap<String, KillSwitchRuleState>,  // rule_name → state
    confirm_off: Option<Instant>,  // confirm-off pending timestamp
}
```

**Kill switch as entity state**: The armed/idle/suppressed state machine is now
an explicit enum per rule, colocated with the plug it monitors. No more three
separate BTreeMaps on the controller.

### 3. MotionSensor

Read-only entity. No target state.

```rust
// --- Actual ---
struct MotionActual {
    occupied: bool,
    illuminance: Option<u32>,  // lux
}

// --- Full entity ---
struct MotionSensorEntity {
    actual: TassActual<MotionActual>,
}
```

### 4. HeatingZone

One per heating zone (relay + TRVs).

```rust
// --- Target ---
enum HeatingZoneTarget {
    Heating,
    Off,
}

// --- Actual ---
struct HeatingZoneActual {
    relay_on: bool,
    temperature: Option<f64>,  // from wall thermostat sensor
}

// --- Full entity ---
struct HeatingZoneEntity {
    target: TassTarget<HeatingZoneTarget>,
    actual: TassActual<HeatingZoneActual>,
    pump_on_since: Option<Instant>,   // for min_cycle enforcement
    pump_off_since: Option<Instant>,  // for min_pause enforcement
}
```

### 5. TRV

One per thermostatic radiator valve.

```rust
// --- Target ---
enum TrvTarget {
    Setpoint(f64),              // normal schedule-driven temperature
    Inhibited,                  // window open → min setpoint
    ForcedOpen,                 // pressure group → max setpoint
}

enum TrvTargetOwner {
    Schedule,
    PressureGroup,
    OpenWindow,
}

// --- Actual ---
struct TrvActual {
    local_temperature: Option<f64>,
    pi_heating_demand: Option<u8>,
    running_state: Option<String>,  // "heat" or "idle"
    setpoint: Option<f64>,
    operating_mode: Option<String>,
    battery: Option<u8>,
}

// --- Full entity ---
struct TrvEntity {
    target: TassTarget<TrvTarget>,
    actual: TassActual<TrvActual>,
    last_seen: Option<Instant>,
}
```

## WorldState

```rust
struct WorldState {
    light_zones: BTreeMap<String, LightZoneEntity>,    // room_name → entity
    plugs: BTreeMap<String, PlugEntity>,               // device_name → entity
    motion_sensors: BTreeMap<String, MotionSensorEntity>, // sensor_name → entity
    heating_zones: BTreeMap<String, HeatingZoneEntity>, // zone_name → entity
    trvs: BTreeMap<String, TrvEntity>,                 // device_name → entity

    // Non-entity state (transient event processing)
    pending_presses: BTreeMap<(String, String), PendingPress>,
    last_double_tap: BTreeMap<(String, String), Instant>,
    at_last_fired: BTreeMap<String, (u8, u8)>,

    // Time
    cached_sun: Option<(NaiveDate, i32, SunTimes)>,
}
```

## Event Types (Unchanged)

The existing `Event` enum is kept as-is. Events are external facts that arrive
from the MQTT bridge. They don't need to change for TASS.

```rust
enum Event {
    ButtonPress { device, button, gesture, ts },
    Occupancy { sensor, occupied, illuminance, ts },
    GroupState { group, on, ts },
    PlugState { device, on, power, ts },
    PlugPowerUpdate { device, watts, ts },
    TrvState { device, ..., ts },
    WallThermostatState { device, ..., ts },
    Tick { ts },
}
```

## Effect Types (Replaces Action)

Effects replace the current `Action` enum. They're more explicit about intent:

```rust
enum Effect {
    // MQTT commands
    PublishGroupSet { group: String, payload: MqttPayload },
    PublishDeviceSet { device: String, payload: MqttPayload },
    PublishDeviceGet { device: String },
    PublishRaw { topic: String, payload: String, retain: bool },

    // HA discovery
    PublishHaDiscovery { zone: String, config: String },
    PublishHaState { zone: String, state: String },

    // WebSocket
    BroadcastSnapshot,       // trigger full state broadcast
    BroadcastEntityUpdate {  // incremental entity update
        entity_type: EntityType,
        entity_name: String,
    },
    BroadcastEventLog { entry: DecisionLogEntry },
}
```

`MqttPayload` is the existing `Payload` enum (SceneRecall, StateOff, etc.).

## Business Logic Modules

### EventProcessor

The top-level dispatcher, replacing `Controller`:

```rust
struct EventProcessor {
    world: WorldState,
    topology: Arc<Topology>,
    clock: Arc<dyn Clock>,
    defaults: Defaults,
    location: Option<Location>,
}

impl EventProcessor {
    fn process_event(&mut self, event: Event) -> Vec<Effect> {
        match event {
            Event::ButtonPress { .. } => button_dispatch::handle(self, &event),
            Event::Occupancy { .. } => motion_logic::handle(self, &event),
            Event::GroupState { .. } => light_logic::handle_group_state(self, &event),
            Event::PlugState { .. } | Event::PlugPowerUpdate { .. } =>
                plug_logic::handle(self, &event),
            Event::TrvState { .. } => heating_logic::handle_trv(self, &event),
            Event::WallThermostatState { .. } => heating_logic::handle_relay(self, &event),
            Event::Tick { .. } => self.handle_tick(&event),
        }
    }
}
```

### light_logic

Handles light zone state transitions:

- **Button press → set target**: Resolves binding, sets target to On(scene_id),
  phase to Commanded, emits SceneRecall effect.
- **Group state echo → update actual**: Sets actual to On/Off with Fresh
  freshness. If actual matches target, advances phase to Confirmed.
- **Startup → set target Off**: Sets target to Off with System owner, emits
  StateOff for motion-controlled zones.
- **Scene cycle**: Uses `last_press_at` and cycle window to determine whether to
  advance, toggle off, or fresh-on.
- **Propagation**: When a parent zone changes, propagates to descendants by
  updating their actual state (soft propagation) or target (hard propagation).

### motion_logic

Handles motion sensor → light zone interactions:

- **Occupancy update → update sensor actual**: Sets MotionSensor actual to
  Occupied/Vacant with illuminance.
- **Motion-on evaluation**: Checks gates (zone physically off, illuminance below
  threshold, cooldown expired, all using TASS state). If gates pass, sets light
  zone target to On with Motion owner.
- **Motion-off evaluation**: Checks that owner is Motion, all sensors for the
  room are Vacant, zone is physically on. If all pass, sets light zone target to
  Off.

### plug_logic

Handles plug state and kill switch:

- **Plug state event → update actual**: Sets PlugActual with on/off and power.
  If actual matches target, advances phase to Confirmed.
- **Power update → evaluate kill switch**: For each kill switch rule on this plug,
  transitions the rule's state machine:
  - Below threshold + Armed → Idle(now)
  - Above threshold → Armed (clear idle, lift suppression)
  - Idle for holdoff duration → fire: set plug target to Off, suppress all rules
- **Tick → evaluate holdoffs**: Check all Idle rules for holdoff expiry.

### heating_logic

Handles heating zones, TRVs, and relay control:

- **TRV state event → update TRV actual**: Merges partial readings into TrvActual.
- **Relay state event → update zone actual**: Sets HeatingZoneActual relay_on.
  Tracks pump_on_since/pump_off_since.
- **Schedule evaluation (tick)**: Computes desired temperature per TRV from
  schedule. Sets TRV target to Setpoint(temp).
- **Pressure group evaluation**: When any zone needs heat, sets all TRVs in the
  pressure group to ForcedOpen.
- **Open window detection**: If TRV demand doesn't rise after N minutes, sets
  TRV target to Inhibited.
- **Relay control**: Evaluates whether zone needs heat (any TRV demanding).
  Enforces min_cycle/min_pause constraints.

### schedule_logic

Handles At triggers (unchanged logic, operates on TASS world state).

### button_dispatch

Handles the button press pipeline:
1. Hardware double-tap suppression
2. Soft double-tap deferral
3. Binding lookup → effect execution

## Startup Sequence

With TASS, startup is simpler:

1. Build topology, create EventProcessor with all entities in Unset/Unknown state.
2. Connect to MQTT. Subscribe to all topics.
3. Drain retained messages (200ms). Each retained message updates the
   corresponding entity's actual state (Unknown → Fresh).
4. For entities still in Unknown after drain: emit RequestState effects
   (publish `/get`).
5. Drain `/get` responses (2s). More actual states arrive.
6. For motion-controlled zones with actual=On: set target to Off, emit StateOff.
7. For plugs with actual=On: transition kill switch rules to Armed.
8. Start event loop.

The 5-phase startup with per-device-type phases is replaced by a uniform process:
all entities start Unknown, readings arrive, entities become Known. No special
cases per device type.

## Frontend Systems View

### Wire Types

```rust
// Each system groups an entity with all its related devices
struct LightSystemSnapshot {
    // Primary entity
    name: String,
    group_name: String,
    target: TargetSnapshot,         // { value, phase, owner, since_ms }
    actual: ActualSnapshot,         // { value, freshness, since_ms }

    // Slot/scene info
    active_slot: Option<String>,
    scene_ids: Vec<u8>,

    // Related devices
    switches: Vec<SwitchInfo>,       // { device, button, last_event }
    motion_sensors: Vec<MotionSensorSnapshot>,
    members: Vec<String>,            // bulb names

    // Timing
    last_press_ago_ms: Option<u64>,
    last_off_ago_ms: Option<u64>,
    cycle_window_ms: u64,
}

struct SwitchInfo {
    device: String,
    button: String,
    last_event: Option<SwitchEventSnapshot>,  // gesture + timestamp
}

struct SwitchEventSnapshot {
    gesture: String,
    ago_ms: u64,
}

struct MotionSensorSnapshot {
    device: String,
    occupied: Option<bool>,
    illuminance: Option<u32>,
    freshness: String,
    since_ago_ms: Option<u64>,
}

struct PlugSystemSnapshot {
    device: String,
    target: TargetSnapshot,
    actual: ActualSnapshot,
    power: Option<f64>,

    kill_switch_rules: Vec<KillSwitchRuleSnapshot>,
    linked_switches: Vec<SwitchInfo>,
}

struct KillSwitchRuleSnapshot {
    rule_name: String,
    state: String,          // "inactive", "armed", "idle", "suppressed"
    threshold_watts: f64,
    holdoff_secs: u64,
    idle_since_ago_ms: Option<u64>,  // only when state="idle"
}

struct HeatingSystemSnapshot {
    name: String,
    target: TargetSnapshot,
    actual: ActualSnapshot,
    relay_device: String,

    trvs: Vec<TrvSystemSnapshot>,
    min_cycle_remaining_secs: Option<f64>,
    min_pause_remaining_secs: Option<f64>,
}

struct TrvSystemSnapshot {
    device: String,
    target: TargetSnapshot,
    actual: TrvActualSnapshot,
    schedule_name: Option<String>,
    schedule_summary: Option<String>,
}

struct TargetSnapshot {
    value: String,       // human-readable target value
    phase: String,       // "unset", "pending", "commanded", "confirmed"
    owner: String,       // "user", "motion", "schedule", etc.
    since_ago_ms: u64,
}

struct ActualSnapshot {
    value: String,       // human-readable actual value
    freshness: String,   // "unknown", "fresh", "stale", "deprecated"
    since_ago_ms: Option<u64>,
}
```

### UI Layout

**Light System Card:**
```
┌─────────────────────────────────────────────────────────┐
│ ● Kitchen Cooker                          [day] cycle:0 │
│ Target: On(S1: bright cool) · Confirmed · user · 5m    │
│ Actual: On · fresh · 5m                                 │
│─────────────────────────────────────────────────────────│
│ Switches:                                               │
│   hue-ts-kitchen-entrance [2] · press 5m ago            │
│   hue-ts-kitchen-center [2]                             │
│ Motion:                                                 │
│   hue-ms-landing: vacant · 15 lux · fresh 2m           │
│─────────────────────────────────────────────────────────│
│ [S1: bright] [S2: warm] [S3: dim]              [OFF]   │
└─────────────────────────────────────────────────────────┘
```

**Plug System Card:**
```
┌─────────────────────────────────────────────────────────┐
│ ● sonoff-p-ws-pavel-displays                            │
│ Target: On · Confirmed · user · 2h                      │
│ Actual: On · 145W · fresh · 3s                          │
│─────────────────────────────────────────────────────────│
│ Kill Switch:                                            │
│   ws-pavel-displays-kill: armed · <20W for 30m          │
│ Switch:                                                 │
│   hue-s-living-room-tv [off] · soft_double_tap 2h ago   │
│─────────────────────────────────────────────────────────│
│ [Toggle]                                                │
└─────────────────────────────────────────────────────────┘
```

**Heating System Card:**
```
┌─────────────────────────────────────────────────────────┐
│ ● Upstairs                                              │
│ Target: Heating · Commanded · schedule · 1m              │
│ Actual: relay ON · 20.5°C · fresh · 30s                 │
│ min_cycle: 4m remaining                                 │
│─────────────────────────────────────────────────────────│
│ TRVs:                                                   │
│   bosch-trv-master-bedroom                              │
│     Target: 21.0°C · Confirmed · schedule               │
│     Actual: 20.8°C · demand 85% · heat · fresh 45s      │
│     Battery: 78%                                        │
│   bosch-trv-master-bathroom                             │
│     Target: 18.0°C · Confirmed · schedule               │
│     Actual: 19.2°C · demand 0% · idle · fresh 60s       │
│     Battery: 92%                                        │
└─────────────────────────────────────────────────────────┘
```

## What Changes vs What Stays

### Unchanged
- `config/` — Configuration parsing and types
- `topology.rs` — Immutable structure validation
- `provision/` — Zigbee2MQTT provisioning
- `time.rs`, `sun.rs` — Clock and sunrise/sunset
- `mqtt/codec.rs`, `mqtt/topics.rs` — MQTT constants and topic builders
- `mqtt/mod.rs` — MQTT bridge (mostly; event parsing stays, effect publishing
  adapted to new Effect enum)
- `daemon.rs` — Event loop structure (adapted for EventProcessor API)

### Replaced
- `domain/state.rs` → `tass.rs` + `entities/` module
- `controller/mod.rs` → `logic/mod.rs` (EventProcessor)
- `controller/room.rs` → `logic/lights.rs`
- `controller/motion.rs` → `logic/motion.rs`
- `controller/plug.rs` + `controller/kill_switch.rs` → `logic/plugs.rs`
- `controller/heating.rs` → `logic/heating.rs`
- `controller/actions.rs` → `logic/schedule.rs`
- `domain/action.rs` → `domain/effect.rs`
- `web/snapshot.rs` → updated for TASS entities
- `mqtt-controller-wire` → expanded for systems view

### New
- `tass.rs` — Core TASS generic types
- `entities/` — Entity type definitions
- `logic/buttons.rs` — Button dispatch (extracted from controller/mod.rs)
- Frontend system components (replacing simple card components)

## Migration Strategy

Full rewrite (not incremental). The TASS pattern fundamentally changes state
management — a hybrid would be more complex than either approach alone.

1. Implement core TASS types (`tass.rs`)
2. Implement entity types (`entities/`)
3. Implement business logic modules (`logic/`)
4. Wire into daemon and MQTT bridge
5. Update wire types and frontend
6. Rewrite tests
7. Verify all hosts build
