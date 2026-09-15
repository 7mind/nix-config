import { z } from 'zod';

const number = z.number().finite();
const timestamp = number.int().nonnegative().max(Number.MAX_SAFE_INTEGER);
const maybeNumber = number.nullish();
const actualMeta = z.object({ freshness: z.string().default('unknown'), since_ago_ms: timestamp.nullish() });
const targetMeta = z.object({ phase: z.string().default('unset'), owner: z.string().default(''), since_ago_ms: timestamp.nullish() });
const tass = { target: targetMeta.nullish(), actual: actualMeta.nullish() };
const switchInfo = z.object({
  device: z.string(), buttons: z.array(z.object({ button: z.string(), actions: z.array(z.object({ gesture: z.string(), description: z.string() })) })),
});
// The Rust serde names are snake_case on target values, PascalCase on messages.
const lightTargetWire = z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('off') }),
  z.object({ kind: z.literal('on'), brightness: maybeNumber, color_temp: maybeNumber }),
]);
export const lightSchema = z.object({
  ...tass, device: z.string(), room: z.string().nullish(), target_value: lightTargetWire.nullish(),
  actual_value: z.object({ on: z.boolean(), brightness: maybeNumber, color_temp: maybeNumber, color_xy: z.tuple([number, number]).nullish() }).nullish(),
});
const motion = z.object({
  name: z.string(), mode: z.enum(['on-off', 'on-only', 'off-only']), active_slot: z.string().nullable(),
  targets: z.array(z.string()), session_targets: z.array(z.string()), max_illuminance: maybeNumber,
  off_cooldown_secs: number, cooldown_remaining_secs: maybeNumber,
  sensors: z.array(z.object({ device: z.string(), occupied: z.boolean().nullish(), illuminance: maybeNumber,
    freshness: z.string().default('unknown'), since_ago_ms: timestamp.nullish(), occupancy_timeout_secs: number.default(0) })),
});
export const roomSchema = z.object({
  ...tass, name: z.string(), group_name: z.string(), physically_on: z.boolean(), motion_owned: z.boolean(),
  active_slot: z.string().nullable(), scene_ids: z.array(number.int()), cycle_idx: number.int(),
  target_value: z.discriminatedUnion('kind', [z.object({ kind: z.literal('off') }), z.object({ kind: z.literal('on'), scene_id: number.int(), cycle_idx: number.int() })]).nullish(),
  actual_value: z.enum(['on', 'off']).nullish(), switches: z.array(switchInfo).default([]),
  lights: z.array(z.object({ device: z.string() })).default([]), motion_rules: z.array(motion).default([]),
});
export const plugSchema = z.object({
  ...tass, device: z.string(), on: z.boolean(), target_value: z.enum(['on', 'off']).nullish(),
  actual_value: z.object({ on: z.boolean(), power: maybeNumber }).nullish(), power_watts: maybeNumber,
  idle_since_ago_ms: timestamp.nullable(), kill_switch_holdoff_secs: maybeNumber,
  kill_switch_rules: z.array(z.object({ rule_name: z.string(), state: z.string(), threshold_watts: number, holdoff_secs: number, idle_since_ago_ms: timestamp.nullish() })).default([]),
  linked_switches: z.array(switchInfo).default([]),
});
export const valveTargetSchema = z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('setpoint'), temperature: number }), z.object({ kind: z.literal('inhibited') }),
  z.object({ kind: z.literal('forced_open'), reason: z.string() }),
]);
export const valveSchema = z.object({
  ...tass, device: z.string(), local_temperature: number.nullable(), setpoint: number.nullable(),
  pi_heating_demand: number.nullable(), battery: number.nullable(), running_state: z.string(),
  inhibited: z.boolean(), forced: z.boolean().default(false), schedule: z.string().default(''),
  schedule_summary: z.string().default(''), target_value: valveTargetSchema.nullish(),
});
export const heatingSchema = z.object({
  ...tass, name: z.string(), relay_device: z.string(), relay_on: z.boolean(), relay_state_known: z.boolean(),
  relay_temperature: number.nullable(), relay_stale: z.boolean().default(false),
  min_cycle_remaining_secs: number.default(0), min_pause_remaining_secs: number.default(0),
  target_value: z.enum(['heating', 'off']).nullish(),
  actual_value: z.object({ relay_on: z.boolean(), temperature: maybeNumber }).nullish(), trvs: z.array(valveSchema),
});
export const historyPointSchema = z.object({
  timestamp_epoch_ms: timestamp, observed_at_epoch_ms: timestamp.nullable(), local_temperature: number.nullable(),
  reported_setpoint: number.nullable(), target: valveTargetSchema.nullable(), heating_demand: number.nullable(),
  battery: number.nullable(), freshness: z.string(),
});
export const commandSchema = z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('RecallScene'), room: z.string(), scene_id: number.int().min(0).max(255) }),
  z.object({ kind: z.literal('SetRoomOff'), room: z.string() }),
  z.object({ kind: z.literal('SetPlugPower'), device: z.string(), on: z.boolean() }),
]);
export const snapshotSchema = z.object({
  type: z.literal('StateSnapshot'), rooms: z.array(roomSchema), plugs: z.array(plugSchema),
  heating_zones: z.array(heatingSchema).default([]), lights: z.array(lightSchema).default([]), timestamp_epoch_ms: timestamp,
});
const entitySchema = z.discriminatedUnion('kind', [
  z.object({ type: z.literal('Entity'), kind: z.literal('Room'), data: roomSchema }),
  z.object({ type: z.literal('Entity'), kind: z.literal('Plug'), data: plugSchema }),
  z.object({ type: z.literal('Entity'), kind: z.literal('HeatingZone'), data: heatingSchema }),
  z.object({ type: z.literal('Entity'), kind: z.literal('Light'), data: lightSchema }),
]);
export const historySchema = z.object({
  type: z.literal('ValveHistory'), request_id: z.string(), device: z.string(), from_epoch_ms: timestamp, to_epoch_ms: timestamp,
  points: z.array(historyPointSchema), error: z.string().nullable(),
});
export const serverSchema = z.union([
  snapshotSchema, entitySchema, historySchema,
  z.object({ type: z.literal('CommandResult'), request_id: z.string(), error: z.string().nullable() }),
  z.object({ type: z.literal('Pong'), nonce: z.string(), client_ts_ms: timestamp, server_ts_ms: timestamp }),
  z.object({ type: z.literal('EventLog') }), z.object({ type: z.literal('EntityLog') }), z.object({ type: z.literal('Topology') }),
]);
export type Room = z.infer<typeof roomSchema>;
export type Plug = z.infer<typeof plugSchema>;
export type Light = z.infer<typeof lightSchema>;
export type Valve = z.infer<typeof valveSchema>;
export type HeatingZone = z.infer<typeof heatingSchema>;
export type ActualMeta = z.infer<typeof actualMeta>;
export type TargetMeta = z.infer<typeof targetMeta>;
export type ValveTarget = z.infer<typeof valveTargetSchema>;
export type HistoryPoint = z.infer<typeof historyPointSchema>;
export type ValveHistory = z.infer<typeof historySchema>;
export type Snapshot = z.infer<typeof snapshotSchema>;
export type ServerMessage = z.infer<typeof serverSchema>;
export type ControlCommand = z.infer<typeof commandSchema>;
export type ClientMessage =
  | { type: 'GetState' }
  | { type: 'Ping'; nonce: string; client_ts_ms: number }
  | { type: 'Command'; request_id: string; command: ControlCommand }
  | { type: 'GetValveHistory'; request_id: string; device: string };
