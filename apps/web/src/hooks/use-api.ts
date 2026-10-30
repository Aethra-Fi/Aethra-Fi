"use client";

import { keepPreviousData, useQuery } from "@tanstack/react-query";
import { api, type AnalyticsRange, type EventType } from "@/lib/api";
import { CHAIN_ID } from "@/lib/network";

const k = (...parts: unknown[]) => ["api", CHAIN_ID, ...parts] as const;

export function useHealth() {
  return useQuery({ queryKey: k("health"), queryFn: ({ signal }) => api.health(signal), refetchInterval: 30_000, retry: 0 });
}

export function usePools() {
  return useQuery({ queryKey: k("pools"), queryFn: ({ signal }) => api.pools(signal), staleTime: 30_000 });
}

export function usePool(poolId: string | undefined) {
  return useQuery({
    queryKey: k("pool", poolId),
    queryFn: ({ signal }) => api.pool(poolId!, signal),
    enabled: Boolean(poolId),
    refetchInterval: 30_000,
  });
}

export function useDashboard() {
  return useQuery({ queryKey: k("dashboard"), queryFn: ({ signal }) => api.dashboard(signal), refetchInterval: 60_000 });
}

export function useEvents(p: { limit?: number; type?: EventType | ""; pool?: string } = {}, live = true) {
  return useQuery({
    queryKey: k("events", p),
    queryFn: ({ signal }) => api.events(p, signal),
    refetchInterval: live ? 10_000 : false,
    placeholderData: keepPreviousData,
  });
}

export function useTokens() {
  return useQuery({ queryKey: k("tokens"), queryFn: ({ signal }) => api.tokens(signal), staleTime: 5 * 60_000 });
}

export function useLaunches() {
  return useQuery({ queryKey: k("launches"), queryFn: ({ signal }) => api.launches(signal), refetchInterval: 30_000 });
}

export function useAnalytics(range: AnalyticsRange) {
  return useQuery({
    queryKey: k("analytics", range),
    queryFn: ({ signal }) => api.analytics(range, signal),
    placeholderData: keepPreviousData,
  });
}

export function usePositionsApi(owner: string | undefined) {
  return useQuery({ queryKey: k("positions", owner), queryFn: ({ signal }) => api.positions(owner!, signal), enabled: Boolean(owner) });
}

export function useOrdersApi(owner: string | undefined) {
  return useQuery({ queryKey: k("orders", owner), queryFn: ({ signal }) => api.orders(owner!, signal), enabled: Boolean(owner), refetchInterval: 20_000 });
}

export function useLoansApi(owner: string | undefined) {
  return useQuery({ queryKey: k("loans", owner), queryFn: ({ signal }) => api.loans(owner!, signal), enabled: Boolean(owner) });
}

export function useBuybacks() {
  return useQuery({ queryKey: k("buybacks"), queryFn: ({ signal }) => api.buybacks(signal), refetchInterval: 60_000 });
}
