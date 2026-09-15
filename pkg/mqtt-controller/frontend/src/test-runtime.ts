import type { Runtime, Transport } from './connection';
import type { ClientMessage } from './protocol';

export class TestSocket implements Transport {
  readyState = 0;
  readonly sent: ClientMessage[] = [];
  private handlers!: Parameters<Transport['listen']>[0];
  listen(handlers: Parameters<Transport['listen']>[0]): void { this.handlers = handlers; }
  send(message: string): void {
    if (this.readyState !== 1) throw new Error('Socket is closed');
    this.sent.push(JSON.parse(message) as ClientMessage);
  }
  close(code: number, reason: string): void { this.readyState = 3; this.handlers.close(code, reason); }
  open(): void { this.readyState = 1; this.handlers.open(); }
  receive(message: unknown): void { this.handlers.message(JSON.stringify(message)); }
  lastPing(): Extract<ClientMessage, { type: 'Ping' }> {
    const ping = [...this.sent].reverse().find(message => message.type === 'Ping');
    if (ping === undefined || ping.type !== 'Ping') throw new Error('No heartbeat sent');
    return ping;
  }
  pong(): void {
    const ping = this.lastPing();
    this.receive({ type: 'Pong', nonce: ping.nonce, client_ts_ms: ping.client_ts_ms, server_ts_ms: ping.client_ts_ms });
  }
}

export class TestRuntime implements Runtime {
  private time = 1_700_000_000_000;
  private sequence = 0;
  private timerSequence = 0;
  readonly timers = new Map<number, { at: number; callback: () => void }>();
  readonly sockets: TestSocket[] = [];
  isVisible = true;
  now(): number { return this.time; }
  random(): number { return 0; }
  nonce(): string { return `nonce-${++this.sequence}`; }
  visible(): boolean { return this.isVisible; }
  socket(): TestSocket { const socket = new TestSocket(); this.sockets.push(socket); return socket; }
  later(callback: () => void, delay: number): number {
    const id = ++this.timerSequence;
    this.timers.set(id, { at: this.time + delay, callback });
    return id;
  }
  cancel(timer: number): void { this.timers.delete(timer); }
  advance(milliseconds: number): void {
    const end = this.time + milliseconds;
    let executed = 0;
    while (true) {
      const next = [...this.timers.entries()].filter(([, timer]) => timer.at <= end).sort((a, b) => a[1].at - b[1].at)[0];
      if (next === undefined) break;
      if (++executed > 100_000) throw new Error('Timer loop did not converge');
      this.time = Math.max(this.time, next[1].at);
      this.timers.delete(next[0]);
      next[1].callback();
    }
    this.time = end;
  }
  jump(milliseconds: number): void { this.time += milliseconds; this.advance(0); }
  latest(): TestSocket {
    const socket = this.sockets.at(-1);
    if (socket === undefined) throw new Error('No socket created');
    return socket;
  }
}
