/** Price helpers shared by the UI, indexer and scripts. Prices are token1 per token0 in human units. */

const Q96 = 2n ** 96n;

export const MIN_TICK = -887272;
export const MAX_TICK = 887272;

/** Human price (token1 per token0) from a v4/DAMM sqrtPriceX96. */
export function sqrtPriceX96ToPrice(sqrtPriceX96: bigint, decimals0: number, decimals1: number): number {
  const s = Number(sqrtPriceX96) / Number(Q96);
  return s * s * 10 ** (decimals0 - decimals1);
}

/** sqrtPriceX96 for a human price (token1 per token0). */
export function priceToSqrtPriceX96(price: number, decimals0: number, decimals1: number): bigint {
  if (!(price > 0)) throw new Error("price must be positive");
  const raw = price * 10 ** (decimals1 - decimals0);
  const sqrt = Math.sqrt(raw);
  // split to keep precision for large and small values
  const scaled = BigInt(Math.floor(sqrt * 2 ** 48));
  return scaled * 2n ** 48n;
}

export function tickToPrice(tick: number, decimals0: number, decimals1: number): number {
  return 1.0001 ** tick * 10 ** (decimals0 - decimals1);
}

export function priceToTick(price: number, decimals0: number, decimals1: number): number {
  const raw = price * 10 ** (decimals1 - decimals0);
  return Math.floor(Math.log(raw) / Math.log(1.0001));
}

/** Round a tick to the nearest usable multiple of `spacing` (floor). */
export function nearestUsableTick(tick: number, spacing: number): number {
  const t = Math.floor(tick / spacing) * spacing;
  return Math.max(Math.ceil(MIN_TICK / spacing) * spacing, Math.min(Math.floor(MAX_TICK / spacing) * spacing, t));
}

export function fullRangeTicks(spacing: number): [number, number] {
  return [Math.ceil(MIN_TICK / spacing) * spacing, Math.floor(MAX_TICK / spacing) * spacing];
}

/** DLMM: human price of a bin, where raw price(id) = (1 + binStep/1e4)^id. */
export function binToPrice(binId: number, binStepBps: number, decimals0: number, decimals1: number): number {
  return (1 + binStepBps / 10_000) ** binId * 10 ** (decimals0 - decimals1);
}

/** DLMM: the bin whose price is closest to (at or below) a human price. */
export function priceToBin(price: number, binStepBps: number, decimals0: number, decimals1: number): number {
  const raw = price * 10 ** (decimals1 - decimals0);
  return Math.floor(Math.log(raw) / Math.log(1 + binStepBps / 10_000) + 1e-9);
}

/** Fee in pips (1e-6) to a percentage string, e.g. 3000 -> "0.30%". */
export function formatFeePips(pips: number): string {
  return `${(pips / 10_000).toFixed(pips % 100 === 0 ? 2 : 3)}%`;
}

export type LiquidityShape = "spot" | "curve" | "bidask";

/**
 * Distribute a DLMM deposit across `2*radius+1` bins centered on `activeId`.
 * Returns per-bin weights (sum = 1) for token0 (bins >= active) and token1 (bins <= active).
 */
export function binDistribution(
  activeId: number,
  radius: number,
  shape: LiquidityShape,
): { ids: number[]; weight0: number[]; weight1: number[] } {
  const ids: number[] = [];
  const raw: number[] = [];
  for (let d = -radius; d <= radius; d++) {
    ids.push(activeId + d);
    const x = radius === 0 ? 0 : Math.abs(d) / radius;
    raw.push(shape === "spot" ? 1 : shape === "curve" ? Math.exp(-4 * x * x) : 0.25 + x);
  }
  const w0 = ids.map((id, i) => (id >= activeId ? raw[i]! : 0));
  const w1 = ids.map((id, i) => (id <= activeId ? raw[i]! : 0));
  const s0 = w0.reduce((a, b) => a + b, 0) || 1;
  const s1 = w1.reduce((a, b) => a + b, 0) || 1;
  return { ids, weight0: w0.map((w) => w / s0), weight1: w1.map((w) => w / s1) };
}
