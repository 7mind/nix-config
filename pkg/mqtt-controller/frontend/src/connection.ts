import { serverSchema, type ClientMessage, type ServerMessage } from './protocol';

export type ConnectionState = 'NEW' | 'ALIVE' | 'STALE' | 'DEAD';
export interface Transport {
  readonly readyState: number;
  send(message: string): void;
  close(code: number, reason: string): void;
  listen(handlers: { open(): void; message(data: string): void; close(code: number, reason: string): void; error(): void }): void;
}
export interface Runtime {
  now(): number;
  nonce(): string;
  random(): number;
  visible(): boolean;
  socket(): Transport;
  later(callback: () => void, delay: number): number;
  cancel(timer: number): void;
}
export const CONNECTION_POLICY = {
  connectMs: 10_000, pingMs: 10_000, pongMs: 3_000, graceMs: 10_000,
  retryBaseMs: 1_000, retryCapMs: 30_000, maxAttempts: 15, poolSize: 3,
  deadRetentionMs: 5_000, tickMs: 1_000, pauseThresholdMs: 500,
} as const;
const CONNECTING = 0;
const OPEN = 1;
const PERMANENT_CODES = new Set([1002, 1003, 1007, 1009, 1010, 1015, 4002]);

interface PendingPing { sentAt: number; timer: number; expired: boolean }
interface Connection {
  id: string; socket: Transport; state: ConnectionState; createdAt: number;
  stateAt: number; deadline: number | null; timers: Set<number>; pings: Map<string, PendingPing>;
  lastRtt: number | null; lastPong: number | null;
}
export interface ConnectionInfo {
  id: string; state: ConnectionState; createdAt: number; stateAt: number; deadline: number | null;
  pendingPings: number; lastRtt: number | null; lastPong: number | null;
}
export interface Health {
  connections: ConnectionInfo[]; activeId: string | null; attempt: number; maxAttempts: number;
  retryAt: number | null; retryStartedAt: number | null; deferred: boolean; terminal: boolean;
  frozen: boolean; offline: boolean; lastClose: { code: number; reason: string } | null;
  sent: number; received: number; timedOut: number; rtts: { at: number; ms: number }[];
}

export class ConnectionManager {
  private readonly connections = new Map<string, Connection>();
  private activeId: string | null = null;
  private attempts = 0;
  private terminal = false;
  private deferred = false;
  private frozen = false;
  private offline = false;
  private suspended = false;
  private destroyed = false;
  private retryTimer: number | null = null;
  private retryAt: number | null = null;
  private retryStartedAt: number | null = null;
  private tickTimer: number | null = null;
  private lastTick: number;
  private lastClose: Health['lastClose'] = null;
  private sent = 0;
  private received = 0;
  private timedOut = 0;
  private rtts: Health['rtts'] = [];

  constructor(
    private readonly runtime: Runtime,
    private readonly onHealth: (health: Health) => void,
    private readonly onMessage: (message: ServerMessage) => void,
    private readonly onActive: (id: string) => void,
  ) { this.lastTick = runtime.now(); }

  start(): void {
    if (this.destroyed || this.tickTimer !== null) return;
    this.tick();
    this.connect();
  }

  stats(): Health {
    return {
      connections: [...this.connections.values()].map(connection => ({
        id: connection.id, state: connection.state, createdAt: connection.createdAt, stateAt: connection.stateAt,
        deadline: connection.deadline, pendingPings: connection.pings.size, lastRtt: connection.lastRtt, lastPong: connection.lastPong,
      })), activeId: this.activeId, attempt: this.attempts, maxAttempts: CONNECTION_POLICY.maxAttempts,
      retryAt: this.retryAt, retryStartedAt: this.retryStartedAt, deferred: this.deferred, terminal: this.terminal,
      frozen: this.frozen, offline: this.offline, lastClose: this.lastClose,
      sent: this.sent, received: this.received, timedOut: this.timedOut, rtts: [...this.rtts],
    };
  }

  send(message: ClientMessage): void {
    const connection = this.activeId === null ? undefined : this.connections.get(this.activeId);
    if (connection === undefined || connection.state !== 'ALIVE' || connection.socket.readyState !== OPEN || this.destroyed) {
      throw new Error('The controller connection is not ready. No command was sent.');
    }
    try { connection.socket.send(JSON.stringify(message)); }
    catch {
      this.die(connection, 1006, 'Send failed');
      throw new Error('Sending failed. Check the reported device state before trying again.');
    }
  }

