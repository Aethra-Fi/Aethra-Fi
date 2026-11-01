"use client";

import * as React from "react";
import Link from "next/link";
import { ArrowLeftRight } from "lucide-react";
import type { Address } from "viem";
import { useReadContracts } from "wagmi";
import { ThemedAreaChart, type Point } from "@/components/charts/area-chart";
import { ThemedBarChart } from "@/components/charts/bar-chart";
import { EventTable } from "@/components/events/event-table";
import { AddressLink, EmptyState, KV, ModeBadge, PairLabel, Panel, QueryState, Stat, StatGrid, VenueBadge } from "@/components/kit";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { useEvents, usePool } from "@/hooks/use-api";
import type { ApiPoolDetail } from "@/lib/api";
import { formatBps, formatFeePips, formatNumber, formatPct, formatUsd, timeAgo } from "@/lib/format";
import { cn } from "@/lib/utils";
import { ABIS } from "@/lib/contracts";
import { CHAIN_ID } from "@/lib/network";
import { priceFromBin } from "@/lib/dlmm";
import { DepositPanel } from "./deposit";

type ChartTab = "price" | "volume" | "tvl" | "fees";
const TABS: { key: ChartTab; label: string }[] = [
  { key: "price", label: "Price" },
  { key: "volume", label: "Volume" },
  { key: "tvl", label: "TVL" },
  { key: "fees", label: "Fees" },
];

/** Price, volume, TVL and fee history of one pool from its hourly stats (last 30 days). */
function PoolCharts({ pool }: { pool: ApiPoolDetail }) {
  const [tab, setTab] = React.useState<ChartTab>("price");
  const candles = pool.candles ?? [];
  const series: Record<ChartTab, Point[]> = {
    price: (pool.price_series ?? candles.map((c) => ({ t: c.t, price: c.close }))).map((x) => ({ t: x.t, v: x.price })),
    volume: candles.map((c) => ({ t: c.t, v: c.volume_usd ?? 0 })),
    tvl: candles.filter((c) => c.tvl_usd !== null && c.tvl_usd !== undefined).map((c) => ({ t: c.t, v: c.tvl_usd as number })),
    fees: candles.map((c) => ({ t: c.t, v: c.fees_usd ?? 0 })),
  };
  const data = series[tab];
  const usd = (v: number) => formatUsd(v, { compact: true });
  const title = tab === "price" ? `Price · ${pool.token1.symbol} per ${pool.token0.symbol}` : TABS.find((t) => t.key === tab)!.label;
  const empty = tab === "price" || tab === "tvl" ? data.length < 2 : !data.some((p) => p.v > 0);
  return (
    <Panel
      title={title}
      aside={
        <div className="flex border" role="tablist" aria-label="Chart">
          {TABS.map((t) => (
            <button
              key={t.key}
              role="tab"
              aria-selected={tab === t.key}
              onClick={() => setTab(t.key)}
              className={cn("px-2.5 py-1 font-mono text-[11px] uppercase tracking-button", tab === t.key ? "bg-surface-2 text-primary-text" : "text-fg-2 hover:text-fg")}
            >
              {t.label}
            </button>
          ))}
        </div>
      }
    >
      {empty ? (
        <EmptyState title={tab === "price" ? "No price history yet" : `No ${tab === "tvl" ? "TVL" : tab} recorded yet`}>
          The chart fills in as the indexer records activity in this pool.
        </EmptyState>
      ) : tab === "price" ? (
        <ThemedAreaChart data={data} format={(v) => formatNumber(v, 5)} />
      ) : tab === "tvl" ? (
        <ThemedAreaChart data={data} format={usd} />
      ) : (
        <ThemedBarChart data={data} format={usd} color={tab === "fees" ? "primary" : "accent"} />
      )}
    </Panel>
  );
}

const BIN_RADIUS = 20;

/** Liquidity around the active bin of a DLMM pool, valued in token1 (read from the pool contract). */
function BinLiquidity({ pool }: { pool: ApiPoolDetail }) {
  const active = pool.active_index;
  const step = pool.bin_step_bps ?? 0;
  const ids = active === null ? [] : Array.from({ length: BIN_RADIUS * 2 + 1 }, (_, i) => active - BIN_RADIUS + i);
  const bins = useReadContracts({
    contracts: ids.map((id) => ({ address: pool.pool_address as Address, abi: ABIS.dlmmPool, functionName: "getBin", args: [id], chainId: CHAIN_ID }) as const),
    query: { enabled: !!pool.pool_address && active !== null && step > 0, refetchInterval: 30_000 },
  });
  if (active === null || !step) return null;
  const d0 = pool.token0.decimals;
  const d1 = pool.token1.decimals;
  const data = ids.map((id, i) => {
    const r = bins.data?.[i]?.result as readonly [bigint, bigint, bigint] | undefined;
    const price = priceFromBin(id, step, d0, d1);
    const v = r ? (Number(r[0]) / 10 ** d0) * price + Number(r[1]) / 10 ** d1 : 0;
    return { t: String(id), v };
  });
  const fmt = (v: number) => `${formatNumber(v, 4)}`;
  return (
    <Panel title={`Liquidity by bin · in ${pool.token1.symbol}`} aside={<span className="font-mono text-xs text-muted">active bin {active}</span>}>
      {bins.isLoading ? (
        <div className="skeleton h-[220px] w-full" />
      ) : data.some((x) => x.v > 0) ? (
        <ThemedBarChart data={data} height={220} format={fmt} color="accent" highlight={String(active)} xFormat={(t) => `bin ${t} · ${formatNumber(priceFromBin(Number(t), step, d0, d1), 5)}`} />
      ) : (
        <EmptyState title="No liquidity near the active bin" />
      )}
      <p className="mt-3 text-xs text-muted">
        Bins below the active bin hold {pool.token1.symbol}, bins above hold {pool.token0.symbol}. The highlighted bar is the active bin, where swaps trade.
      </p>
    </Panel>
  );
}

