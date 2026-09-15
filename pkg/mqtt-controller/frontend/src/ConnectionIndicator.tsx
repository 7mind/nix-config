import { useEffect, useState } from 'react';
import { CONNECTION_POLICY, type Health } from './connection';
import { duration } from './format';

export function healthLabel(health: Health): string {
  if (health.terminal) return 'Stopped';
  if (health.frozen) return 'Paused';
  if (health.offline) return 'Offline';
  if (health.connections.some(connection => connection.id === health.activeId && connection.state === 'ALIVE')) return 'Connected';
  if (health.deferred) return 'Deferred';
  if (health.connections.some(connection => connection.state === 'STALE')) return 'Reconnecting';
  if (health.retryAt !== null) return 'Retrying';
  if (health.connections.some(connection => connection.state === 'NEW')) return 'Connecting';
  return 'Disconnected';
}

export function ConnectionIndicator({ health, retry }: { health: Health; retry: () => void }) {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    let frame = 0;
    let previous = 0;
    const update = (timestamp: number) => {
      if (timestamp - previous >= 100) { setNow(Date.now()); previous = timestamp; }
      frame = requestAnimationFrame(update);
    };
    frame = requestAnimationFrame(update);
    return () => cancelAnimationFrame(frame);
  }, []);
  const state = healthLabel(health);
  const active = health.connections.find(connection => connection.id === health.activeId);
  const waiting = active ?? health.connections.find(connection => connection.state !== 'DEAD');
  let remaining = 1;
  if (health.retryAt !== null && health.retryStartedAt !== null) {
    remaining = (health.retryAt - now) / (health.retryAt - health.retryStartedAt);
  } else if (waiting !== undefined && waiting.deadline !== null) {
    const budget = waiting.state === 'STALE' ? CONNECTION_POLICY.graceMs
      : waiting.state === 'NEW' && waiting.pendingPings === 0 ? CONNECTION_POLICY.connectMs
      : waiting.pendingPings > 0 ? CONNECTION_POLICY.pongMs : CONNECTION_POLICY.pingMs;
    remaining = (waiting.deadline - now) / budget;
  }
  remaining = Math.max(0, Math.min(1, remaining));
  const healthy = state === 'Connected';
  useEffect(() => { document.title = `${state === 'Connected' ? '' : `[${state}] `}Home · MQTT Controller`; }, [state]);
  return <details className={`connection ${healthy ? 'healthy' : 'unhealthy'}`}>
    <summary aria-label={`Controller connection: ${state}`}>
      <svg className="connection-ring" viewBox="0 0 32 32" aria-hidden="true">
        <circle className="ring-track" cx="16" cy="16" r="13" />
        <circle className="ring-budget" cx="16" cy="16" r="13" pathLength="100" strokeDasharray={`${remaining * 100} 100`} />
        <text x="16" y="21" textAnchor="middle">{healthy ? '✓' : health.terminal ? '×' : '·'}</text>
      </svg>
      <span>{state}</span>
      {healthy && active !== undefined && active.lastRtt !== null && <small>{Math.round(active.lastRtt)} ms</small>}
    </summary>
    <div className="connection-details">
      <div className="detail-heading"><strong>Controller connection</strong><button className="button small" onClick={retry}>Try again</button></div>
      <p>{health.terminal ? 'Automatic reconnection has stopped.' : health.deferred ? 'Reconnection is deferred while this tab is hidden.' : healthy ? 'Heartbeat confirmed. State updates are live.' : 'Controls resume after a heartbeat and a fresh snapshot.'}</p>
      <dl className="detail-list">
        <dt>Attempt</dt><dd>{health.attempt} / {health.maxAttempts}</dd>
        <dt>Next retry</dt><dd>{health.retryAt === null ? '—' : `${Math.max(0, Math.ceil((health.retryAt - now) / 1000))}s`}</dd>
        <dt>Heartbeat timeouts</dt><dd>{health.timedOut} / {health.sent} ({health.sent === 0 ? 0 : Math.round(health.timedOut / health.sent * 100)}%)</dd>
        <dt>Matching replies</dt><dd>{health.received}</dd>
      </dl>
      <div className="rtt-table"><span>Round trip</span><span>Min / median / max</span>
        {[30, 60, 300].map(seconds => {
          const values = health.rtts.filter(sample => sample.at >= now - seconds * 1000).map(sample => sample.ms).sort((a, b) => a - b);
          return <div className="rtt-row" key={seconds}><span>{seconds < 60 ? `${seconds}s` : `${seconds / 60}m`}</span><span>{values.length === 0 ? '—' : `${Math.round(values[0]!)} / ${Math.round(values[Math.floor(values.length / 2)]!)} / ${Math.round(values[values.length - 1]!)} ms (${values.length})`}</span></div>;
        })}
      </div>
      <div className="connection-pool">{health.connections.map(connection => <div className={connection.id === health.activeId ? 'pool-active' : ''} key={connection.id}>
        <span>{connection.id === health.activeId ? 'Active' : 'Background'} · {connection.state}</span>
        <small>{duration(now - connection.createdAt)} · {connection.pendingPings} pending</small>
      </div>)}</div>
      {health.lastClose !== null && <p className="last-close">Last close: {health.lastClose.code} · {health.lastClose.reason}</p>}
    </div>
  </details>;
}