  retry(): void {
    if (this.destroyed) return;
    this.cancelRetry();
    this.terminal = false;
    this.attempts = 0;
    this.activeId = null;
    for (const connection of this.connections.values()) this.retire(connection, 'Manual reconnect');
    this.connect();
  }

  visibilityChanged(): void {
    if (this.destroyed || this.terminal || this.suspended) return;
    if (this.runtime.visible()) {
      if (this.deferred) { this.deferred = false; this.connect(); }
      this.check();
    }
    this.emit();
  }

  networkChanged(offline: boolean): void {
    this.offline = offline;
    if (!offline) this.check();
    this.emit();
  }

  freeze(): void { this.frozen = true; this.emit(); }
  resume(gapMs: number): void {
    if (this.destroyed || this.terminal || this.suspended) return;
    this.frozen = false;
    if (gapMs >= CONNECTION_POLICY.pongMs) {
      const active = this.activeId === null ? undefined : this.connections.get(this.activeId);
      if (active !== undefined) this.markStale(active);
      this.connect();
    }
    this.check();
  }

  pageHide(): void {
    if (this.destroyed) return;
    this.suspended = true;
    this.frozen = true;
    this.activeId = null;
    this.cancelRetry();
    for (const connection of this.connections.values()) this.retire(connection, 'Page suspended');
    this.emit();
  }

  pageShow(): void {
    if (this.destroyed) return;
    this.suspended = false;
    this.frozen = false;
    this.lastTick = this.runtime.now();
    if (!this.terminal) this.connect();
  }

  destroy(): void {
    this.destroyed = true;
    this.cancelRetry();
    if (this.tickTimer !== null) this.runtime.cancel(this.tickTimer);
    this.activeId = null;
    for (const connection of this.connections.values()) this.retire(connection, 'Dashboard closed');
    this.connections.clear();
    this.cancelRetry();
  }

  private emit(): void { if (!this.destroyed) this.onHealth(this.stats()); }

  private connect(): void {
    if (this.destroyed || this.terminal || this.suspended) return;
    if (!this.runtime.visible()) { this.deferred = true; this.emit(); return; }
    const live = [...this.connections.values()].filter(connection => connection.state !== 'DEAD');
    if (live.some(connection => connection.state === 'NEW') || live.length >= CONNECTION_POLICY.poolSize) return;
    if (live.some(connection => connection.state === 'ALIVE')) return;
    if (this.attempts >= CONNECTION_POLICY.maxAttempts) { this.terminal = true; this.emit(); return; }
    this.cancelRetry();
    this.deferred = false;
    this.attempts++;
    let socket: Transport;
    try { socket = this.runtime.socket(); }
    catch { this.lastClose = { code: 1006, reason: 'Could not open a connection' }; this.scheduleRetry(); return; }
    const now = this.runtime.now();
    const connection: Connection = {
      id: this.runtime.nonce(), socket, state: 'NEW', createdAt: now, stateAt: now,
      deadline: now + CONNECTION_POLICY.connectMs, timers: new Set(), pings: new Map(), lastRtt: null, lastPong: null,
    };
    this.connections.set(connection.id, connection);
    this.timer(connection, CONNECTION_POLICY.connectMs, () => {
      if (connection.state === 'NEW' && socket.readyState === CONNECTING) this.die(connection, 1006, 'Connection timed out');
    });
    socket.listen({
      open: () => {
        if (connection.state === 'DEAD' || this.destroyed) return;
        connection.deadline = this.runtime.now() + CONNECTION_POLICY.pongMs;
        this.ping(connection);
        this.emit();
      },
      message: data => this.receive(connection, data),
      close: (code, reason) => this.die(connection, code, reason || 'Connection closed'),
      error: () => this.die(connection, 1006, 'Network error'),
    });
    this.emit();
  }

  private timer(connection: Connection, delay: number, callback: () => void): number {
    const timer = this.runtime.later(() => {
      connection.timers.delete(timer);
      if (!this.destroyed && connection.state !== 'DEAD') callback();
    }, delay);
    connection.timers.add(timer);
    return timer;
  }

