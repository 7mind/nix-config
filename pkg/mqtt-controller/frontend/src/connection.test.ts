import { describe, expect, it } from 'vitest';
import { CONNECTION_POLICY, ConnectionManager } from './connection';
import { TestRuntime } from './test-runtime';
import type { ServerMessage } from './protocol';

function setup() {
  const runtime = new TestRuntime();
  const messages: ServerMessage[] = [];
  const active: string[] = [];
  const manager = new ConnectionManager(runtime, () => {}, message => messages.push(message), id => active.push(id));
  manager.start();
  return { runtime, manager, messages, active };
}

describe('connection recovery', () => {
  it('requires a matching heartbeat before allowing commands', () => {
    const { runtime, manager } = setup();
    const socket = runtime.latest(); socket.open();
    expect(manager.stats().connections[0]!.state).toBe('NEW');
    expect(() => manager.send({ type: 'GetState' })).toThrow('not ready');
    socket.receive({ type: 'Pong', nonce: 'wrong', client_ts_ms: runtime.now(), server_ts_ms: runtime.now() });
    expect(manager.stats().activeId).toBeNull();
    socket.pong();
    manager.send({ type: 'GetState' });
    expect(socket.sent.at(-1)).toEqual({ type: 'GetState' });
    manager.destroy();
  });
  it('replaces a stale connection immediately and ignores superseded data', () => {
    const { runtime, manager, messages } = setup();
    const old = runtime.latest(); old.open(); old.pong();
    runtime.advance(CONNECTION_POLICY.pingMs + CONNECTION_POLICY.pongMs);
    expect(runtime.sockets).toHaveLength(2);
    expect(manager.stats().connections[0]!.state).toBe('STALE');
    const replacement = runtime.latest(); replacement.open(); replacement.pong();
    expect(old.readyState).toBe(3);
    old.receive({ type: 'CommandResult', request_id: 'old', error: null });
    replacement.receive({ type: 'CommandResult', request_id: 'new', error: null });
    expect(messages).toEqual([{ type: 'CommandResult', request_id: 'new', error: null }]);
    manager.destroy();
  });
  it('lets a late matching pong recover within grace and closes the extra socket', () => {
    const { runtime, manager, active } = setup();
    const old = runtime.latest(); old.open(); old.pong();
    runtime.advance(CONNECTION_POLICY.pingMs + CONNECTION_POLICY.pongMs);
    const replacement = runtime.latest();
    old.pong();
    expect(replacement.readyState).toBe(3);
    expect(manager.stats().activeId).toBe(active[0]);
    expect(active).toHaveLength(2);
    manager.destroy();
  });
  it('a previous grace timer cannot terminate a later stale episode', () => {
    const { runtime, manager } = setup();
    const old = runtime.latest(); old.open(); old.pong();
    runtime.advance(13_000);
    runtime.advance(1_000); old.pong();
    runtime.advance(1_000); manager.resume(1);
    runtime.advance(3_000);
    runtime.advance(5_000);
    expect(manager.stats().activeId, 'the previous grace deadline must not clear the active connection').not.toBeNull();
    expect(manager.stats().connections.find(connection => connection.id === manager.stats().activeId)!.state).toBe('STALE');
    manager.destroy();
  });
  it('expires the first heartbeat as a failed handshake', () => {
    const { runtime, manager } = setup();
    runtime.latest().open();
    runtime.advance(CONNECTION_POLICY.pongMs);
    expect(runtime.latest().readyState).toBe(3);
    expect(manager.stats().retryAt).not.toBeNull();
    manager.destroy();
  });
  it('does not retain timed-out pings after a newer exchange proves recovery', () => {
    const { runtime, manager } = setup();
    const old = runtime.latest(); old.open(); old.pong();
    runtime.advance(CONNECTION_POLICY.pingMs + CONNECTION_POLICY.pongMs);
    manager.resume(1);
    old.pong();
    expect(manager.stats().connections[0]!.pendingPings).toBe(0);
    manager.destroy();
  });
  it('updates the visible budget while waiting for a pong', () => {
    const { runtime, manager } = setup();
    runtime.latest().open(); runtime.latest().pong();
    runtime.advance(CONNECTION_POLICY.pingMs);
    expect(manager.stats().connections[0]!.deadline).toBe(runtime.now() + CONNECTION_POLICY.pongMs);
    manager.destroy();
  });
  it('detects an event-loop pause without waiting for the native close event', () => {
    const { runtime, manager } = setup();
    runtime.latest().open(); runtime.latest().pong();
    runtime.jump(20_000);
    expect(runtime.sockets.length).toBe(2);
    expect(manager.stats().connections.filter(connection => connection.state !== 'DEAD').length).toBeLessThanOrEqual(CONNECTION_POLICY.poolSize);
    manager.destroy();
  });
  it('defers hidden reconnects without using attempts and retries immediately on visibility', () => {
    const { runtime, manager } = setup();
    runtime.isVisible = false;
    runtime.latest().close(1006, 'lost');
    const attempt = manager.stats().attempt;
    runtime.advance(90_000);
    expect(runtime.sockets).toHaveLength(1);
    expect(manager.stats().attempt).toBe(attempt);
    runtime.isVisible = true; manager.visibilityChanged();
    expect(runtime.sockets).toHaveLength(2);
    manager.destroy();
  });
  it('honors the retry ceiling and permanent close codes until a manual retry', () => {
    const { runtime, manager } = setup();
    for (let attempt = 0; attempt < CONNECTION_POLICY.maxAttempts; attempt++) {
      runtime.latest().close(1006, 'unavailable');
      runtime.advance(CONNECTION_POLICY.retryCapMs);
    }
    expect(runtime.sockets).toHaveLength(CONNECTION_POLICY.maxAttempts);
    expect(manager.stats().terminal).toBe(true);
    manager.networkChanged(false); manager.resume(Infinity); manager.visibilityChanged();
    expect(runtime.sockets).toHaveLength(CONNECTION_POLICY.maxAttempts);
    manager.retry();
    expect(runtime.sockets).toHaveLength(CONNECTION_POLICY.maxAttempts + 1);
    runtime.latest().close(1002, 'protocol mismatch');
    runtime.advance(100_000);
    expect(manager.stats().terminal).toBe(true);
    manager.destroy();
  });
  it('closes for page suspension and restores a fresh connection', () => {
    const { runtime, manager } = setup();
    runtime.latest().open(); runtime.latest().pong();
    manager.pageHide(); runtime.advance(60_000);
    expect(runtime.sockets).toHaveLength(1);
    expect(runtime.latest().readyState).toBe(3);
    manager.pageShow();
    expect(runtime.sockets).toHaveLength(2);
    manager.destroy();
  });
  it('checks native readyState before timing out a handshake', () => {
    const { runtime, manager } = setup();
    runtime.latest().readyState = 1;
    runtime.advance(CONNECTION_POLICY.connectMs);
    expect(runtime.latest().readyState).toBe(1);
    runtime.latest().open(); runtime.latest().pong();
    expect(manager.stats().connections[0]!.state).toBe('ALIVE');
    manager.destroy();
  });
  it('cannot schedule work during or after destruction', () => {
    const { runtime, manager } = setup();
    manager.destroy();
    expect(runtime.timers.size).toBe(0);
    runtime.advance(100_000); manager.retry(); manager.resume(Infinity);
    expect(runtime.sockets).toHaveLength(1);
    expect(runtime.timers.size).toBe(0);
  });
});
