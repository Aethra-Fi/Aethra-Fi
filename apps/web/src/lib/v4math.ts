/** Float-based Uniswap v4 price helpers for UI estimates. Contracts enforce exact amounts via amountMax/Min. */

export const MIN_TICK = -887272;
export const MAX_TICK = 887272;
export const Q96 = 2 ** 96;
/** Uniswap v4 LPFeeLibrary.DYNAMIC_FEE_FLAG */
export const DYNAMIC_FEE_FLAG = 0x800000;

export function tickToPrice(tick: number, decimals0 = 18, decimals1 = 18): number {
  return Math.pow(1.0001, tick) * Math.pow(10, decimals0 - decimals1);
}

export function priceToTick(price: number, tickSpacing = 1, decimals0 = 18, decimals1 = 18): number {
  const raw = price / Math.pow(10, decimals0 - decimals1);
  const t = Math.round(Math.log(raw) / Math.log(1.0001));
  const aligned = Math.round(t / tickSpacing) * tickSpacing;
  const min = Math.ceil(MIN_TICK / tickSpacing) * tickSpacing;
  const max = Math.floor(MAX_TICK / tickSpacing) * tickSpacing;
  return Math.min(max, Math.max(min, aligned));
}

export function fullRangeTicks(tickSpacing: number): [number, number] {
  return [Math.ceil(MIN_TICK / tickSpacing) * tickSpacing, Math.floor(MAX_TICK / tickSpacing) * tickSpacing];
}

export function sqrtPriceX96ToPrice(sqrtPriceX96: bigint | string, decimals0 = 18, decimals1 = 18): number {
  const s = Number(BigInt(sqrtPriceX96)) / Q96;
  return s * s * Math.pow(10, decimals0 - decimals1);
}

export function priceToSqrtPriceX96(price: number, decimals0 = 18, decimals1 = 18): bigint {
  const raw = price / Math.pow(10, decimals0 - decimals1);
  const sqrt = Math.sqrt(raw);
  // split the 2^96 shift so the float keeps its 53-bit mantissa
  return BigInt(Math.round(sqrt * 2 ** 48)) << 48n;
}

const sqrtAtTick = (tick: number) => Math.pow(1.0001, tick / 2);

/** Liquidity for the given raw amounts in [tickLower, tickUpper] at sqrtPrice (float, raw units). */
export function liquidityForAmounts(
  sqrtPriceX96: bigint | string,
  tickLower: number,
  tickUpper: number,
  amount0: bigint,
  amount1: bigint,
): bigint {
  const p = Number(BigInt(sqrtPriceX96)) / Q96;
  const a = sqrtAtTick(tickLower);
  const b = sqrtAtTick(tickUpper);
  const x = Number(amount0);
  const y = Number(amount1);
  let l: number;
  if (p <= a) l = (x * a * b) / (b - a);
  else if (p >= b) l = y / (b - a);
  else l = Math.min((x * p * b) / (b - p), y / (p - a));
  if (!Number.isFinite(l) || l <= 0) return 0n;
  // 0.1% haircut so float error never asks for more than amountMax
  return BigInt(Math.floor(l * 0.999));
}

export function amountsForLiquidity(
  sqrtPriceX96: bigint | string,
  tickLower: number,
  tickUpper: number,
  liquidity: bigint,
): { amount0: number; amount1: number } {
  const p = Number(BigInt(sqrtPriceX96)) / Q96;
  const a = sqrtAtTick(tickLower);
  const b = sqrtAtTick(tickUpper);
  const L = Number(liquidity);
  if (p <= a) return { amount0: (L * (b - a)) / (a * b), amount1: 0 };
  if (p >= b) return { amount0: 0, amount1: L * (b - a) };
  return { amount0: (L * (b - p)) / (p * b), amount1: L * (p - a) };
}
