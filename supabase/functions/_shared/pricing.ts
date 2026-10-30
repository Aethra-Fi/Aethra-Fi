// USD price discovery: stables = 1, oracle assets from the hub, everything else through pools
// against an already priced token (e.g. WETH via WETH/USDC, then launch tokens via token/WETH).
import { isStableToken, type PriceSource, toHuman } from "./math.ts";

export interface PriceToken {
  address: string;
  symbol: string;
  kind: string;
  decimals: number;
  /** USD price from the hub oracle (already scaled from 1e18), if any. */
  oraclePrice?: number | null;
}

export interface PricePool {
  pool_id: string;
  venue: string;
  token0: string;
  token1: string;
  /** token1 per token0 in human units */
  price: number | null;
  reserve0: bigint;
  reserve1: bigint;
  enabled?: boolean;
}

export interface DerivedPrice {
  price: number;
  source: PriceSource;
  via?: string; // pool id for pool-derived prices
}

const NATIVE = "0x0000000000000000000000000000000000000000";

/**
 * Derive USD prices. Up to `maxHops` passes: each pass prices tokens that share a pool with a priced
 * token, picking the pool with the largest priced-side value (ties: any pool with a price).
 */
export function derivePrices(
  tokens: PriceToken[],
  pools: PricePool[],
  opts: { weth?: string | null; maxHops?: number } = {},
): Map<string, DerivedPrice> {
  const out = new Map<string, DerivedPrice>();
  const decimals = new Map<string, number>();
  for (const t of tokens) {
    decimals.set(t.address, t.decimals);
    if (isStableToken(t.symbol, t.kind)) out.set(t.address, { price: 1, source: "stable" });
    else if (t.oraclePrice && t.oraclePrice > 0 && Number.isFinite(t.oraclePrice)) {
      out.set(t.address, { price: t.oraclePrice, source: "oracle" });
    }
  }

  const usable = pools.filter((p) => p.enabled !== false && p.price !== null && p.price > 0 && Number.isFinite(p.price));
  const maxHops = opts.maxHops ?? 4;
  for (let hop = 0; hop < maxHops; hop++) {
    const best = new Map<string, { value: number; price: number; via: string }>();
    for (const p of usable) {
      const known0 = out.get(p.token0);
      const known1 = out.get(p.token1);
      if (known0 && known1) continue;
      if (!known0 && !known1) continue;
      if (known0) {
        // 1 token0 = price token1  =>  p1 = p0 / price
        const value = toHuman(p.reserve0, decimals.get(p.token0) ?? 18) * known0.price;
        const candidate = known0.price / (p.price as number);
        consider(best, p.token1, value, candidate, p.pool_id);
      } else if (known1) {
        const value = toHuman(p.reserve1, decimals.get(p.token1) ?? 18) * known1.price;
        const candidate = known1.price * (p.price as number);
        consider(best, p.token0, value, candidate, p.pool_id);
      }
    }
    if (best.size === 0) break;
    for (const [addr, b] of best) out.set(addr, { price: b.price, source: "pool", via: b.via });
  }

  // native ETH (v4 currency 0x0) follows WETH
  if (opts.weth && out.has(opts.weth) && !out.has(NATIVE)) out.set(NATIVE, { ...out.get(opts.weth)! });
  return out;
}

function consider(
  best: Map<string, { value: number; price: number; via: string }>,
  addr: string,
  value: number,
  price: number,
  via: string,
) {
  if (!Number.isFinite(price) || price <= 0) return;
  const cur = best.get(addr);
  if (!cur || value > cur.value) best.set(addr, { value, price, via });
}

/** Hub prices are 1e18-scaled. */
export function scaleE18(v: bigint): number | null {
  if (v <= 0n) return null;
  const n = toHuman(v, 18);
  return Number.isFinite(n) && n > 0 ? n : null;
}
