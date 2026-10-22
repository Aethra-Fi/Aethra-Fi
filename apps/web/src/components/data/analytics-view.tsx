"use client";

import * as React from "react";
import { ThemedAreaChart } from "@/components/charts/area-chart";
import { PageHeader, Panel, QueryState, Stat, StatGrid, VenueBadge } from "@/components/kit";
import { PoolTable } from "@/components/pools/pool-table";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { useAnalytics } from "@/hooks/use-api";
import type { AnalyticsRange } from "@/lib/api";
import { formatUsd } from "@/lib/format";
import { cn } from "@/lib/utils";

const RANGES: AnalyticsRange[] = ["24h", "7d", "30d", "90d"];
const usd = (v: number) => formatUsd(v, { compact: true });

export function AnalyticsView() {
  const [range, setRange] = React.useState<AnalyticsRange>("7d");
  const q = useAnalytics(range);
  return (
    <>
      <PageHeader
        eyebrow="Analytics"
        title="Protocol analytics"
        description="TVL, volume and fees across every venue, from the Aethra indexer."
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
            const sum = (k: "volume_usd" | "fees_usd") => d.series.reduce((a, p) => a + p[k], 0);
            const last = d.series[d.series.length - 1];
            return (
              <div className="space-y-6">
                <StatGrid>
                  <Stat label="TVL" value={usd(last?.tvl_usd ?? 0)} />
                  <Stat label={`Volume · ${range}`} value={usd(sum("volume_usd"))} />
                  <Stat label={`Fees · ${range}`} value={usd(sum("fees_usd"))} />
                  <Stat label="Venues" value={d.venues.length} />
                </StatGrid>
                <div className="grid gap-6 lg:grid-cols-2">
                  <Panel title="TVL">
                    <ThemedAreaChart data={d.series.map((p) => ({ t: p.t, v: p.tvl_usd }))} format={usd} />
                  </Panel>
                  <Panel title="Volume">
                    <ThemedAreaChart data={d.series.map((p) => ({ t: p.t, v: p.volume_usd }))} format={usd} color="accent" />
                  </Panel>
                </div>
                <Panel title="By venue">
                  <Table>
                    <TableHeader>
                      <TableRow>
                        <TableHead>Venue</TableHead>
                        <TableHead className="text-right">TVL</TableHead>
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
                          <TableCell className="num text-right">{usd(v.volume_usd)}</TableCell>
                          <TableCell className="num text-right">{usd(v.fees_usd)}</TableCell>
                        </TableRow>
                      ))}
                    </TableBody>
                  </Table>
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
