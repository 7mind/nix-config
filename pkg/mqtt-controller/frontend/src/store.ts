import { ConnectionManager, type Health, type Runtime } from './connection';
import type { ControlCommand, HeatingZone, Light, Plug, Room, ServerMessage, ValveHistory } from './protocol';

export interface Timed<T> { value: T; receivedAt: number }
export type CommandStatus =
  | { state: 'pending' | 'accepted'; message: string; command: ControlCommand; confirmed: boolean }
  | { state: 'error'; message: string };
export interface HistoryStatus { loading: boolean; data: ValveHistory | null; error: string | null }
export interface DashboardState {
  health: Health; ready: boolean; receivedAt: number | null;
  rooms: Timed<Room>[]; plugs: Timed<Plug>[]; lights: Timed<Light>[]; heating: Timed<HeatingZone>[];
  commands: ReadonlyMap<string, CommandStatus>; histories: ReadonlyMap<string, HistoryStatus>;
}
const COMMAND_TIMEOUT_MS = 8_000;
const HISTORY_TIMEOUT_MS = 10_000;
const HISTORY_CONCURRENCY = 2;

export class DashboardClient {
  readonly connection: ConnectionManager;
  private state: DashboardState;
  private readonly subscribers = new Set<() => void>();
  private readonly pendingCommands = new Map<string, { key: string; timer: number }>();
  private readonly pendingHistories = new Map<string, { device: string; timer: number }>();
  private historyQueue: string[] = [];
  private destroyed = false;

  constructor(private readonly runtime: Runtime) {
    this.connection = new ConnectionManager(runtime,
      health => this.healthChanged(health), message => this.receive(message), () => this.resync());
    this.state = {
      health: this.connection.stats(), ready: false, receivedAt: null,
      rooms: [], plugs: [], lights: [], heating: [], commands: new Map(), histories: new Map(),
    };
  }
  getSnapshot = (): DashboardState => this.state;
  subscribe = (listener: () => void): (() => void) => { this.subscribers.add(listener); return () => this.subscribers.delete(listener); };
  start(): void { this.connection.start(); }
  destroy(): void {
    this.destroyed = true;
    for (const command of this.pendingCommands.values()) this.runtime.cancel(command.timer);
    for (const history of this.pendingHistories.values()) this.runtime.cancel(history.timer);
    this.pendingCommands.clear();
    this.pendingHistories.clear();
    this.subscribers.clear();
    this.connection.destroy();
  }

  command(key: string, command: ControlCommand): void {
    if (this.destroyed) return;
    const current = this.state.commands.get(key);
    if (current !== undefined && current.state === 'pending') return;
    if (!this.state.ready) { this.commandStatus(key, { state: 'error', message: 'Waiting for a live controller snapshot. No command was sent.' }); return; }
    const request_id = this.runtime.nonce();
    const timer = this.runtime.later(() => {
      this.pendingCommands.delete(request_id);
      this.commandStatus(key, { state: 'error', message: 'No acknowledgement. Check the reported state before trying again.' });
    }, COMMAND_TIMEOUT_MS);
    this.pendingCommands.set(request_id, { key, timer });
    this.commandStatus(key, { state: 'pending', message: 'Sending command…', command, confirmed: false });
    try { this.connection.send({ type: 'Command', request_id, command }); }
    catch (error) {
      this.runtime.cancel(timer);
      this.pendingCommands.delete(request_id);
      this.commandStatus(key, { state: 'error', message: error instanceof Error ? error.message : 'Sending failed' });
    }
  }

  loadHistory(device: string): void {
    if (this.destroyed || !this.state.ready) return;
    if (this.historyQueue.includes(device) || [...this.pendingHistories.values()].some(request => request.device === device)) return;
    const existing = this.state.histories.get(device);
    this.historyStatus(device, { loading: true, data: existing === undefined ? null : existing.data, error: null });
    this.historyQueue.push(device);
    this.pumpHistory();
  }

  private publish(update: Partial<DashboardState>): void {
    if (this.destroyed) return;
    this.state = { ...this.state, ...update };
    for (const listener of this.subscribers) listener();
  }

  private healthChanged(health: Health): void {
    const alive = health.connections.some(connection => connection.id === health.activeId && connection.state === 'ALIVE');
    if (!alive) {
      for (const [request, pending] of this.pendingCommands) {
        this.runtime.cancel(pending.timer);
        this.pendingCommands.delete(request);
        this.commandStatus(pending.key, { state: 'error', message: 'Connection interrupted. The command outcome is unknown; check reported state after reconnecting.' });
      }
      for (const pending of this.pendingHistories.values()) {
        this.runtime.cancel(pending.timer);
        const existing = this.state.histories.get(pending.device);
        this.historyStatus(pending.device, { loading: false, data: existing === undefined ? null : existing.data, error: 'History will refresh when the connection recovers.' });
      }
      this.pendingHistories.clear();
      for (const device of this.historyQueue) {
        const existing = this.state.histories.get(device);
        this.historyStatus(device, { loading: false, data: existing === undefined ? null : existing.data, error: 'Waiting for connection' });
      }
      this.historyQueue = [];
    }
    this.publish({ health, ready: alive && this.state.ready });
  }

  private resync(): void {
    this.publish({ ready: false });
    try { this.connection.send({ type: 'GetState' }); }
    catch { /* The connection manager exposes the failure and schedules recovery. */ }
  }

