import { expect, it } from 'vitest';
import { chartSegments } from './HistoryChart';
import type { HistoryPoint } from './protocol';

function point(timestamp_epoch_ms: number, local_temperature: number | null): HistoryPoint {
  return { timestamp_epoch_ms, local_temperature, observed_at_epoch_ms: timestamp_epoch_ms,
    target: null, reported_setpoint: null, heating_demand: null, battery: null, freshness: 'fresh' };
}
it('leaves gaps for missing telemetry and controller downtime', () => {
  const path = chartSegments([point(0, 20), point(60_000, 21), point(120_000, null), point(180_000, 22), point(400_000, 23)],
    point => point.local_temperature, time => time / 1000, temperature => temperature, false);
  expect(path).toBe('M0.00,20.00L60.00,21.00M180.00,22.00M400.00,23.00');
});
