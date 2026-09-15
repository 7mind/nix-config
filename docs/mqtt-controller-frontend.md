# MQTT controller dashboard

The dashboard lives in `pkg/mqtt-controller/frontend`: React, TypeScript, Vite and
Zod. Axum serves its static assets alongside `/ws`; there is no browser event log.
The former Leptos/WASM frontend and Trunk build have been removed.

## Development and validation

Use Node.js 24 and the committed npm lockfile:

```sh
cd pkg/mqtt-controller/frontend
npm ci
npm run dev
npm test
npm run build
npm run test:browser
```

Vite proxies `/ws` to a controller on `127.0.0.1:8780`. Development controls issue
real commands to that controller. Browser tests instead start their own local
WebSocket server with synthetic devices. Set
`PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH` to use an installed Chromium; otherwise
install Playwright's Chromium with `npx playwright install chromium`.

Backend tests use an embedded MQTT broker and temporary databases:

```sh
cd pkg/mqtt-controller
cargo test -p mqtt-controller -p mqtt-controller-wire --locked
```

The Nix overlay builds static assets with `frontend.nix`, runs frontend tests,
and embeds the output in the controller package. To verify the frontend build:

```sh
nix build --no-link '.?submodules=1#nixosConfigurations.raspi5m.pkgs.mqtt-controller-frontend'
```

## Controls and state

Light groups expose their scheduled scene IDs and an OFF action. Plugs expose
explicit ON/OFF actions, so a repeated request cannot toggle the wrong way after
an outdated observation. Requested and reported state remain separate. A command
acknowledgement means the controller accepted the action; hardware confirmation
arrives through subsequent MQTT observations. Validation failures, missing
acknowledgements and interrupted connections appear beside the affected control.

`mqtt-controller-wire` defines the Rust protocol; `frontend/src/protocol.ts`
validates received messages in the browser. Update both when changing the wire
contract. Commands carry a request ID and receive a matching `CommandResult`.
They are never queued offline or replayed after reconnection.

## Valve history

With the web interface enabled, the service records one snapshot per valve per
minute in `/var/lib/mqtt-controller/heating-history.db`. Standalone invocations
must provide `--web-history-db PATH` alongside `--web-port` and
`--web-assets-dir`. Database initialization failures prevent startup; subsequent
sampling failures are logged and shown with history results.

History survives restarts and retains the last 24 hours. Recording begins after
deployment; existing audit entries cannot reconstruct past temperatures. Each
sample retains observed temperature, reported setpoint, requested target, demand,
battery, freshness and last observation time. Repeated samples within a minute
replace that minute's row. This is sampled history: short changes between samples
may not appear. Charts leave gaps for missing samples and stale/unknown readings,
and do not interpolate setpoint changes. Requested non-temperature modes remain
available in the recorded-values table.

## Connection recovery

Each socket moves through NEW, ALIVE, STALE and DEAD. A matching nonce and echoed
timestamp establish liveness; an open transport alone does not. The manager uses
handshake deadlines, per-ping deadlines, a stale grace period with an overlapping
replacement, bounded jittered exponential backoff and a manual retry after the
attempt ceiling or a permanent protocol error. Every promotion requests a fresh
snapshot before enabling controls. Lost server broadcast updates close the
connection so the browser must resynchronize.

Visibility, network changes, page freeze/resume, BFCache restoration and detected
timer gaps trigger verification or recovery. Teardown prevents new connections.
The indicator has text, a countdown ring, a title status and an expandable view
of connection IDs, RTT windows, heartbeat timeouts and retry/close details.

The server keeps ordered command/database work in a bounded worker separate from
its heartbeat reader. Protocol pongs must match the current or previous nonce.
Before checking the heartbeat deadline, a short Tokio timer defers the check so
buffered I/O can run after a scheduler pause; Node's `setImmediate` is not
applicable to this Rust server.

Two deliberate limits relative to `resilient-ws-ui`: the user requested no event
log, and heartbeats run on the browser's main thread. Hidden tabs may throttle or
suspend timers; the dashboard verifies/replaces connections when visible again
instead of promising continuous background connectivity. Reconnection starts a
fresh session; uncertain commands require checking reported state before retrying.
