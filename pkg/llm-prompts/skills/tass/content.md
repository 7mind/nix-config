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
- `Pending → Commanded`: The effect executor emits the command. In fire-and-forget
  systems (MQTT QoS 0), this transition is immediate. In request-response systems,
  it may await an acknowledgment.
- `Commanded → Confirmed`: An actual state reading arrives that matches the target
  value (within tolerance for analog values).
- `Confirmed → Pending`: A new target value is set, invalidating the previous
  confirmation.
- `Commanded → Pending`: A new target value is set before confirmation arrived.
  The old command is superseded.

### Collapsing Pending and Commanded

In fire-and-forget systems where command emission is synchronous with effect
processing (e.g., the business logic returns effects that are immediately
published), `Pending` and `Commanded` can be collapsed. The business logic sets
the target **and** emits the command in one step, transitioning directly to
`Commanded`. This is the common case for MQTT controllers.

### Phase Never Returns to Unset

Once a target is set, the entity stays in the target lifecycle. There is no
"un-targeting." To stop controlling an entity, set the target to a neutral value
(e.g., Off) rather than returning to Unset.

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

## Event Processing Model

The core computation is a **pure function**:

```
process(event, world_state, clock, topology) → (effects, world_state')
```

- **event**: A typed, parsed event from the outside world (button press, sensor
  reading, MQTT message, timer tick, WebSocket command).
- **world_state**: The complete collection of all TASS entities.
- **clock**: Abstracted time source (injectable for testing).
- **topology**: Immutable structural metadata (rooms, bindings, schedules).
- **effects**: Commands to emit, messages to broadcast, timers to schedule.
- **world_state'**: The updated entity state.

No I/O happens inside the processing function. Effects are **returned**, not
**executed**. The caller (daemon event loop) executes them.

### Effect Types

Effects are the outputs of the processing function:

| Effect                | Description                                         |
|-----------------------|-----------------------------------------------------|
| **Command**           | Publish an MQTT message to control a device/group   |
| **RequestState**      | Publish a `/get` request for fresh state            |
| **BroadcastState**    | Push state update to WebSocket clients              |
| **PublishDiscovery**  | Publish HA MQTT discovery config                    |
| **ScheduleTimer**     | Schedule a deferred callback (e.g., holdoff expiry) |
| **CancelTimer**       | Cancel a previously scheduled timer                 |

## Cross-Entity Logic

Business logic may read **multiple entities** to compute effects:

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
- **Pressure groups**: When any heating zone needs heat, force-open all TRVs in
  the group.
- **Kill switch**: Reads plug power, sets plug target to Off when conditions met.
- **Parent-child rooms**: Parent zone off propagates to child zones.

### Important: Target May Change in Response to Actual

The business logic may change a target in response to an actual state reading:
- A physical button press (actual event) sets a light zone's target.
- A motion sensor's actual state change triggers a light zone target change.
- A plug's actual power reading (below threshold) triggers a target change (off).

This is not a violation of the pattern — it's how the pattern connects the
physical world to the control logic.

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

Because the processing function is pure, tests are straightforward:

```
// Arrange
let mut world = test_world();
assert_eq!(world.light_zone("kitchen").target_phase(), Unset);

// Act: button press
let effects = process(button_press("switch", "1", Press), &mut world, &clock);

// Assert: target set, command emitted
assert_eq!(world.light_zone("kitchen").target_value(), On(scene=1));
assert_eq!(world.light_zone("kitchen").target_phase(), Commanded);
assert_eq!(effects, [Command("hue-lz-kitchen", scene_recall(1))]);

// Act: z2m confirms group is on
let effects = process(group_state("hue-lz-kitchen", true), &mut world, &clock);

// Assert: target confirmed
assert_eq!(world.light_zone("kitchen").target_phase(), Confirmed);
assert_eq!(world.light_zone("kitchen").actual_freshness(), Fresh);
```

No mocking of MQTT. No sequencing of boolean flags. Every state is explicit and
inspectable. Property-based testing becomes natural: generate random event
sequences and assert invariants hold (e.g., "target phase never skips Commanded").

## Summary

TASS provides:

1. **Clarity**: "What we want" and "what we know" are always separate.
2. **Discipline**: State machines define all valid states and transitions.
3. **Resilience**: Actual state naturally fades (Fresh → Stale). Communication
   failures are visible, not hidden.
4. **Testability**: Pure function processing with inspectable state.
5. **Debuggability**: Every entity's complete state is visible and timestamped.
6. **Composability**: Cross-entity logic reads multiple entities cleanly.