  private ping(connection: Connection): void {
    if (connection.state === 'DEAD' || connection.socket.readyState !== OPEN || this.destroyed) return;
    if ([...connection.pings.values()].some(ping => !ping.expired)) return;
    const nonce = this.runtime.nonce();
    const sentAt = this.runtime.now();
    const timer = this.timer(connection, CONNECTION_POLICY.pongMs, () => {
      const pending = connection.pings.get(nonce);
      if (pending === undefined) return;
      pending.expired = true;
      this.timedOut++;
      if (connection.state === 'NEW') this.die(connection, 1006, 'Handshake heartbeat timed out');
      else this.markStale(connection);
    });
    connection.pings.set(nonce, { sentAt, timer, expired: false });
    if (connection.state !== 'STALE') connection.deadline = sentAt + CONNECTION_POLICY.pongMs;
    this.sent++;
    try { connection.socket.send(JSON.stringify({ type: 'Ping', nonce, client_ts_ms: sentAt })); }
    catch { this.die(connection, 1006, 'Heartbeat send failed'); }
  }

  private receive(connection: Connection, data: string): void {
    if (this.destroyed || connection.state === 'DEAD') return;
    let message: ServerMessage;
    try { message = serverSchema.parse(JSON.parse(data)); }
    catch { this.die(connection, 4002, 'Unexpected server data. Reload after updating the dashboard.'); return; }
    if (message.type === 'Pong') {
      const ping = connection.pings.get(message.nonce);
      if (ping === undefined || ping.sentAt !== message.client_ts_ms) return;
      this.runtime.cancel(ping.timer);
      connection.timers.delete(ping.timer);
      connection.pings.delete(message.nonce);
      for (const [nonce, pending] of connection.pings) {
        if (pending.expired) connection.pings.delete(nonce);
      }
      const now = this.runtime.now();
      connection.lastRtt = Math.max(0, now - ping.sentAt);
      connection.lastPong = now;
      this.received++;
      this.rtts.push({ at: now, ms: connection.lastRtt });
      this.rtts = this.rtts.filter(sample => sample.at >= now - 300_000).slice(-300);
      const wasAlive = connection.state === 'ALIVE';
      connection.state = 'ALIVE';
      if (!wasAlive) connection.stateAt = now;
      connection.deadline = now + CONNECTION_POLICY.pingMs;
      this.attempts = 0;
      this.cancelRetry();
      this.deferred = false;
      if (this.activeId !== connection.id || !wasAlive) {
        const current = this.activeId === null ? undefined : this.connections.get(this.activeId);
        if (current !== undefined && current !== connection && current.state === 'ALIVE') {
          this.retire(connection, 'Another connection is healthy');
        } else {
          this.activeId = connection.id;
          for (const other of this.connections.values()) if (other !== connection) this.retire(other, 'Superseded');
          this.emit();
          this.onActive(connection.id);
        }
      }
      this.emit();
    } else if (connection.id === this.activeId && connection.state === 'ALIVE') {
      this.onMessage(message);
    }
  }

  private markStale(connection: Connection): void {
    if (this.destroyed || connection.state === 'DEAD' || connection.state === 'STALE') return;
    connection.state = 'STALE';
    connection.stateAt = this.runtime.now();
    connection.deadline = connection.stateAt + CONNECTION_POLICY.graceMs;
    const deadline = connection.deadline;
    this.timer(connection, CONNECTION_POLICY.graceMs, () => {
      if (connection.state === 'STALE' && connection.deadline === deadline) this.die(connection, 1006, 'No heartbeat reply');
    });
    this.emit();
    this.connect();
  }

  private retire(connection: Connection, reason: string): void {
    if (connection.state === 'DEAD') return;
    connection.state = 'DEAD';
    connection.stateAt = this.runtime.now();
    connection.deadline = null;
    for (const timer of connection.timers) this.runtime.cancel(timer);
    connection.timers.clear();
    connection.pings.clear();
    try { connection.socket.close(1000, reason); } catch { /* The native socket may already be gone. */ }
  }

  private die(connection: Connection, code: number, reason: string): void {
    if (this.destroyed || connection.state === 'DEAD') return;
    this.lastClose = { code, reason };
    if (this.activeId === connection.id) this.activeId = null;
    this.retire(connection, reason);
    if (PERMANENT_CODES.has(code)) {
      this.terminal = true;
      this.activeId = null;
      this.cancelRetry();
      for (const other of this.connections.values()) this.retire(other, 'Connection stopped');
    } else if (![...this.connections.values()].some(other => other.state === 'ALIVE' || other.state === 'NEW')) {
      this.scheduleRetry();
    }
    this.emit();
  }

