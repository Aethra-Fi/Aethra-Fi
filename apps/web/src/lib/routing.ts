import { encodeAbiParameters, type Address, type Hex } from "viem";
import { Venue } from "@aethra/sdk";
import type { ApiPool } from "./api";
import { DYNAMIC_FEE_FLAG } from "./v4math";
import { poolKeyComponents } from "./abis/shared";

export interface RouteHop {
  venue: number;
  pool: Address;
  tokenIn: Address;
  tokenOut: Address;
  data: Hex;
}

export interface CandidateRoute {
  hops: RouteHop[];
  pools: ApiPool[];
  /** token symbols along the path, e.g. ["WETH", "USDG", "TSLA"] */
  path: string[];
}

const ZERO: Address = "0x0000000000000000000000000000000000000000";
const VENUE: Record<ApiPool["venue"], Venue> = { V4: Venue.V4, DLMM: Venue.DLMM, DAMM: Venue.DAMM, LAUNCH: Venue.LAUNCH };

const eq = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

/**
 * PoolKey for a v4 pool record. Hook pools in dynamic/oracle mode use the dynamic-fee flag.
 * NOTE(lead): confirm against the hook's PoolKey convention once AethraHook is final.
 */
export function poolKeyFromApi(p: ApiPool) {
  const hooks = (p.hooks ?? ZERO) as Address;
  const dynamic = hooks !== ZERO && p.mode !== "plain";
  return {
    currency0: p.token0.address as Address,
    currency1: p.token1.address as Address,
    fee: dynamic ? DYNAMIC_FEE_FLAG : p.fee_pips,
    tickSpacing: p.tick_spacing ?? 60,
    hooks,
  };
}

export function hopForPool(p: ApiPool, tokenIn: string, launchpad: Address | null): RouteHop | null {
  const tokenOut = eq(p.token0.address, tokenIn) ? p.token1.address : eq(p.token1.address, tokenIn) ? p.token0.address : null;
  if (!tokenOut) return null;
  const venue = VENUE[p.venue];
  let data: Hex = "0x";
  let pool: Address = (p.pool_address ?? ZERO) as Address;
  if (p.venue === "V4") {
    data = encodeAbiParameters([{ type: "tuple", components: poolKeyComponents }], [poolKeyFromApi(p)]);
    pool = ZERO;
  } else if (p.venue === "LAUNCH") {
    if (!launchpad) return null;
    pool = launchpad;
    const launchToken = p.token0.kind === "launch" ? p.token0.address : p.token1.address;
    data = encodeAbiParameters([{ type: "address" }], [launchToken as Address]);
  } else if (!p.pool_address) return null;
  return { venue, pool, tokenIn: tokenIn as Address, tokenOut: tokenOut as Address, data };
}

/** Direct and one-intermediate routes between two tokens over enabled pools (max `limit` candidates). */
export function candidateRoutes(
  pools: ApiPool[],
  tokenIn: string,
  tokenOut: string,
  launchpad: Address | null,
  limit = 8,
): CandidateRoute[] {
  const live = pools.filter((p) => p.enabled);
  const has = (p: ApiPool, t: string) => eq(p.token0.address, t) || eq(p.token1.address, t);
  const other = (p: ApiPool, t: string) => (eq(p.token0.address, t) ? p.token1 : p.token0);
  const out: CandidateRoute[] = [];
  for (const p of live) {
    if (has(p, tokenIn) && has(p, tokenOut)) {
      const h = hopForPool(p, tokenIn, launchpad);
      if (h) out.push({ hops: [h], pools: [p], path: [symbolOf(p, tokenIn), symbolOf(p, tokenOut)] });
    }
  }
  for (const a of live) {
    if (!has(a, tokenIn) || has(a, tokenOut)) continue;
    const mid = other(a, tokenIn);
    for (const b of live) {
      if (b === a || !has(b, mid.address) || !has(b, tokenOut)) continue;
      const h1 = hopForPool(a, tokenIn, launchpad);
      const h2 = hopForPool(b, mid.address, launchpad);
      if (h1 && h2) out.push({ hops: [h1, h2], pools: [a, b], path: [symbolOf(a, tokenIn), mid.symbol, symbolOf(b, tokenOut)] });
    }
  }
  // prefer deeper pools first so the quote budget goes to likely winners
  const depth = (r: CandidateRoute) => Math.min(...r.pools.map((p) => p.tvl_usd || 0));
  return out.sort((x, y) => depth(y) - depth(x) || x.hops.length - y.hops.length).slice(0, limit);
}

function symbolOf(p: ApiPool, addr: string): string {
  return eq(p.token0.address, addr) ? p.token0.symbol : p.token1.symbol;
}

export function minReceived(amountOut: bigint, slippagePct: number): bigint {
  const bps = BigInt(Math.round(slippagePct * 100));
  return (amountOut * (10_000n - bps)) / 10_000n;
}

export const VENUE_LABEL: Record<string, string> = {
  V4: "v4 hook pool",
  DLMM: "DLMM bins",
  DAMM: "DAMM range",
  LAUNCH: "Launch curve",
};
