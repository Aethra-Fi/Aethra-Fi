/** Credit helpers. Rates come from the vault as per-second WAD values. */

export const SECONDS_PER_YEAR = 31_536_000;
const WAD = 1e18;

export function aprFromPerSecondWad(rate: bigint | null | undefined): number | null {
  if (rate === null || rate === undefined) return null;
  return (Number(rate) / WAD) * SECONDS_PER_YEAR * 100;
}

export function apyFromPerSecondWad(rate: bigint | null | undefined): number | null {
  if (rate === null || rate === undefined) return null;
  const r = Number(rate) / WAD;
  return (Math.pow(1 + r, SECONDS_PER_YEAR) - 1) * 100;
}

/**
 * Kinked rate model used to draw the curve. Must match the deployed KinkIRM parameters; the lead should
 * replace these with on-chain reads once the IRM exposes them (see docs in the final report).
 */
export interface KinkModel {
  baseRatePct: number;
  slope1Pct: number;
  slope2Pct: number;
  kinkPct: number;
}

export const DEFAULT_KINK_MODEL: KinkModel = { baseRatePct: 0, slope1Pct: 8, slope2Pct: 120, kinkPct: 80 };

export function kinkBorrowRate(utilPct: number, m: KinkModel = DEFAULT_KINK_MODEL): number {
  const u = Math.max(0, Math.min(100, utilPct));
  if (u <= m.kinkPct) return m.baseRatePct + (u / m.kinkPct) * m.slope1Pct;
  return m.baseRatePct + m.slope1Pct + ((u - m.kinkPct) / (100 - m.kinkPct)) * m.slope2Pct;
}

export function kinkCurve(m: KinkModel = DEFAULT_KINK_MODEL, steps = 50): { u: number; borrow: number }[] {
  return Array.from({ length: steps + 1 }, (_, i) => {
    const u = (i / steps) * 100;
    return { u, borrow: kinkBorrowRate(u, m) };
  });
}

export type HealthState = "safe" | "warning" | "danger" | "none";

export function healthState(hf: number | null | undefined): HealthState {
  if (hf === null || hf === undefined || !Number.isFinite(hf)) return "none";
  if (hf < 1.1) return "danger";
  if (hf < 1.5) return "warning";
  return "safe";
}