  private commandStatus(key: string, status: CommandStatus | undefined): void {
    const commands = new Map(this.state.commands);
    if (status === undefined) commands.delete(key);
    else commands.set(key, status);
    this.publish({ commands });
  }

  // Only subsequent entity updates can confirm a submitted command; cached
  // confirmation may belong to a previous request for the same target.
  private confirmTargets(rooms: Room[], plugs: Plug[]): ReadonlyMap<string, CommandStatus> {
    const commands = new Map(this.state.commands);
    for (const [key, status] of commands) {
      if (status.state === 'error') continue;
      const command = status.command;
      let confirmed: boolean;
      if (command.kind === 'SetPlugPower') {
        const plug = plugs.find(plug => plug.device === command.device);
        if (plug === undefined) continue;
        confirmed = plug.target != null && plug.target.phase === 'confirmed'
          && plug.target_value === (command.on ? 'on' : 'off');
      } else {
        const room = rooms.find(room => room.name === command.room);
        if (room === undefined) continue;
        const target = room.target_value;
        confirmed = room.target != null && room.target.phase === 'confirmed' && target != null
          && (command.kind === 'SetRoomOff' ? target.kind === 'off'
            : target.kind === 'on' && target.scene_id === command.scene_id);
      }
      if (status.state === 'accepted' && confirmed) commands.delete(key);
      else if (confirmed !== status.confirmed) commands.set(key, { ...status, confirmed });
    }
    return commands;
  }

  private historyStatus(device: string, status: HistoryStatus): void {
    const histories = new Map(this.state.histories);
    histories.set(device, status);
    this.publish({ histories });
  }

  private pumpHistory(): void {
    while (this.state.ready && this.pendingHistories.size < HISTORY_CONCURRENCY && this.historyQueue.length > 0) {
      const device = this.historyQueue.shift();
      if (device === undefined) throw new Error('History queue invariant violated');
      const request_id = this.runtime.nonce();
      const timer = this.runtime.later(() => {
        this.pendingHistories.delete(request_id);
        const existing = this.state.histories.get(device);
        this.historyStatus(device, { loading: false, data: existing === undefined ? null : existing.data, error: 'History request timed out. Try again.' });
        this.pumpHistory();
      }, HISTORY_TIMEOUT_MS);
      this.pendingHistories.set(request_id, { device, timer });
      try { this.connection.send({ type: 'GetValveHistory', request_id, device }); }
      catch {
        this.runtime.cancel(timer);
        this.pendingHistories.delete(request_id);
        const existing = this.state.histories.get(device);
        this.historyStatus(device, { loading: false, data: existing === undefined ? null : existing.data, error: 'Could not request history. Try again when connected.' });
      }
    }
  }

  private receive(message: ServerMessage): void {
    const receivedAt = this.runtime.now();
    switch (message.type) {
      case 'StateSnapshot':
        this.publish({
          ready: true, receivedAt,
          rooms: message.rooms.map(value => ({ value, receivedAt })), plugs: message.plugs.map(value => ({ value, receivedAt })),
          lights: message.lights.map(value => ({ value, receivedAt })), heating: message.heating_zones.map(value => ({ value, receivedAt })),
          commands: this.confirmTargets(message.rooms, message.plugs),
        });
        break;
      case 'Entity':
        if (!this.state.ready) break;
        switch (message.kind) {
          case 'Room': this.publish({ rooms: replace(this.state.rooms, message.data, receivedAt, room => room.name), commands: this.confirmTargets([message.data], []) }); break;
          case 'Plug': this.publish({ plugs: replace(this.state.plugs, message.data, receivedAt, plug => plug.device), commands: this.confirmTargets([], [message.data]) }); break;
          case 'Light': this.publish({ lights: replace(this.state.lights, message.data, receivedAt, light => light.device) }); break;
          case 'HeatingZone': this.publish({ heating: replace(this.state.heating, message.data, receivedAt, zone => zone.name) }); break;
        }
        break;
      case 'CommandResult': {
        const pending = this.pendingCommands.get(message.request_id);
        if (pending === undefined) break;
        this.runtime.cancel(pending.timer);
        this.pendingCommands.delete(message.request_id);
        const status = this.state.commands.get(pending.key);
        if (status === undefined || status.state !== 'pending') throw new Error('Pending command status invariant violated');
        this.commandStatus(pending.key, message.error === null
          ? status.confirmed ? undefined : { ...status, state: 'accepted', message: 'Command accepted. Reported state updates when the device responds.' }
          : { state: 'error', message: message.error });
        break;
      }
      case 'ValveHistory': {
        const pending = this.pendingHistories.get(message.request_id);
        if (pending === undefined || pending.device !== message.device) break;
        this.runtime.cancel(pending.timer);
        this.pendingHistories.delete(message.request_id);
        this.historyStatus(message.device, { loading: false, data: message, error: message.error });
        this.pumpHistory();
        break;
      }
      case 'Pong': case 'EventLog': case 'EntityLog': case 'Topology': break;
    }
  }
}

function replace<T>(items: Timed<T>[], value: T, receivedAt: number, key: (value: T) => string): Timed<T>[] {
  const index = items.findIndex(item => key(item.value) === key(value));
  const next = [...items];
  if (index < 0) next.push({ value, receivedAt });
  else next[index] = { value, receivedAt };
  return next;
}
