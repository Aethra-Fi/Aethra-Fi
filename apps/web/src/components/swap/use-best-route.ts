"use client";

import { useQuery } from "@tanstack/react-query";
import type { Address } from "viem";
import { usePublicClient } from "wagmi";
import { usePools } from "@/hooks/use-api";
import { ABIS, addressOf } from "@/lib/contracts";
import { CHAIN_ID, DEPLOYMENT } from "@/lib/network";
import { candidateRoutes, type CandidateRoute } from "@/lib/routing";
import { isNative } from "@/hooks/use-token";

export interface QuotedRoute extends CandidateRoute {
  amountOut: bigint;
  hopAmounts: readonly bigint[];
}

/** Router address used for both quoting and swapping. */
export const ROUTER = addressOf("router");

/** The router speaks ERC-20 only; native ETH routes through WETH. */
export const asErc20 = (a: string) => (isNative(a) ? DEPLOYMENT.weth : a);

/**
 * Quote every candidate route through `router.quote` over eth_call and return them best first.
 * v4 quotes revert-and-decode inside the router, so quote is a non-view call simulated here.
 */
export function useBestRoute(tokenIn: string | undefined, tokenOut: string | undefined, amountIn: bigint | null) {
  const pools = usePools();
  const client = usePublicClient({ chainId: CHAIN_ID });
  const launchpad = addressOf("launchpad");
  const a = tokenIn && asErc20(tokenIn);
  const b = tokenOut && asErc20(tokenOut);
  const sameWrapped = !!a && !!b && a.toLowerCase() === b.toLowerCase();

  const q = useQuery({
    queryKey: ["route", CHAIN_ID, a, b, amountIn?.toString(), pools.dataUpdatedAt],
    enabled: Boolean(client && ROUTER && a && b && !sameWrapped && amountIn && amountIn > 0n && pools.data),
    refetchInterval: 15_000,
    queryFn: async (): Promise<QuotedRoute[]> => {
      const candidates = candidateRoutes(pools.data!, a!, b!, launchpad);
      const settled = await Promise.allSettled(
        candidates.map(async (r) => {
          const { result } = await client!.simulateContract({
            address: ROUTER!,
            abi: ABIS.router,
            functionName: "quote",
            args: [r.hops.map((h) => ({ ...h, pool: h.pool as Address })), amountIn!],
          });
          const [amountOut, hopAmounts] = result;
          return { ...r, amountOut, hopAmounts } satisfies QuotedRoute;
        }),
      );
      return settled
        .flatMap((s) => (s.status === "fulfilled" && s.value.amountOut > 0n ? [s.value] : []))
        .sort((x, y) => (y.amountOut > x.amountOut ? 1 : y.amountOut < x.amountOut ? -1 : x.hops.length - y.hops.length));
    },
  });

  return {
    routes: q.data ?? [],
    best: q.data?.[0],
    isQuoting: q.isFetching,
    poolsState: pools,
    wrapOnly: sameWrapped && tokenIn?.toLowerCase() !== tokenOut?.toLowerCase(),
    error: q.error as Error | null,
  };
}
