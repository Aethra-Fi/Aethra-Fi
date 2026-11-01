"use client";

import * as React from "react";
import { ThemedAreaChart } from "@/components/charts/area-chart";
import { ThemedBarChart } from "@/components/charts/bar-chart";
import { PageHeader, Panel, QueryState, Stat, StatGrid, VenueBadge } from "@/components/kit";
import { PoolTable } from "@/components/pools/pool-table";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { useAnalytics } from "@/hooks/use-api";
import type { AnalyticsRange } from "@/lib/api";
import { formatNumber, formatPct, formatUsd } from "@/lib/format";
import { cn } from "@/lib/utils";

const RANGES: AnalyticsRange[] = ["24h", "7d", "30d"];
const usd = (v: number) => formatUsd(v, { compact: true });

/** Horizontal share bar with its percentage. */
function ShareBar({ share }: { share: number }) {
  return (
    <div className="flex items-center gap-2">
      <div className="h-1.5 flex-1 bg-surface-2">
        <div className="h-full bg-primary" style={{ width: `${Math.min(100, Math.max(0, share * 100))}%` }} />
      </div>
      <span className="num w-12 text-right text-xs text-muted">{formatPct(share * 100, 1)}</span>
    </div>
  );
}

export function AnalyticsView() {
  const [range, setRange] = React.useState<AnalyticsRange>("7d");
  const q = useAnalytics(range);
  return (
    <>
      <PageHeader
        eyebrow="Analytics"
        title="Protocol analytics"
        description="Protocol-wide TVL, volume and fees with a per-venue breakdown, sourced from the Aethra indexer."
        actions={
          <div className="flex border">
            {RANGES.map((r) => (
              <button
                key={r}
                onClick={() => setRange(r)}
                className={cn("px-3 py-2 font-mono text-[12px] uppercase tracking-button", r === range ? "bg-surface-2 text-primary-text" : "text-fg-2 hover:text-fg")}
              >
                {r}
              </button>
            ))}
          </div>
        }
      />
      <div className="mt-8">
        <QueryState query={q} skeleton={<div className="skeleton h-[70vh]" />}>
          {(d) => {
            const sum = (k: "volume_usd" | "fees_usd" | "trades") => d.series.reduce((a, p) => a + (p[k] ?? 0), 0);
            const last = d.series[d.series.length - 1];
            const hourly = range === "24h";
            const of = (k: "tvl_usd" | "volume_usd" | "fees_usd" | "trades") => d.series.map((p) => ({ t: p.t, v: p[k] ?? 0 }));
            const venueTvl = d.venues.reduce((a, v) => a + v.tvl_usd, 0);
            return (
              <div className="space-y-6">
                <StatGrid>
                  <Stat label="TVL" value={usd(last?.tvl_usd ?? 0)} />
                  <Stat label={`Volume · ${range}`} value={usd(sum("volume_usd"))} />
                  <Stat label={`Fees · ${range}`} value={usd(sum("fees_usd"))} />
                  <Stat label={`Trades · ${range}`} value={formatNumber(sum("trades"))} hint={`${d.venues.length} venues`} />
                </StatGrid>
                <div className="grid gap-6 lg:grid-cols-2">
                  <Panel title="TVL">
                    <ThemedAreaChart data={of("tvl_usd")} format={usd} />
                  </Panel>
                  <Panel title="Volume">
                    <ThemedBarChart data={of("volume_usd")} format={usd} hourly={hourly} />
                  </Panel>
                  <Panel title="Fees">
                    <ThemedBarChart data={of("fees_usd")} format={usd} color="primary" hourly={hourly} />
                  </Panel>
                  <Panel title="Trades">
                    <ThemedBarChart data={of("trades")} format={(v) => formatNumber(v)} hourly={hourly} />
                  </Panel>
                </div>
                <Panel title="Venue breakdown">
                  <div className="-m-4">
                  <Table>
                    <TableHeader>
                      <TableRow>
                        <TableHead>Venue</TableHead>
                        <TableHead className="text-right">TVL</TableHead>
                        <TableHead className="hidden w-[28%] sm:table-cell">TVL share</TableHead>
                        <TableHead className="text-right">Volume</TableHead>
                        <TableHead className="text-right">Fees</TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {d.venues.map((v) => (
                        <TableRow key={v.venue}>
                          <TableCell>
                            <VenueBadge venue={v.venue} />
                          </TableCell>
                          <TableCell className="num text-right">{usd(v.tvl_usd)}</TableCell>
                          <TableCell className="hidden sm:table-cell">
                            <ShareBar share={venueTvl > 0 ? v.tvl_usd / venueTvl : 0} />
                          </TableCell>
                          <TableCell className="num text-right">{usd(v.volume_usd)}</TableCell>
                          <TableCell className="num text-right">{usd(v.fees_usd)}</TableCell>
                        </TableRow>
                      ))}
                    </TableBody>
                  </Table>
                  </div>
                </Panel>
                <div className="space-y-3">
                  <p className="eyebrow">Top pools</p>
                  <PoolTable pools={d.top_pools} />
                </div>
              </div>
            );
          }}
        </QueryState>
      </div>
    </>
  );
}
