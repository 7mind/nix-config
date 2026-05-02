# TASS: Target/Actual State Separation

A pattern for reliable state management in event-driven control systems.

## Problem

Control systems manage devices and subsystems whose state is observed indirectly
(via sensors, network messages, or periodic readings) and changed via commands
that may fail, be delayed, or produce unexpected results. Ad-hoc state tracking
leads to:

- **State confusion**: no clear distinction between "what we want" and "what we
  know." Boolean flags like `is_on` conflate commanded state with observed state.
- **Corner cases**: stale readings, out-of-order events, partial updates, and
  startup races each require one-off workarounds.
- **Hard debugging**: reconstructing "why is the system in this state?" requires
  mental replay of event logs.
- **Fragile tests**: tests must carefully sequence mock events and assert on
  interleaved boolean flags rather than inspecting structured state.

## Core Concept

Every controllable entity is represented as a **quadruple**:

```
Entity = (TargetState, TargetPhase, ActualState, ActualFreshness)
```

| Component         | Meaning                                         |
|-------------------|-------------------------------------------------|
| **TargetState**   | What we want the entity to be (value)           |
| **TargetPhase**   | Lifecycle of the current target (state machine) |
| **ActualState**   | Last observed state of the entity (value)       |
| **ActualFreshness** | How recent/reliable the observation is (state machine) |

Read-only entities (sensors) have only the actual half. Event sources (buttons)
have no persistent TASS state.

## Target Phase State Machine

```
         set_target()           emit_command()           confirm()
  Unset ───────────→ Pending ──────────────→ Commanded ──────────→ Confirmed
                        ↑                                             │
                        └─────────────────────────────────────────────┘
                                     set_target() [new target]
```

| Phase       | Meaning                                                      |
|-------------|--------------------------------------------------------------|
| **Unset**   | Initial. No target has been defined. System is passive.      |
| **Pending** | A target value was set (by user, logic, or schedule). The    |
|             | system has not yet emitted the command to the physical world.|
| **Commanded** | The command was emitted (e.g., MQTT publish). Awaiting      |
|             | confirmation from actual state.                              |
| **Confirmed** | An actual state reading confirms the entity matches the    |
|             | target. The system is at rest for this entity.               |

### Transitions

- `Unset → Pending`: User, automation rule, or schedule sets a target value.
- `Pending → Commanded`: The runtime emits the command (after a core returns
  it as an effect). In fire-and-forget systems (MQTT QoS 0), this transition
  is immediate. In request-response systems, it may await an acknowledgment.
- `Commanded → Confirmed`: An actual state reading arrives that matches the target
  value (within tolerance for analog values).
- `Confirmed → Pending`: A new target value is set, invalidating the previous
  confirmation.
- `Commanded → Pending`: A new target value is set before confirmation arrived.
  The old command is superseded.

### Collapsing Pending and Commanded

In fire-and-forget systems where command emission is synchronous with effect
processing (e.g., a core returns effects that are immediately published),
`Pending` and `Commanded` can be collapsed. The core sets the target **and**
emits the command in one step, transitioning directly to `Commanded`. This is
the common case for MQTT controllers.

### Phase Never Returns to Unset

Once a target is set, the entity stays in the target lifecycle. There is no
"un-targeting." To stop controlling an entity, set the target to a neutral value
(e.g., Off) rather than returning to Unset.

### Command Retries

When a command is emitted (`Pending → Commanded`) but the matching actual
reading never arrives, the entity stays in `Commanded`. The system does not
silently give up — it retries.

Each actuator type defines its own **retry policy**:

- **Backoff**: constant, exponential, or decorrelated jitter
- **Max attempts**: usually unbounded — keep retrying until confirmed or until
  a new target supersedes the current one
- **Per-attempt deadline**: how long to wait before re-emitting

Retries are the rule, not the exception. Devices drop messages, networks have
transient failures, gateways reboot mid-transaction. The default assumption is
that any single command may not take effect, so a working TASS controller
almost always defines a non-trivial retry policy per actuator type.

Crucially, retry detection uses the **same sensor path** as confirmation.
There is no separate channel for "did the command land?" — if a command's
effect is not observable via the entity's actual state, the system has no way
to confirm or retry it. Design actuators so that all consequential effects are
visible through sensors.

