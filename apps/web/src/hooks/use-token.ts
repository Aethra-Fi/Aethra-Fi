"use client";

import { useMemo } from "react";
import { erc20Abi, maxUint256, type Address } from "viem";
import { useAccount, useBalance, useReadContract, useReadContracts } from "wagmi";
import { CHAIN_ID, DEPLOYMENT } from "@/lib/network";
import { useTokens } from "./use-api";
import type { ApiToken } from "@/lib/api";

export const NATIVE = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE" as const;
export const isNative = (a: string | undefined | null) => !!a && a.toLowerCase() === NATIVE.toLowerCase();

export interface TokenOption extends ApiToken {
  native?: boolean;
}

/** Token list = native ETH + SDK deployment tokens + indexer tokens (deduped by address). */
export function useTokenList(): { tokens: TokenOption[]; loading: boolean; offline: boolean } {
  const q = useTokens();
  const tokens = useMemo(() => {
    const map = new Map<string, TokenOption>();
    map.set(NATIVE.toLowerCase(), { address: NATIVE, symbol: "ETH", name: "Ether", decimals: 18, kind: "canonical", logo_url: null, native: true });
    map.set(DEPLOYMENT.weth.toLowerCase(), { address: DEPLOYMENT.weth, symbol: "WETH", name: "Wrapped Ether", decimals: 18, kind: "canonical", logo_url: null });
    for (const t of Object.values(DEPLOYMENT.tokens ?? {})) {
      map.set(t.address.toLowerCase(), { address: t.address, symbol: t.symbol, name: t.name, decimals: t.decimals, kind: t.kind, logo_url: t.logo ?? null });
    }
    for (const t of q.data ?? []) map.set(t.address.toLowerCase(), { ...map.get(t.address.toLowerCase()), ...t });
    return [...map.values()];
  }, [q.data]);
  return { tokens, loading: q.isLoading, offline: q.isError };
}

/** Balance of an ERC-20 (or native ETH) for the connected account. */
export function useTokenBalance(token: string | undefined) {
  const { address } = useAccount();
  const native = isNative(token);
  const nativeQ = useBalance({ address, chainId: CHAIN_ID, query: { enabled: Boolean(address && native) } });
  const erc = useReadContract({
    address: token as Address,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    chainId: CHAIN_ID,
    query: { enabled: Boolean(address && token && !native) },
  });
  return native ? { value: nativeQ.data?.value, isLoading: nativeQ.isLoading } : { value: erc.data, isLoading: erc.isLoading };
}

export function useAllowance(token: string | undefined, spender: Address | null | undefined) {
  const { address } = useAccount();
  const q = useReadContract({
    address: token as Address,
    abi: erc20Abi,
    functionName: "allowance",
    args: address && spender ? [address, spender] : undefined,
    chainId: CHAIN_ID,
    query: { enabled: Boolean(address && token && spender && !isNative(token)) },
  });
  return { allowance: isNative(token) ? maxUint256 : q.data, refetch: q.refetch, isLoading: q.isLoading };
}

/** Batch-read symbol/decimals for arbitrary token addresses (used where the indexer is not available). */
export function useTokenMeta(addresses: (string | undefined)[]) {
  const list = addresses.filter((a): a is string => !!a && !isNative(a));
  return useReadContracts({
    contracts: list.flatMap((a) => [
      { address: a as Address, abi: erc20Abi, functionName: "symbol", chainId: CHAIN_ID } as const,
      { address: a as Address, abi: erc20Abi, functionName: "decimals", chainId: CHAIN_ID } as const,
    ]),
    query: { enabled: list.length > 0 },
  });
}