  private scheduleRetry(): void {
    if (this.destroyed || this.suspended || this.terminal || this.retryTimer !== null) return;
    if (this.attempts >= CONNECTION_POLICY.maxAttempts) { this.terminal = true; this.emit(); return; }
    if (!this.runtime.visible()) { this.deferred = true; this.emit(); return; }
    const delay = Math.min(CONNECTION_POLICY.retryCapMs, CONNECTION_POLICY.retryBaseMs * 2 ** Math.max(0, this.attempts - 1))
      * (0.5 + this.runtime.random() * 0.5);
    this.retryStartedAt = this.runtime.now();
    this.retryAt = this.retryStartedAt + delay;
    this.retryTimer = this.runtime.later(() => {
      this.retryTimer = null;
      this.retryAt = null;
      this.retryStartedAt = null;
      this.connect();
    }, delay);
    this.emit();
  }

  private cancelRetry(): void {
    if (this.retryTimer !== null) this.runtime.cancel(this.retryTimer);
    this.retryTimer = null;
    this.retryAt = null;
    this.retryStartedAt = null;
  }

  private check(): void {
    if (this.destroyed || this.terminal || this.suspended) return;
    for (const connection of this.connections.values()) this.ping(connection);
    if (this.retryTimer === null) this.connect();
    this.emit();
  }

  private tick(): void {
    if (this.destroyed) return;
    const now = this.runtime.now();
    const elapsed = now - this.lastTick;
    this.lastTick = now;
    if (elapsed > CONNECTION_POLICY.tickMs + CONNECTION_POLICY.pauseThresholdMs) this.resume(elapsed);
    for (const [id, connection] of this.connections) {
      if (connection.state === 'DEAD' && now - connection.stateAt >= CONNECTION_POLICY.deadRetentionMs) this.connections.delete(id);
      if (connection.state === 'ALIVE' && connection.lastPong !== null && now - connection.lastPong >= CONNECTION_POLICY.pingMs) this.ping(connection);
    }
    this.emit();
    this.tickTimer = this.runtime.later(() => this.tick(), CONNECTION_POLICY.tickMs);
  }
}

export function browserRuntime(url: string, window: Window, document: Document): Runtime {
  return {
    now: () => Date.now(), random: () => Math.random(), visible: () => document.visibilityState === 'visible',
    nonce: () => Array.from(crypto.getRandomValues(new Uint8Array(12)), byte => byte.toString(16).padStart(2, '0')).join(''),
    later: (callback, delay) => window.setTimeout(callback, delay), cancel: timer => window.clearTimeout(timer),
    socket: () => {
      const socket = new WebSocket(url);
      return {
        get readyState() { return socket.readyState; },
        send: message => socket.send(message), close: (code, reason) => socket.close(code, reason),
        listen: handlers => {
          socket.onopen = () => handlers.open();
          socket.onmessage = event => handlers.message(String(event.data));
          socket.onclose = event => handlers.close(event.code, event.reason);
          socket.onerror = () => handlers.error();
        },
      };
    },
  };
}

export function bindLifecycle(manager: ConnectionManager, window: Window, document: Document, navigator: Navigator): () => void {
  const cleanup: (() => void)[] = [];
  const listen = (target: EventTarget, event: string, handler: EventListener) => {
    target.addEventListener(event, handler);
    cleanup.push(() => target.removeEventListener(event, handler));
  };
  listen(document, 'visibilitychange', () => manager.visibilityChanged());
  listen(document, 'freeze', () => manager.freeze());
  listen(document, 'resume', () => manager.resume(Infinity));
  listen(window, 'pagehide', () => manager.pageHide());
  listen(window, 'pageshow', event => { if ((event as PageTransitionEvent).persisted) manager.pageShow(); });
  listen(window, 'online', () => manager.networkChanged(false));
  listen(window, 'offline', () => manager.networkChanged(true));
  const network = (navigator as Navigator & { connection?: EventTarget }).connection;
  if (network !== undefined) listen(network, 'change', () => manager.networkChanged(false));
  return () => { for (const remove of cleanup) remove(); };
}