## Actual Freshness State Machine

```
                  reading()                    time_passes()
  Unknown ──────────────→ Fresh(timestamp) ──────────────→ Stale(timestamp)
                              ↑                                │
                              └────────────────────────────────┘
                                        reading()

  On set_target() when actual is Fresh or Stale:
  Fresh/Stale ──→ Deprecated ──→ Fresh(timestamp) [new reading arrives]
```

| Freshness      | Meaning                                                   |
|----------------|-----------------------------------------------------------|
| **Unknown**    | No reading has ever been received. The entity's actual    |
|                | state is not known at all.                                |
| **Fresh**      | A recent reading was received. The timestamp records when.|
|                | "Recent" is defined by a configurable threshold per entity|
|                | type (e.g., 60s for motion sensors, 300s for TRVs).      |
| **Stale**      | The reading is older than the freshness threshold. The    |
|                | last known value is still stored but should be treated    |
|                | with lower confidence.                                    |
| **Deprecated** | The target changed, making this reading irrelevant. The   |
|                | old value describes the *previous* target's state, not    |
|                | the *current* target's. A new reading is needed to        |
|                | confirm the new target.                                   |

### Transitions

- `Unknown → Fresh`: First reading arrives.
- `Fresh → Stale`: Time exceeds the freshness threshold since the last reading.
- `Stale → Fresh`: A new reading arrives, resetting the timestamp.
- `Fresh/Stale → Deprecated`: Target changes to `Pending`. The current reading
  describes the old target, not the new one.
- `Deprecated → Fresh`: A new reading arrives that describes the new target's
  state.

### Actual State Always Stores a Value (When Known)

Even when freshness is `Stale` or `Deprecated`, the actual value is preserved.
This allows the UI to show "last known: ON, 5 minutes ago (stale)" rather than
just "unknown."

## Target Owner

Optionally, each target carries an **owner** — who or what set it:

| Owner        | Meaning                                |
|--------------|----------------------------------------|
| **Unset**    | No target has been set                 |
| **User**     | A physical button press                |
| **Motion**   | Motion sensor automation               |
| **Schedule** | Time-based schedule trigger            |
| **WebUI**    | Web dashboard command                  |
| **System**   | System-level action (startup, etc.)    |
| **Rule**     | An automation rule (e.g., kill switch) |

The owner enables owner-aware logic. For example:
- Motion-off only fires when owner is `Motion` (user presses override).
- Cooldown after off only applies when owner is `User` or `Motion`.
- Kill switch can override any owner.

## Knobs

A typical TASS program exposes a set of **knobs** — dynamically modifiable
parameters that affect decisions. Examples:

- Motion timeout duration
- Temperature setpoints and offsets
- Schedule enable/disable
- Holdoff and cooldown durations
- Threshold levels (lux, power, temperature)
- Mode selectors (Away, Sleep, Vacation)

Knobs are read by the decision logic at every tick. They are typically:

- Settable by the user via a control interface (WebUI, MQTT topic, API)
- Persisted across restarts in their own store
- Treated as inputs to cores, alongside sensor data and ledger entries

Knobs are runtime state, not static configuration: changing a knob takes
immediate effect on subsequent decisions, without code changes or restarts.

**Knobs are distinct from the ledger.** The ledger holds the system's
internal state — what the controller has observed, decided, and remembered.
Knobs are external inputs that the user (or another system) writes; the
controller only reads them. Conflating the two would let the controller
mutate user intent, or let user writes corrupt internal bookkeeping. Keep
the stores separate.

## Ledger

The controller's internal state persists between ticks in a key-value
storage called the **ledger**. The ledger is **not user-modifiable** — it is
written exclusively by the controller's own decision logic. User-facing
inputs go through Knobs; the ledger records what the system observed and
decided.

Ledger entries fall into two categories:

| Type        | Description                                                   |
|-------------|---------------------------------------------------------------|
| **Primary** | Authoritative, stored values: TASS quadruples, latest sensor  |
|             | readings, owners, timestamps, retry counters, history records.|
| **Derived** | Mechanically computed from primary entries (and knob values): |
|             | aggregates ("any motion in zone"), pressure-group verdicts,   |
|             | freshness classifications, cross-entity rollups.              |

