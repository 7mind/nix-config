import { useMemo, useState } from 'react';
import type { HistoryPoint, ValveHistory } from './protocol';
import { temperature, valveTarget } from './format';

const WIDTH = 480;
const HEIGHT = 190;
const LEFT = 50;
const RIGHT = WIDTH - 10;
const TOP = 12;
const BOTTOM = HEIGHT - 24;
const MAX_SAMPLE_GAP_MS = 90_000;

export function chartSegments(
  points: HistoryPoint[], value: (point: HistoryPoint) => number | null, x: (timestamp: number) => number,
  y: (temperature: number) => number, step: boolean,
): string {
  let path = '';
  let previous: HistoryPoint | null = null;
  for (const point of points) {
    const current = value(point);
    if (current === null) { previous = null; continue; }
    const xpos = x(point.timestamp_epoch_ms).toFixed(2);
    const ypos = y(current).toFixed(2);
    if (previous === null || point.timestamp_epoch_ms - previous.timestamp_epoch_ms > MAX_SAMPLE_GAP_MS) path += `M${xpos},${ypos}`;
    else path += step ? `H${xpos}V${ypos}` : `L${xpos},${ypos}`;
    previous = point;
  }
  return path;
}

export function HistoryChart({ history, device }: { history: ValveHistory; device: string }) {
  const [hover, setHover] = useState<number | null>(null);
  const [tableOpen, setTableOpen] = useState(false);
  const chart = useMemo(() => {
    const temperatures = history.points.flatMap(point => [
      point.freshness === 'fresh' ? point.local_temperature : null,
      point.freshness === 'fresh' ? point.reported_setpoint : null,
      point.target !== null && point.target.kind === 'setpoint' ? point.target.temperature : null,
    ]).filter((value): value is number => value !== null);
    const low = temperatures.length === 0 ? 15 : Math.floor(Math.min(...temperatures) - 1);
    const high = temperatures.length === 0 ? 25 : Math.max(low + 4, Math.ceil(Math.max(...temperatures) + 1));
    const x = (timestamp: number) => LEFT + (timestamp - history.from_epoch_ms) / (history.to_epoch_ms - history.from_epoch_ms) * (RIGHT - LEFT);
    const y = (temperature: number) => BOTTOM - (temperature - low) / (high - low) * (BOTTOM - TOP);
    const actual = chartSegments(history.points, point => point.freshness === 'fresh' ? point.local_temperature : null, x, y, false);
    const reported = chartSegments(history.points, point => point.freshness === 'fresh' ? point.reported_setpoint : null, x, y, true);
    const target = chartSegments(history.points, point => point.target !== null && point.target.kind === 'setpoint' ? point.target.temperature : null, x, y, true);
    const demand = chartSegments(history.points, point => point.freshness === 'fresh' ? point.heating_demand : null, x,
      value => BOTTOM - value / 100 * 24, true);
    return { low, high, x, y, actual, reported, target, demand };
  }, [history]);
  const selected = hover === null ? undefined : history.points.reduce<HistoryPoint | undefined>((nearest, point) =>
    nearest === undefined || Math.abs(point.timestamp_epoch_ms - hover) < Math.abs(nearest.timestamp_epoch_ms - hover) ? point : nearest, undefined);
  const formatTime = (timestamp: number) => new Date(timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  const hasReadings = history.points.some(point => point.freshness === 'fresh' && point.local_temperature !== null);
  return <div className="history-chart">
    <svg viewBox={`0 0 ${WIDTH} ${HEIGHT}`} role="img" aria-label={`${device}: temperature and setpoint history for the last 24 hours`}
      onPointerMove={event => {
        const bounds = event.currentTarget.getBoundingClientRect();
        const fraction = Math.max(0, Math.min(1, ((event.clientX - bounds.left) / bounds.width * WIDTH - LEFT) / (RIGHT - LEFT)));
        setHover(history.from_epoch_ms + fraction * (history.to_epoch_ms - history.from_epoch_ms));
      }} onPointerLeave={() => setHover(null)}>
      {[chart.low, (chart.low + chart.high) / 2, chart.high].map(value => <g key={value}>
        <line className="chart-grid" x1={LEFT} y1={chart.y(value)} x2={RIGHT} y2={chart.y(value)} />
        <text className="chart-label" x={LEFT - 7} y={chart.y(value) + 4} textAnchor="end">{value}°</text>
      </g>)}
      <path className="chart-demand" d={chart.demand} />
      <path className="chart-target" d={chart.target} />
      <path className="chart-reported" d={chart.reported} />
      <path className="chart-actual" d={chart.actual} />
      {[-24, -18, -12, -6, 0].map(hours => <text key={hours} className="chart-label" x={chart.x(history.to_epoch_ms + hours * 3600_000)} y={HEIGHT - 5} textAnchor={hours === -24 ? 'start' : hours === 0 ? 'end' : 'middle'}>{hours === 0 ? 'Now' : `${hours}h`}</text>)}
      {selected !== undefined && <line className="chart-cursor" x1={chart.x(selected.timestamp_epoch_ms)} x2={chart.x(selected.timestamp_epoch_ms)} y1={TOP} y2={BOTTOM} />}
    </svg>
    {history.points.length === 0 ? <p className="chart-empty">History starts as the controller records samples.</p>
      : !hasReadings && <p className="chart-empty">No fresh temperature readings in this period.</p>}
    <div className="chart-legend"><span className="legend-actual">Temperature</span><span className="legend-target">Requested</span><span className="legend-reported">Reported setpoint</span><span className="legend-demand">Demand 0–100%</span></div>
    {selected !== undefined && <div className="chart-inspect">{formatTime(selected.timestamp_epoch_ms)} · {celsius(selected.local_temperature)} · requested {valveTarget(selected.target)} · reported {celsius(selected.reported_setpoint)} · demand {selected.heating_demand === null ? '—' : `${selected.heating_demand}%`} · {selected.freshness}</div>}
    <details className="history-data" onToggle={event => setTableOpen(event.currentTarget.open)}><summary>Inspect recorded values</summary>{tableOpen && <div className="history-table-wrap"><table>
      <thead><tr><th>Time</th><th>Temperature</th><th>Requested</th><th>Reported setpoint</th><th>Demand</th><th>Reading</th></tr></thead>
      <tbody>{[...history.points].reverse().map(point => <tr key={point.timestamp_epoch_ms}><td>{formatTime(point.timestamp_epoch_ms)}</td><td>{celsius(point.local_temperature)}</td><td>{valveTarget(point.target)}</td><td>{celsius(point.reported_setpoint)}</td><td>{point.heating_demand === null ? '—' : `${point.heating_demand}%`}</td><td>{point.freshness}</td></tr>)}</tbody>
    </table></div>}</details>
  </div>;
}

function celsius(value: number | null): string { return value === null ? '—' : `${temperature(value)}C`; }
