"use client";

import Link from "next/link";
import { ArrowLeftRight } from "lucide-react";
import { ThemedAreaChart } from "@/components/charts/area-chart";
import { EventTable } from "@/components/events/event-table";
import { AddressLink, EmptyState, KV, ModeBadge, PairLabel, Panel, QueryState, Stat, StatGrid, VenueBadge } from "@/components/kit";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { useEvents, usePool } from "@/hooks/use-api";
import type { ApiPoolDetail } from "@/lib/api";
import { formatBps, formatFeePips, formatNumber, formatPct, formatUsd, timeAgo } from "@/lib/format";
import { cn } from "@/lib/utils";
import { DepositPanel } from "./deposit";

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
        const series = (p.price_series ?? p.candles?.map((c) => ({ t: c.t, price: c.close })) ?? []).map((x) => ({ t: x.t, v: x.price }));
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
                <Panel title={`Price · ${p.token1.symbol} per ${p.token0.symbol}`}>
                  {series.length > 1 ? (
                    <ThemedAreaChart data={series} format={(v) => formatNumber(v, 5)} />
                  ) : (
                    <EmptyState title="No price history yet">The chart fills in as the indexer records swaps.</EmptyState>
                  )}
                </Panel>
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
