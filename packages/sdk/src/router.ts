import {
  type Address,
  type Hex,
  type PublicClient,
  encodeAbiParameters,
  encodeFunctionData,
  decodeFunctionResult,
  zeroAddress,
} from "viem";
import { Venue, type Hop, type PoolKey } from "./types.js";
import { aethraRouterAbi } from "./abis/aethraRouterAbi.js";

/** Minimal pool description used for route building (from the indexer API or on-chain discovery). */
export interface RoutablePool {
  venue: Venue;
  token0: Address;
  token1: Address;
  /** DLMM/DAMM pool address, or launchpad address for LAUNCH */
  address?: Address;
  /** V4 only */
  key?: PoolKey;
  /** LAUNCH only: the launch token */
  launchToken?: Address;
}

export interface QuotedRoute {
  hops: Hop[];
  amountOut: bigint;
  hopAmounts: bigint[];
}

const POOL_KEY_ABI = [
  {
    type: "tuple",
    components: [
      { name: "currency0", type: "address" },
      { name: "currency1", type: "address" },
      { name: "fee", type: "uint24" },
      { name: "tickSpacing", type: "int24" },
      { name: "hooks", type: "address" },
    ],
  },
] as const;

const same = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

export function sortTokens(a: Address, b: Address): [Address, Address] {
  return BigInt(a) < BigInt(b) ? [a, b] : [b, a];
}

export function encodePoolKey(key: PoolKey): Hex {
  return encodeAbiParameters(POOL_KEY_ABI, [key]);
}

/** Build the router hop for trading `tokenIn -> tokenOut` through `pool`. */
export function hopFor(pool: RoutablePool, tokenIn: Address, tokenOut: Address): Hop {
  const touches =
    (same(pool.token0, tokenIn) && same(pool.token1, tokenOut)) ||
    (same(pool.token1, tokenIn) && same(pool.token0, tokenOut));
  if (!touches) throw new Error("pool does not trade this pair");
  switch (pool.venue) {
    case Venue.V4:
      if (!pool.key) throw new Error("v4 pool needs a PoolKey");
      return { venue: Venue.V4, pool: zeroAddress, tokenIn, tokenOut, data: encodePoolKey(pool.key) };
    case Venue.DLMM:
    case Venue.DAMM:
      if (!pool.address) throw new Error("pool address missing");
      return { venue: pool.venue, pool: pool.address, tokenIn, tokenOut, data: "0x" };
    case Venue.LAUNCH:
      if (!pool.address || !pool.launchToken) throw new Error("launch pool needs launchpad + token");
      return {
        venue: Venue.LAUNCH,
        pool: pool.address,
        tokenIn,
        tokenOut,
        data: encodeAbiParameters([{ type: "address" }], [pool.launchToken]),
      };
    default:
      throw new Error(`unsupported venue ${pool.venue}`);
  }
}

/**
 * Enumerate candidate routes: every direct pool, plus two-hop routes through each intermediate token
 * (typically WETH and the USD stable). Routes are capped to keep quoting cheap.
 */
export function candidateRoutes(
  pools: RoutablePool[],
  tokenIn: Address,
  tokenOut: Address,
  intermediates: Address[],
  maxRoutes = 24,
): Hop[][] {
  const trades = (p: RoutablePool, a: Address, b: Address) =>
    (same(p.token0, a) && same(p.token1, b)) || (same(p.token1, a) && same(p.token0, b));
  const routes: Hop[][] = [];
  for (const p of pools) if (trades(p, tokenIn, tokenOut)) routes.push([hopFor(p, tokenIn, tokenOut)]);
  for (const mid of intermediates) {
    if (same(mid, tokenIn) || same(mid, tokenOut)) continue;
    const first = pools.filter((p) => trades(p, tokenIn, mid));
    const second = pools.filter((p) => trades(p, mid, tokenOut));
    for (const a of first) for (const b of second) routes.push([hopFor(a, tokenIn, mid), hopFor(b, mid, tokenOut)]);
  }
  return routes.slice(0, maxRoutes);
}

/**
 * Quote every candidate route with the on-chain router (eth_call of `quote`) and return them sorted by output.
 * Failing or zero-output routes are dropped.
 */
export async function quoteRoutes(
  client: PublicClient,
  router: Address,
  routes: Hop[][],
  amountIn: bigint,
): Promise<QuotedRoute[]> {
  const results = await Promise.all(
    routes.map(async (hops) => {
      try {
        const { data } = await client.call({
          to: router,
          data: encodeFunctionData({ abi: aethraRouterAbi, functionName: "quote", args: [hops, amountIn] }),
        });
        if (!data) return null;
        const [amountOut, hopAmounts] = decodeFunctionResult({
          abi: aethraRouterAbi,
          functionName: "quote",
          data,
        }) as readonly [bigint, readonly bigint[]];
        if (amountOut === 0n) return null;
        return { hops, amountOut, hopAmounts: [...hopAmounts] } satisfies QuotedRoute;
      } catch {
        return null;
      }
    }),
  );
  return results.filter((r): r is QuotedRoute => r !== null).sort((a, b) => (b.amountOut > a.amountOut ? 1 : -1));
}

/** Best route or null. */
export async function findBestRoute(
  client: PublicClient,
  router: Address,
  pools: RoutablePool[],
  tokenIn: Address,
  tokenOut: Address,
  amountIn: bigint,
  intermediates: Address[],
): Promise<QuotedRoute | null> {
  const routes = candidateRoutes(pools, tokenIn, tokenOut, intermediates);
  const quoted = await quoteRoutes(client, router, routes, amountIn);
  return quoted[0] ?? null;
}

/** Apply slippage (in bps) to an expected output. */
export function minOut(amountOut: bigint, slippageBps: number): bigint {
  return (amountOut * BigInt(10_000 - Math.round(slippageBps))) / 10_000n;
}
