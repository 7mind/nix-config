# Resilient WebSocket connections + visible connection health

> **Reference implementation:** https://github.com/pshirshov/ws-reconnect-demo
>
> File paths in this skill (`src/client/connection.ts`, `src/client/manager.ts`,
> `src/client/ui.ts`, `src/server.ts`) refer to that repository. Consult it for
> concrete, working code that exercises every pattern described below.

Agent guidelines for two coupled problems:

1. **Reliability** — keep a logical channel to the backend open across page freezes, IP changes, NAT/proxy timeouts, browser bugs, and flaky networks, *without* relying on the transport's own `close` event.
2. **Visibility** — give the user a compact, always-on, truthful indication of connection health, plus a drill-down when they want detail.

The guidance is stack-agnostic. Concrete examples are drawn from the reference implementation (`src/client/`, `src/server.ts`) — TypeScript + browser `WebSocket` + Node `ws`, but the patterns transfer to other runtimes (native apps, mobile, SSE, long-polling, gRPC streaming).

---

## Part 1 — Reliability

### R1. Do not trust transport-level liveness

`WebSocket.readyState === OPEN` does **not** mean the peer is reachable. Common failure modes where the browser never fires `close`:

- Firefox stale WebSocket bug ([bugzilla 920074](https://bugzilla.mozilla.org/show_bug.cgi?id=920074)) — no TCP keepalives on WS; idle NAT drops are silent.
- Mobile page freeze — tab is frozen, TCP connection is reaped server-side, `readyState` stays `OPEN` until you try to use it.
- IP change (Wi-Fi ↔ cellular, VPN toggle) — old 4-tuple is dead; no close event on the client.
- Intermediate proxy idle timeout (Nginx 60s, Cloudflare 100s, cellular NAT 30s) — silent drop.

**Rule:** Liveness is established by application-level heartbeat, not by the transport. Everything else in this skill follows from that.

### R2. State machine, not a boolean

Model each connection with at least four states. Binary "connected/disconnected" is too coarse to drive either recovery logic or UI.

```
NEW ──→ ALIVE ──→ STALE ──→ DEAD
  │              ↑       │
  │              └───────┘  (recovery: matching pong arrives in grace)
  └──────────────────────→ DEAD
```

| State   | Meaning                                                                                  |
|---------|------------------------------------------------------------------------------------------|
| `NEW`   | Handshake in progress.                                                                   |
| `ALIVE` | Open + recent matching pong.                                                             |
| `STALE` | A heartbeat timed out. May recover within a grace period.                                |
| `DEAD`  | Terminal. Kept visible briefly for the UI, then evicted.                                 |

Reference: `src/client/connection.ts` — `ConnectionState`, `transitionTo`. `STALE` is a first-class state with its own grace period (not just a transient moment inside `ALIVE → DEAD`), which is what enables overlapping-connection failover (R6).

### R3. Per-request heartbeat with nonces

Do not heartbeat by checking "has there been any message in the last N seconds." That pattern misses the case where the server is alive but the *specific exchange* you care about is stuck.

- Each heartbeat carries a random nonce (UUID v4 or 8 random bytes) and a client timestamp.
- The peer echoes both and adds its own timestamp.
- A per-nonce timeout fires after `pongTimeoutMs`; if the matching pong is not back, mark **that connection** `STALE`.
- RTT = `now - clientTs` at the moment the matching pong arrives.

Reference: `src/client/connection.ts:148` (`sendPing`) and `src/client/connection.ts:224` (`handleMessage`) — pending pings are kept in a `Map<nonce, sentAt>` and resolved individually.

On the server side, do the same thing with protocol-level pings — see R11.

### R4. Connect timeout

A hanging TCP/TLS handshake (captive portal, SYN blackhole, upstream LB overload) will leave the socket in `CONNECTING` **indefinitely**. The platform will not time it out for you on a useful timescale.

Arm a timer at construction. When it fires, check *both* the wrapper state and the native `readyState` before aborting — you can race the platform's `open` event and abort a socket that just came up.

Reference: `src/client/connection.ts:103`:

```ts
this.connectTimeoutId = setTimeout(() => {
  if (this.state === ConnectionState.NEW && this.ws.readyState === WebSocket.CONNECTING) {
    this.close(`connect timeout after ${config.connectTimeoutMs}ms`);
  }
}, config.connectTimeoutMs);
```

### R5. Exponential backoff with jitter, cap, and ceiling

Naïve reconnect loops cause thundering-herd spikes after a server restart and are also a good way to get your IP rate-limited. Always:

- Base delay (e.g. 1s), doubling per attempt.
- Cap the per-attempt delay (e.g. 30s).
- **Full jitter**: `delay = cap_or_computed × random(0.5, 1.0)` (not just ±20%).
- Maximum total attempts before giving up (e.g. 15), then stop and expose a manual "try again" affordance. Infinite retry loops burn battery and trick users into thinking "it's trying" when the backend is gone.
- Reset the counter to 0 the moment any connection reaches `ALIVE`.

Reference: `src/client/manager.ts:265` (`getBackoffDelay`).

### R6. Overlapping connections during `STALE` grace

When the active connection goes `STALE`, do **not** wait for it to resolve before starting a replacement. Instead:

1. Create a replacement immediately.
2. Let the old connection keep running through its grace period (`staleGracePeriodMs`).
3. If a late pong arrives on the old connection → promote/retain one, close the other as "superseded."
4. If the old one hits `DEAD` first → the new one is already establishing.

This gives you zero-gap failover and is the single biggest perceived-reliability win. Cap the total number of live connections (e.g. 3) so bug loops can't fork forever.

Reference: `src/client/manager.ts` — `handleStale`, `ensureReplacement`, `handleAlive` (promotion logic), `MAX_LIVE_CONNECTIONS`.

### R7. Close-code classification

Not every close is a reason to retry.

| Retriable (reconnect) | Permanent (stop) |
|---|---|
| 1001 Going Away, 1005 No Status, 1006 Abnormal, 1011 Internal, 1012 Service Restart, 1013 Try Again Later, 1014 Bad Gateway | 1002 Protocol Error, 1003 Unsupported Data, 1007 Invalid Payload, 1009 Message Too Big, 1010 Mandatory Extension, 1015 TLS Failure |

Reconnecting on a 1007 (invalid payload) or 1002 (protocol error) means you will hit the same bug on the next socket forever. Stop, surface the error, let the user decide.

Reference: `src/client/manager.ts:50` (`NON_RETRIABLE_CODES`) and `handleDead`.

### R8. Detect event-loop pauses

Any of these will suspend timers *and* the network stack for seconds at a time: mobile tab freeze, OS sleep, debugger breakpoint, long GC, VM suspend. The Page Lifecycle API catches *some* of these (Chrome-only), but not all.

Install a 1-second interval timer that compares `Date.now()` to the expected tick. If the real elapsed time exceeds (interval + threshold), you know the event loop was paused.

```ts
this.tickIntervalId = setInterval(() => {
  const now = Date.now();
  const elapsed = now - this.lastTickAt;
  this.lastTickAt = now;
  if (elapsed > TICK_MS + JUMP_THRESHOLD_MS) {
    this.handleResume(elapsed);
  }
}, TICK_MS);
```

On detection:

- **Short gap** (< `pongTimeoutMs`): just ping existing connections to verify.
- **Long gap** (≥ `pongTimeoutMs`): open a replacement **proactively, in parallel**. NAT tables are gone, TCP state is gone, Firefox won't fire close. Don't waste the pong timeout confirming what's already known.

Reference: `src/client/manager.ts:472` (`startTimeJumpDetector`), `handleResume`.

### R9. Page Lifecycle integration

On the browser, wire all of these. Each plugs a real hole:

| Event | Action |
|---|---|
| `visibilitychange` → visible | Check all connections; run deferred reconnect if pending. |
| `freeze` (Chrome) | Log only — `resume` does the work. |
| `resume` (Chrome) | Treat as long freeze — proactive reconnect. |
| `pagehide` (persisted) | Close all sockets to allow BFCache. |
| `pageshow` (persisted) | Reconnect after BFCache restore. |
| `online` | Check all connections. |
| `offline` | Log. |
| Network Information API `change` | Check all connections. |

BFCache is worth calling out: **an open WebSocket disqualifies the page from BFCache in all browsers**. If BFCache matters for perceived navigation speed, close sockets on `pagehide` (when `event.persisted`) and reopen on `pageshow`. Do not use `beforeunload`/`unload` — those events *themselves* disqualify BFCache.

Reference: `src/client/manager.ts:407` (`setupLifecycleListeners`).

### R10. Defer reconnection while hidden (Phoenix pattern)

If a reconnect would fire while `document.visibilityState === "hidden"`, **defer it** until the tab becomes visible. Don't burn backoff attempts, battery, and rate-limit budget on a user who isn't there. The moment the tab is visible again, run the deferred attempt immediately (no extra wait).

Reference: `src/client/manager.ts:240` — reconnect is skipped and `pendingReconnectOnVisible` is set; the `visibilitychange` handler clears it and re-runs `scheduleReconnect()`. Pattern documented in [Phoenix PR #6534](https://github.com/phoenixframework/phoenix/pull/6534).

### R11. Server-side heartbeat: event-loop ordering matters

On Node.js (and anything with a phased event loop), the naïve server heartbeat pattern has a race:

```
timer phase:      "did we get a pong since last tick? no? terminate."
↓
I/O poll phase:   buffered pong for the previous tick arrives here
```

After a brief server stall (GC, debugger, CPU spike), the timer runs first and kills clients whose pongs are waiting one phase later. False positives — and they mass-disconnect all your clients at once.

Two mitigations, used together:

1. **Defer termination to `setImmediate`** (check phase, *after* I/O poll). Buffered pongs get to clear the pending flag first.
2. **Nonce correlation with a one-tick lookback**. Each ping carries a random 8-byte nonce. The pong handler only clears `pending` if the echoed nonce matches the current *or previous* nonce. This (a) rejects unsolicited pongs (legal per RFC 6455 § 5.5.3) that would otherwise keep dead clients alive, and (b) covers the gap where a stall caused the nonce to rotate before the old pong landed.

Reference: `src/server.ts:68` — read the full comment block; it explains why no drift-detection threshold is needed once both pieces are in place.

### R12. Destroyed flag (re-entry guard)

When tearing down a manager, calling `conn.close()` synchronously drives the connection into `DEAD`, which calls your `handleDead` handler, which may schedule a reconnect timer. You just armed a new reconnect during destroy.

Set a `destroyed` flag first, and short-circuit on it in every state handler, factory method, and scheduler. Do the final `clearTimeout` after closing all connections, belt-and-suspenders.

Reference: `src/client/manager.ts:177` (`destroy`).

### R13. Avoid silent graceful-degradation

When the library can't reconnect (max retries hit, non-retriable close code), **stop** and surface a terminal state. Don't just keep trying quietly. Users need to know the app is degraded so they can refresh, switch network, or give up — hiding it is worse than showing "disconnected."

Reference: `isTerminal` flag surfaced in `ManagerStats` and rendered in the indicator tooltip as "STOPPED."

### R14. Known gaps to call out in designs

Be honest about what a heartbeat *cannot* fix in a pure main-thread browser implementation:

- Chrome throttles main-thread timers to 1/min after 5 min hidden + 30s silent. Time-jump detection catches the resulting gap on resume, but if you need heartbeats to keep running while hidden, use a **dedicated Web Worker** for the heartbeat timer.
- No session resumption. A reconnect = a fresh logical session. If you need at-least-once delivery across reconnects, you need sequence numbers + replay on top.
- The freeze-simulation in the reference demo is imperfect: real freezes suspend ALL timers simultaneously; a flag-based simulation only suspends handlers. The time-jump detector triggers the same recovery path, so the code under test is still exercised.

---

## Part 2 — Visual indication

Rules for surfacing the above to the user without being annoying or misleading.

### V1. One compact indicator in a stable location

There should be exactly one "how's the connection?" widget, and it should live in the same pixel on every screen of the app. The reference implementation uses a 32×32 circle in the status bar (`#ws-indicator`) with:

- Colored dot (state channel).
- Ring around the dot (countdown channel).
- Data-state attribute driving CSS variants.
- Tooltip on hover with full detail.
- `aria-label` for accessibility.

Reference: `src/client/ui.ts:67`–`75` (markup), `ws-indicator` CSS in `public/index.html`.

### V2. Derive the widget state; never store it

The widget has its own derived state (`alive / stale / connecting / dead / terminal / frozen`) computed from manager stats. Do not store this separately — it will drift.

```ts
function deriveWidgetState(stats: ManagerStats): WidgetState {
  if (stats.frozen) return "frozen";
  const seen = new Set(stats.connections.map(c => c.state));
  if (seen.has("ALIVE")) return "alive";
  if (seen.has("STALE")) return "stale";
  if (seen.has("NEW")) return "connecting";
  if (stats.isTerminal) return "terminal";
  if (stats.reconnectScheduledAt !== null || stats.reconnectDeferredUntilVisible) return "connecting";
  return "dead";
}
```

Reference: `src/client/ui.ts:306`.

### V3. Non-color channels are mandatory

Color alone fails colorblind users and prints/screenshots. Encode state in at least two of: color, motion (pulse/spin), shape (solid/ring/×), text label.

The reference widget uses color + ring fill + a stateful label in the tooltip, and the document title mirrors state in text: `(1/1) WS Reconnect` vs `(0/1) WS Reconnect [FROZEN]`.

### V4. Visualize waiting phases as depleting budgets

When the connection is in a state that has a deadline (`ALIVE` awaiting a pong, `STALE` in grace period, `NEW` in connect timeout, scheduled reconnect counting down), show a ring/bar that depletes from full to empty over the remaining time. This turns "is it about to fail?" into something the user can see at a glance.

Reference: `src/client/ui.ts:273` (`computeRingRemaining`). One function, four cases, driven by the derived state.

### V5. Rendering loop: rAF with throttle + immediate refresh on events

Two signals trigger a render:

1. A `requestAnimationFrame` loop that throttles itself to ~10 Hz (every 100ms) — enough to animate countdowns smoothly.
2. An `onUpdate` callback from the manager on every state change, for sub-100ms responsiveness to real events.

Do not poll at 60 Hz. Do not poll at 1 Hz and miss transitions. Throttled rAF + event push is the right combination.

Reference: `src/client/ui.ts:113` (`scheduleUpdate`) and `src/client/manager.ts:59` (`onUpdate`).

### V6. Tooltip/expanded view is where the engineer detail lives

The compact widget says "something is wrong." The expanded view explains what:

- Pool summary (how many connections, in what state).
- Active connection id, uptime.
- In-flight pings.
- Packet loss percentage.
- RTT windows: 30s / 1m / 5m — min / median / max / count.
- Backoff state: attempt N/max, time until next try, or "deferred (tab hidden)", or "stopped."
- Last close reason + code.

Reference: `src/client/ui.ts:354` (`renderTooltipHtml`).

### V7. Mirror the state in `document.title`

Hidden tabs do not show your compact indicator. They *do* show the title. Encode connection state there so it's visible at tab-level:

```ts
document.title = `(${alive}/${total}) WS Reconnect${frozen ? " [FROZEN]" : ""}`;
```

Reference: `src/client/ui.ts:243`.

### V8. Event log for diagnosis (user-facing)

A scrollback of timestamped state transitions, lifecycle events, and reconnect attempts lets both developers and savvy users diagnose flakes without a browser devtools session. Keep it bounded (e.g. 500 entries, display first 100).

Reference: `src/client/manager.ts:536` (`log`), `src/client/ui.ts:227` (`renderLog`).

### V9. Use active-vs-background states in card styling

When you render a pool, mark the **active** connection distinctly (border, badge). Non-active connections in the pool during a failover are informational noise; the user cares about "which one am I talking through right now."

Reference: `card-active` class, `activeConnectionId` in `ManagerStats`.

### V10. Never lie

If reconnection has been stopped (terminal), show "stopped" — not "connecting" with an animation that will never resolve. If a reconnect is deferred because the tab is hidden, say "deferred" — not "retrying." Users adapt their behavior to what the indicator says; making it optimistic is a UX bug that trains users to ignore it.

---

## Part 3 — Bringup checklist

When building a new client (or reviewing one), tick through these in order. A missing item from the top of the list invalidates the ones below it.

**Reliability layer:**

- [ ] Application-level heartbeat with per-ping nonces and per-ping timeouts.
- [ ] Four-state machine (`NEW/ALIVE/STALE/DEAD`) with grace period on `STALE`.
- [ ] Connect timeout that also checks native `readyState`.
- [ ] Exponential backoff with full jitter, cap, max retries, terminal state after cap.
- [ ] Overlapping-connection failover with a pool-size cap.
- [ ] Close-code classification (retriable vs permanent).
- [ ] Time-jump detector driving proactive reconnect on long gaps.
- [ ] Page Lifecycle wiring: `visibilitychange`, `freeze`/`resume`, `pagehide`/`pageshow` for BFCache, `online`/`offline`, Network Information API.
- [ ] Defer-while-hidden reconnect (Phoenix pattern).
- [ ] Server heartbeat with `setImmediate` deferral and nonce correlation (current + previous).
- [ ] `destroyed` flag guarding all state handlers and schedulers.

**Indicator layer:**

- [ ] Single compact widget in a stable location, with `aria-label`.
- [ ] Widget state *derived* from manager stats, never stored.
- [ ] Two independent state channels (color + shape/motion/text).
- [ ] Countdown ring for every waiting phase.
- [ ] Render loop = throttled rAF (≈10 Hz) + event-driven immediate refresh.
- [ ] Expanded/tooltip view with pool, RTT windows, loss %, backoff, last close.
- [ ] `document.title` reflects state so hidden tabs surface it.
- [ ] Bounded, timestamped event log.
- [ ] Terminal/deferred states are truthfully labeled.

If you can't tick an item, write a one-line note on why and what mitigates it — don't silently ship a gap.

---

## References

- **Reference implementation:** https://github.com/pshirshov/ws-reconnect-demo — see `src/client/connection.ts`, `src/client/manager.ts`, `src/client/ui.ts`, `src/server.ts`, `README.md` for working code exercising every pattern above.
- [Chrome Page Lifecycle API](https://developer.chrome.com/docs/web-platform/page-lifecycle-api)
- [web.dev BFCache guide](https://web.dev/articles/bfcache)
- [Phoenix visibility-aware reconnection (PR #6534)](https://github.com/phoenixframework/phoenix/pull/6534)
- Firefox bugs: [920074](https://bugzilla.mozilla.org/show_bug.cgi?id=920074) (no TCP keepalive), [1360753](https://bugzilla.mozilla.org/show_bug.cgi?id=1360753) (connection throttling), [1921382](https://bugzilla.mozilla.org/show_bug.cgi?id=1921382).
- [ws library heartbeat pattern](https://github.com/websockets/ws#how-to-detect-and-close-broken-connections)
- [RFC 6455 § 5.5 — Control frames / Ping/Pong](https://www.rfc-editor.org/rfc/rfc6455#section-5.5)
- [WebSocket close codes reference](https://websocket.org/reference/close-codes/)