Primary entries form the minimal authoritative state. Derived entries are
pure functions of primary state (plus knobs and clock) — they may be cached
for performance but must always be reproducible from primaries alone.

This split has two practical consequences:

1. **Recovery**: after a restart, only primary entries need to be reloaded.
   All derived state is recomputed from them.
2. **Auditability**: any derived value can be re-derived from a snapshot of
   primaries, making "why did the system decide this?" answerable from the
   ledger and knob values alone.

The `world_state` parameter passed to cores (see below) is precisely the
ledger's primary entries, possibly with derived entries materialized on demand.

## Cores

The unit of computation in a TASS system is a **core** — a pure function
that consumes inputs and returns effects and ledger updates:

```
core(event, world_state, knobs, clock, topology) → (effects, world_state')
```

- **event**: A typed, parsed event from the outside world (button press,
  sensor reading, MQTT message, timer tick, WebSocket command).
- **world_state**: The slice of the ledger this core reads — TASS quadruples
  for the entities it owns, plus upstream core outputs and history it
  depends on.
- **knobs**: Current values of the user-modifiable parameters this core
  depends on. Read-only from the core's perspective.
- **clock**: Abstracted time source (injectable for testing).
- **topology**: Immutable structural metadata (rooms, bindings, schedules).
- **effects**: Commands to emit, messages to broadcast, timers to schedule.
- **world_state'**: The updated ledger entries this core writes.

No I/O happens inside a core. Effects are **returned**, not **executed**;
ledger writes are **returned**, not applied. The runtime applies ledger
updates and dispatches effects after the core returns.

Each core owns a coherent slice of behavior — for example:

- "kitchen lighting"
- "heating pressure groups"
- "kill-switch logic"
- "schedule evaluator"

A small TASS program may consist of a single core covering all entities.
Larger programs decompose into many.

### Effect Types

Effects are the outputs of a core:

| Effect                | Description                                         |
|-----------------------|-----------------------------------------------------|
| **Command**           | Publish an MQTT message to control a device/group   |
| **RequestState**      | Publish a `/get` request for fresh state            |
| **BroadcastState**    | Push state update to WebSocket clients              |
| **PublishDiscovery**  | Publish HA MQTT discovery config                    |
| **ScheduleTimer**     | Schedule a deferred callback (e.g., holdoff expiry) |
| **CancelTimer**       | Cancel a previously scheduled timer                 |

### Cross-Entity Logic

A single core typically reads **multiple entities** to compute effects:

```
fn evaluate_motion(
    sensor: &MotionSensorEntity,
    zone: &mut LightZoneEntity,
    all_sensors_for_room: &[&MotionSensorEntity],
    clock: &dyn Clock,
) -> Vec<Effect>
```

This is critical for:
- **Multi-sensor OR-gate**: Motion-off waits for ALL sensors in a room to be
  vacant.
- **Pressure groups**: When any heating zone needs heat, force-open all TRVs
  in the group.
- **Kill switch**: Reads plug power, sets plug target to Off when conditions
  met.
- **Parent-child rooms**: Parent zone off propagates to child zones.

### Target May Change in Response to Actual

A core may change a target in response to an actual state reading:

- A physical button press (actual event) sets a light zone's target.
- A motion sensor's actual state change triggers a light zone target change.
- A plug's actual power reading (below threshold) triggers a target change
  (off).

This is not a violation of the pattern — it's how the pattern connects the
physical world to the control logic.

### Execution DAG

When a TASS program has multiple cores, they may depend on one another's
outputs. These dependencies form a **directed acyclic graph (DAG)** that
defines execution order within a tick:

- Independent cores can run in any order (or in parallel).
- A dependent core runs only after its predecessors have written their
  outputs to the ledger.

Core outputs are stored in the ledger — either as primary entries (decisions
made: target updates, scheduled actions, retry counters) or as derived
entries (computed views, aggregates). Downstream cores read these like any
other ledger data, with no direct coupling to the producer's internals.

This decomposition enables:

- **Independent testing**: each core is a pure function of
  (event, sensors, knobs, ledger slice) → (effects, ledger updates).
