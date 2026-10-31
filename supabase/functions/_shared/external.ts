// Discovery of external Uniswap v4 pools: pools on the PoolManager that do not use the Aethra hook.
// The chain holds hundreds of thousands of them and most are dust, so the indexer tracks a bounded watchlist:
// pools that traded recently, valued by the virtual reserve of a priced token, best first. Real TVL then comes
// from the events of the tracked pools, like any Aethra pool.
import { encodeAbiParameters, keccak256 } from "npm:viem@2.57.7";
import { toHuman } from "./math.ts";

export const NATIVE = "0x0000000000000000000000000000000000000000";
const Q96 = 2n ** 96n;

/** PoolManager `_pools` mapping slot (v4-core StateLibrary.POOLS_SLOT). */
const POOLS_SLOT = 6n;
/** Offsets inside `Pool.State`: slot0 first, active liquidity at +3. */
const LIQUIDITY_OFFSET = 3n;

export function poolStateSlot(poolId: string): bigint {
  return BigInt(keccak256(encodeAbiParameters([{ type: "bytes32" }, { type: "uint256" }], [poolId as `0x${string}`, POOLS_SLOT])));
}
export const liquiditySlot = (poolId: string): bigint => poolStateSlot(poolId) + LIQUIDITY_OFFSET;
export const slot0Slot = (poolId: string): bigint => poolStateSlot(poolId);

/** slot0 packs sqrtPriceX96 (160 bits), tick (24, signed), protocolFee (24), lpFee (24). */
export function decodeSlot0(word: bigint): { sqrtPriceX96: bigint; tick: number; lpFee: number } {
  const sqrtPriceX96 = word & ((1n << 160n) - 1n);
  let tick = Number((word >> 160n) & 0xffffffn);
  if (tick >= 0x800000) tick -= 0x1000000;
  const lpFee = Number((word >> 208n) & 0xffffffn);
  return { sqrtPriceX96, tick, lpFee };
}
export const decodeLiquidity = (word: bigint): bigint => word & ((1n << 128n) - 1n);

export interface PricedToken {
  decimals: number;
  priceUsd: number;
}

/**
 * Value of a pool's active liquidity in USD: the virtual reserve of the priced side at the current price, doubled
 * (a constant-product position holds equal value on both sides). It over-states narrow ranges, so it only ranks
 * candidates; TVL shown to users comes from events.
 */
export function virtualValueUsd(
  liquidity: bigint,
  sqrtPriceX96: bigint,
  token0: PricedToken | null,
  token1: PricedToken | null,
): number {
  if (liquidity <= 0n || sqrtPriceX96 <= 0n) return 0;
  // x = L / sqrtP, y = L * sqrtP (raw units)
  if (token0) return 2 * toHuman((liquidity * Q96) / sqrtPriceX96, token0.decimals) * token0.priceUsd;
  if (token1) return 2 * toHuman((liquidity * sqrtPriceX96) / Q96, token1.decimals) * token1.priceUsd;
  return 0;
}

export interface Candidate {
  id: string;
  currency0: string;
  currency1: string;
  hooks: string;
  fee: number;
  tickSpacing: number;
  createdBlock: number;
  sqrtPriceX96: bigint;
  tick: number;
  liquidity: bigint;
  swaps: number;
  valueUsd: number;
}

/** Best first by value; drops dust and pools nobody trades. */
export function selectTop(cands: Candidate[], opts: { minUsd: number; minSwaps: number; limit: number; exclude?: Set<string> }): Candidate[] {
  return cands
    .filter((c) => c.valueUsd >= opts.minUsd && c.swaps >= opts.minSwaps && !opts.exclude?.has(c.id))
    .sort((a, b) => b.valueUsd - a.valueUsd || b.swaps - a.swaps)
    .slice(0, opts.limit);
}
