import type { ActualMeta, ValveTarget } from './protocol';

export function label(value: string): string {
  return value.replace(/^(hue|sonoff|bosch|zneo|z2m|aqara)-(trv|wt|ms|lz|fs|l|p|s)-/, '')
    .replaceAll('-', ' ').replace(/^./, character => character.toUpperCase());
}
export function temperature(value: number | null | undefined): string {
  return value == null ? '—' : `${value.toFixed(1)}°`;
}
export function duration(milliseconds: number): string {
  const seconds = Math.max(0, Math.floor(milliseconds / 1000));
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ${Math.floor((seconds % 3600) / 60)}m`;
  return `${Math.floor(seconds / 86400)}d`;
}
export function age(actual: ActualMeta | null | undefined, receivedAt: number, now: number): string {
  if (actual == null || actual.since_ago_ms == null) return 'No report yet';
  return `Reported ${duration(actual.since_ago_ms + Math.max(0, now - receivedAt))} ago`;
}
export function valveTarget(target: ValveTarget | null | undefined): string {
  if (target == null) return 'No target';
  switch (target.kind) {
    case 'setpoint': return `${temperature(target.temperature)}C`;
    case 'inhibited': return 'Window hold';
    case 'forced_open': return 'Forced open';
  }
}