- **Local reasoning**: a core's behavior is determined by its inputs from
  sensors, knobs, and the ledger, not by hidden cross-module state.
- **Modular extension**: a new core can subscribe to existing ledger entries
  without modifying upstream producers.

## Typical Tick Loop

A complete TASS program runs as a tick loop. Each tick proceeds in four
phases:

1. **Ingest sensor data**: Collect observations from all sources (MQTT
   messages, periodic polls, button presses, timer firings, WebSocket
   commands). Update actual state, freshness, and sensor readings in the
   ledger.

2. **Compute decisions**: Run the core DAG. For each core, derive new
   targets and effects from:
   - sensor data (just-updated actual state)
   - knob values (current dynamic parameters)
   - ledger data (previous primary state, history, upstream core outputs)

3. **Issue commands**: Emit effects for any entities whose target advanced
   to `Commanded`. Persist target updates and core outputs to the ledger.

4. **Validate and retry**: In subsequent ticks, step (1) supplies
   confirmation through normal sensor readings. Entities still in
   `Commanded` past their actuator's retry deadline have their commands
   re-emitted — through the **same code path** as new commands.

The new-command path and the retry path share infrastructure: there is no
separate "did the command land?" check and no separate retry queue. Both
are driven by the discrepancy between target and actual, observed through
sensors.

## Timestamps

Every phase and freshness transition is timestamped:

```rust
struct Timestamped<T> {
    value: T,
    since: Instant,
}
```

This enables:
- Freshness decay (`Fresh` → `Stale` after N seconds)
- Holdoff evaluation ("power has been below threshold for 30 minutes")
- Cooldown enforcement ("don't re-trigger motion for 30 seconds after off")
- Debugging ("when did this transition happen?")

## Observability

Every entity's complete state is serializable:

```json
{
  "entity": "kitchen-cooker",
  "target": { "value": "On(scene=1)", "phase": "Confirmed", "owner": "User", "since": "12:34:56" },
  "actual": { "value": "On", "freshness": "Fresh", "since": "12:34:57" }
}
```

A monitoring dashboard can show every entity's target/actual/phase/freshness
in real time. Debugging is: "Why isn't the light on?" → check target phase and
actual freshness. Everything is visible.

## Testing Strategy

Because cores are pure functions, tests are straightforward:

```
// Arrange
let mut world = test_world();
let knobs = test_knobs();
assert_eq!(world.light_zone("kitchen").target_phase(), Unset);

// Act: button press
let effects = lighting_core(
    button_press("switch", "1", Press), &mut world, &knobs, &clock,
);

// Assert: target set, command emitted
assert_eq!(world.light_zone("kitchen").target_value(), On(scene=1));
assert_eq!(world.light_zone("kitchen").target_phase(), Commanded);
assert_eq!(effects, [Command("hue-lz-kitchen", scene_recall(1))]);

// Act: z2m confirms group is on
let effects = lighting_core(
    group_state("hue-lz-kitchen", true), &mut world, &knobs, &clock,
);

// Assert: target confirmed
assert_eq!(world.light_zone("kitchen").target_phase(), Confirmed);
assert_eq!(world.light_zone("kitchen").actual_freshness(), Fresh);
```

No mocking of MQTT. No sequencing of boolean flags. Every state is explicit
and inspectable. Property-based testing becomes natural: generate random
event sequences and assert invariants hold (e.g., "target phase never skips
Commanded").

## Summary

TASS provides:

1. **Clarity**: "What we want" and "what we know" are always separate.
2. **Discipline**: State machines define all valid states and transitions.
3. **Resilience**: Actual state naturally fades (Fresh → Stale). Communication
   failures are visible, not hidden. Unconfirmed commands are retried
   automatically through the same sensor path.
4. **Runtime configurability**: Knobs expose decision parameters that take
   effect immediately, without code changes or restarts.
5. **Persistent, inspectable state**: The ledger holds primary state and
   derived views, fully recoverable after restart from primary entries alone.
6. **Composability**: Cores form a DAG; cross-entity logic reads multiple
   entities cleanly.
7. **Testability**: Cores are pure functions with inspectable state.
8. **Debuggability**: Every entity's complete state is visible and timestamped.
