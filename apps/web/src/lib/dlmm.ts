/**
 * DLMM bin math. Mirrors IDLMMPool: price(id) = (1 + binStepBps / 10_000) ^ id, token1 per token0 in raw units.
 * Bins above the active bin hold token0 only, bins below hold token1 only, the active bin holds both.
 */

export type BinShape = "spot" | "curve" | "bidask";

export const MAX_BIN_RADIUS = 50;

/** Raw-unit price (token1 per token0) of a bin. */
export function rawPriceFromBin(id: number, binStepBps: number): number {
  return Math.pow(1 + binStepBps / 10_000, id);
}

/** Human price (token1 per token0, decimals applied) of a bin. */
export function priceFromBin(id: number, binStepBps: number, decimals0 = 18, decimals1 = 18): number {
  return rawPriceFromBin(id, binStepBps) * Math.pow(10, decimals0 - decimals1);
}

/**
 * Nearest bin for a human price. `rounding` controls the direction when the price falls between bins
 * (limit orders selling token0 should round up, selling token1 should round down).
 */
export function binFromPrice(
  price: number,
  binStepBps: number,
  decimals0 = 18,
  decimals1 = 18,
  rounding: "nearest" | "up" | "down" = "nearest",
): number {
  if (!(price > 0) || !(binStepBps > 0)) throw new Error("price and binStep must be positive");
  const raw = price / Math.pow(10, decimals0 - decimals1);
  const exact = Math.log(raw) / Math.log(1 + binStepBps / 10_000);
  // absorb float noise so exact bin prices map back onto their own id
  const snapped = Math.abs(exact - Math.round(exact)) < 1e-9 ? Math.round(exact) : exact;
  const id = rounding === "up" ? Math.ceil(snapped) : rounding === "down" ? Math.floor(snapped) : Math.round(snapped);
  return id === 0 ? 0 : id; // avoid -0
}

/** Relative weight of a bin `d` steps away from the active bin, for a shape of the given radius. */
export function shapeWeight(shape: BinShape, d: number, radius: number): number {
  const a = Math.abs(d);
  if (a > radius) return 0;
  switch (shape) {
    case "spot":
      return 1;
    case "curve": {
      const sigma = Math.max(1, radius / 2);
      return Math.exp(-(a * a) / (2 * sigma * sigma));
    }
    case "bidask":
      return radius === 0 ? 1 : 0.2 + (a / radius) * 0.8;
  }
}

export interface BinDistribution {
  ids: number[];
  amounts0: bigint[];
  amounts1: bigint[];
  /** normalized 0..1 weights per id, for charts */
  weights0: number[];
  weights1: number[];
}

const SCALE = 1_000_000n;

function split(total: bigint, weights: number[]): bigint[] {
  const scaled = weights.map((w) => BigInt(Math.round(w * Number(SCALE))));
  const sum = scaled.reduce((a, b) => a + b, 0n);
  if (total === 0n || sum === 0n) return weights.map(() => 0n);
  const out = scaled.map((w) => (total * w) / sum);
  // put the rounding remainder on the heaviest bin so the parts add up exactly
  const rem = total - out.reduce((a, b) => a + b, 0n);
  let maxI = 0;
  scaled.forEach((w, i) => {
    if (w > scaled[maxI]!) maxI = i;
  });
  out[maxI] = out[maxI]! + rem;
  return out;
}

/**
 * Distribute amount0 over [active, active + radius] and amount1 over [active - radius, active] using a shape.
 * Returns ids in ascending order with per-bin raw amounts that sum exactly to the inputs.
 */
export function distributeBins(params: {
  activeId: number;
  radius: number;
  shape: BinShape;
  amount0: bigint;
  amount1: bigint;
}): BinDistribution {
  const radius = Math.max(0, Math.min(MAX_BIN_RADIUS, Math.floor(params.radius)));
  const { activeId, shape } = params;
  const ids: number[] = [];
  for (let id = activeId - radius; id <= activeId + radius; id++) ids.push(id);
  const w0 = ids.map((id) => (id >= activeId ? shapeWeight(shape, id - activeId, radius) : 0));
  const w1 = ids.map((id) => (id <= activeId ? shapeWeight(shape, id - activeId, radius) : 0));
  const amounts0 = split(params.amount0, w0);
  const amounts1 = split(params.amount1, w1);
  const max0 = Math.max(...w0, 0) || 1;
  const max1 = Math.max(...w1, 0) || 1;
  return {
    ids,
    amounts0,
    amounts1,
    weights0: w0.map((w) => (params.amount0 > 0n ? w / max0 : 0)),
    weights1: w1.map((w) => (params.amount1 > 0n ? w / max1 : 0)),
  };
}
