// Pure numeric helpers. Raw on-chain integers stay bigint; human/USD values are JS numbers
// (good to ~15 significant digits, which is fine for analytics).

const TWO_96 = 2 ** 96;

/** bigint raw amount -> human float, without overflowing Number for very large values. */
export function toHuman(raw: bigint, decimals: number): number {
  if (raw === 0n) return 0;
  const neg = raw < 0n;
  const abs = neg ? -raw : raw;
  const s = abs.toString();
  let value: number;
  if (decimals <= 0) {
    value = Number(s);
  } else if (s.length > decimals) {
    value = Number(`${s.slice(0, s.length - decimals)}.${s.slice(s.length - decimals, s.length - decimals + 18)}`);
  } else {
    value = Number(`0.${"0".repeat(decimals - s.length)}${s}`);
  }
  return neg ? -value : value;
}

/** v4 / DAMM sqrtPriceX96 -> token1 per token0 in human units. */
export function priceFromSqrtX96(sqrtPriceX96: bigint, decimals0: number, decimals1: number): number | null {
  if (sqrtPriceX96 <= 0n) return null;
  const s = Number(sqrtPriceX96) / TWO_96;
  const p = s * s * 10 ** (decimals0 - decimals1);
  return Number.isFinite(p) && p > 0 ? p : null;
}

/** DLMM bin price: (1 + binStep/10_000)^id raw, -> token1 per token0 in human units. */
export function priceFromBin(binId: number, binStepBps: number, decimals0: number, decimals1: number): number | null {
  if (!binStepBps) return null;
  const p = Math.exp(binId * Math.log1p(binStepBps / 10_000)) * 10 ** (decimals0 - decimals1);
  return Number.isFinite(p) && p > 0 ? p : null;
}

/** Execution price of a swap as token1 per token0 (human), from raw in/out amounts. */
export function priceFromAmounts(
  zeroForOne: boolean,
  amountIn: bigint,
  amountOut: bigint,
  decimals0: number,
  decimals1: number,
): number | null {
  if (amountIn <= 0n || amountOut <= 0n) return null;
  const amount0 = zeroForOne ? toHuman(amountIn, decimals0) : toHuman(amountOut, decimals0);
  const amount1 = zeroForOne ? toHuman(amountOut, decimals1) : toHuman(amountIn, decimals1);
  if (amount0 <= 0) return null;
  const p = amount1 / amount0;
  return Number.isFinite(p) && p > 0 ? p : null;
}

/** sqrt(1.0001^tick) as a float (raw price units). */
export function sqrtAtTick(tick: number): number {
  return Math.exp((tick / 2) * Math.log(1.0001));
}

function floorBig(x: number): bigint {
  if (!Number.isFinite(x) || x <= 0) return 0n;
  return BigInt(Math.floor(x));
}

/**
 * Token amounts held by `liquidity` in [tickLower, tickUpper] at the current sqrt price
 * (sqrtPriceX96 from the pool). Float math; used for TVL estimates of v4 liquidity changes.
 */
export function amountsForLiquidity(
  sqrtPriceX96: bigint,
  tickLower: number,
  tickUpper: number,
  liquidity: bigint,
): { amount0: bigint; amount1: bigint } {
  const neg = liquidity < 0n;
  const L = Number(neg ? -liquidity : liquidity);
  const sp = Number(sqrtPriceX96) / TWO_96;
  const sa = sqrtAtTick(tickLower);
  const sb = sqrtAtTick(tickUpper);
  let a0 = 0;
  let a1 = 0;
  if (!(sp > 0) || L === 0) return { amount0: 0n, amount1: 0n };
  if (sp <= sa) {
    a0 = (L * (sb - sa)) / (sa * sb);
  } else if (sp < sb) {
    a0 = (L * (sb - sp)) / (sp * sb);
    a1 = L * (sp - sa);
  } else {
    a1 = L * (sb - sa);
  }
  const amount0 = floorBig(a0);
  const amount1 = floorBig(a1);
  return neg ? { amount0: -amount0, amount1: -amount1 } : { amount0, amount1 };
}

/** USD value of a raw amount, or null when the price is unknown. */
export function usdValue(raw: bigint, decimals: number, priceUsd: number | null | undefined): number | null {
  if (priceUsd === null || priceUsd === undefined || !Number.isFinite(priceUsd)) return null;
  const v = toHuman(raw < 0n ? -raw : raw, decimals) * priceUsd;
  return Number.isFinite(v) ? v : null;
}

export type PriceSource = "stable" | "oracle" | "pool";

export interface PricedToken {
  decimals: number;
  price: number | null;
  source?: PriceSource | null;
}

const SOURCE_RANK: Record<PriceSource, number> = { stable: 3, oracle: 2, pool: 1 };

/**
 * USD notional of a swap. Uses the better-priced side (stable > oracle > pool-derived; tie -> token in).
 * Fee USD is the fee in token-in units times the token-in price, or the notional times fee/amountIn.
 */
export function swapUsd(
  amountIn: bigint,
  tokenIn: PricedToken | undefined,
  amountOut: bigint,
  tokenOut: PricedToken | undefined,
  feeAmount: bigint = 0n,
): { amountUsd: number | null; feeUsd: number | null } {
  const inUsd = tokenIn ? usdValue(amountIn, tokenIn.decimals, tokenIn.price) : null;
  const outUsd = tokenOut ? usdValue(amountOut, tokenOut.decimals, tokenOut.price) : null;
  let amountUsd: number | null = null;
  if (inUsd !== null && outUsd !== null) {
    const rIn = tokenIn?.source ? SOURCE_RANK[tokenIn.source] : 0;
    const rOut = tokenOut?.source ? SOURCE_RANK[tokenOut.source] : 0;
    amountUsd = rOut > rIn ? outUsd : inUsd;
  } else {
    amountUsd = inUsd ?? outUsd;
  }
  let feeUsd: number | null = null;
  if (feeAmount > 0n) {
    if (tokenIn && tokenIn.price !== null) feeUsd = usdValue(feeAmount, tokenIn.decimals, tokenIn.price);
    else if (amountUsd !== null && amountIn > 0n) feeUsd = amountUsd * (Number(feeAmount) / Number(amountIn));
  } else if (amountUsd !== null) {
    feeUsd = 0;
  }
  return { amountUsd, feeUsd };
}

/** Symbols treated as USD stables (priced at 1) unless the token is a launchpad token. */
export function isStableToken(symbol: string | null | undefined, kind: string | null | undefined): boolean {
  const k = (kind ?? "").toLowerCase();
  if (k === "usd" || k === "stable") return true;
  if (k === "launch") return false;
  const s = (symbol ?? "").toUpperCase();
  return /^(USD[A-Z0-9.]{0,4}|M?USDC|M?USDG|DAI|PYUSD|FRAX)$/.test(s) && s !== "USDOGE";
}

/** int to non-negative bigint string for numeric columns. */
export function big(v: bigint | number | string | null | undefined): string | null {
  if (v === null || v === undefined) return null;
  return BigInt(v).toString();
}