function OraclePanel({ pool }: { pool: ApiPoolDetail }) {
  const o = pool.oracle;
  if (pool.mode !== "oracle" || !o) return null;
  const risk = o.risk ?? "NORMAL";
  return (
    <Panel title="Oracle guard" aside={<Badge variant={risk === "NORMAL" ? "default" : risk === "ELEVATED" ? "warning" : "danger"}>{risk}</Badge>}>
      <KV label="Reference price" value={formatUsd(o.reference_price_usd)} />
      <KV label="Pool price" value={formatUsd(o.pool_price_usd)} />
      <KV label="Deviation" value={formatBps(o.deviation_bps)} />
      <KV label="Market" value={o.market_open === null ? "—" : o.market_open ? "Open" : "Closed"} />
      <KV label="Fee multiplier" value={o.fee_multiplier ? `${o.fee_multiplier}×` : "—"} />
      <KV label="Feed updated" value={o.updated_at ? timeAgo(o.updated_at) : "—"} />
      <p className="mt-3 text-xs text-muted">
        Swaps toward the reference price pay the base fee; swaps away pay more. The circuit breaker reverts swaps that widen the
        gap past its limit, and swaps revert while the price feed is unavailable.
      </p>
    </Panel>
  );
}

export function PoolDetail({ poolId }: { poolId: string }) {
  const q = usePool(poolId);
  const events = useEvents({ pool: poolId, limit: 25 });
  return (
    <QueryState query={q} stateClassName="pt-10" skeleton={<div className="skeleton mt-10 h-[60vh] w-full" />} empty={<EmptyState title="Pool not found" />}>
      {(p) => {
        return (
          <>
            <div className="flex flex-col gap-4 border-b pb-8 pt-10 md:flex-row md:items-end md:justify-between">
              <div className="space-y-3">
                <p className="eyebrow">
                  <Link href="/pools" className="hover:text-primary-text">
                    Pools
                  </Link>{" "}
                  / {p.venue}
                </p>
                <div className="flex flex-wrap items-center gap-3 text-2xl">
                  <PairLabel pool={p} />
                  <VenueBadge venue={p.venue} external={p.external} />
                  <ModeBadge mode={p.mode} />
                  {!p.enabled && <Badge variant="danger">Paused</Badge>}
                </div>
              </div>
              {!p.external && (
                <Button asChild>
                  <Link href={`/swap?in=${p.token0.address}&out=${p.token1.address}`}>
                    <ArrowLeftRight /> Trade
                  </Link>
                </Button>
              )}
            </div>

            <StatGrid className="mt-8">
              <Stat label="TVL" value={formatUsd(p.tvl_usd, { compact: true })} />
              <Stat label="24h volume" value={formatUsd(p.volume_24h_usd, { compact: true })} />
              <Stat label="Current fee" value={p.fee_pips === 0 && p.mode !== "plain" ? "Dynamic" : formatFeePips(p.fee_pips)} hint={p.mode === "plain" ? "Fixed" : "Adapts to volatility"} />
              <Stat
                label="24h change"
                value={<span className={cn(p.price_change_24h >= 0 ? "text-primary-text" : "text-danger")}>{formatPct(p.price_change_24h, 2, { sign: true })}</span>}
              />
            </StatGrid>

            <div className="mt-8 grid gap-6 lg:grid-cols-[1.6fr_1fr]">
              <div className="space-y-6">
                <PoolCharts pool={p} />
                {p.venue === "DLMM" && <BinLiquidity pool={p} />}
                <div className="space-y-3">
                  <p className="eyebrow">Recent activity</p>
                  <QueryState query={events} isEmpty={(d) => d.length === 0} empty={<EmptyState title="No activity yet" />}>
                    {(rows) => <EventTable events={rows} showPool={false} />}
                  </QueryState>
                </div>
              </div>
              <div className="space-y-6">
                {p.external ? (
                  <Panel title="Uniswap v4 pool">
                    <p className="text-sm text-fg-2">
                      This Uniswap v4 pool does not use the Aethra hook. Aethra indexes it so you can compare markets, but swaps and
                      liquidity here go through the pool&apos;s own hook and the Uniswap v4 PoolManager, not the Aethra router. Figures are
                      rebuilt from on-chain events and can lag the chain by a few minutes.
                    </p>
                  </Panel>
                ) : (
                  <Panel title="Add liquidity" brackets>
                    <DepositPanel pool={p} />
                  </Panel>
                )}
                <OraclePanel pool={p} />
                <Panel title="Pool">
                  <KV label="Pool id" value={<span className="font-mono text-xs">{p.pool_id.slice(0, 10)}…</span>} />
                  {p.pool_address && <KV label="Contract" value={<AddressLink address={p.pool_address} />} />}
                  {p.hooks && <KV label="Hook" value={<AddressLink address={p.hooks} />} />}
                  <KV label={p.token0.symbol} value={<AddressLink address={p.token0.address} />} />
                  <KV label={p.token1.symbol} value={<AddressLink address={p.token1.address} />} />
                  {p.tick_spacing !== null && <KV label="Tick spacing" value={p.tick_spacing} />}
                  {p.bin_step_bps !== null && <KV label="Bin step" value={formatBps(p.bin_step_bps)} />}
                  <KV label="Creator" value={<AddressLink address={p.creator} />} />
                  {new Date(p.created_at).getFullYear() > 2000 && <KV label="Created" value={timeAgo(p.created_at)} />}
                </Panel>
              </div>
            </div>
          </>
        );
      }}
    </QueryState>
  );
}
