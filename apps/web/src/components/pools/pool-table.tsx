"use client";

import Link from "next/link";
import { ExternalBadge, ModeBadge, PairLabel, Sparkline, VenueBadge } from "@/components/kit";
import { Badge } from "@/components/ui/badge";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import type { ApiPool } from "@/lib/api";
import { formatFeePips, formatNumber, formatPct, formatUsd } from "@/lib/format";
import { cn } from "@/lib/utils";

/** Phones get stacked cards (a 7-column table does not fit); md and up get the full table. */
function PoolCards({ pools }: { pools: ApiPool[] }) {
  return (
    <ul className="divide-y border md:hidden">
      {pools.map((p) => (
        <li key={p.pool_id}>
          <Link href={`/pools/${encodeURIComponent(p.pool_id)}`} className="block space-y-3 px-4 py-4 transition-ui hover:bg-surface-2 active:bg-surface-2">
            <div className="flex items-center justify-between gap-3">
              <span className="flex min-w-0 items-center gap-2">
                <PairLabel pool={p} />
                {p.is_fresh && <Badge variant="warning">New</Badge>}
                {!p.enabled && <Badge variant="danger">Paused</Badge>}
              </span>
              <Sparkline values={p.sparkline} volume={p.volume_sparkline} className="shrink-0" />
            </div>
            <div className="flex flex-wrap gap-1">
              <VenueBadge venue={p.venue} external={p.external} />
              <ModeBadge mode={p.mode} />
              <ExternalBadge pool={p} />
            </div>
            <dl className="grid grid-cols-4 gap-2">
              {[
                ["Fee", p.fee_pips === 0 && p.mode !== "plain" ? "Dynamic" : formatFeePips(p.fee_pips)],
                ["TVL", formatUsd(p.tvl_usd, { compact: true })],
                ["24h vol", formatUsd(p.volume_24h_usd, { compact: true })],
              ].map(([k, v]) => (
                <div key={k}>
                  <dt className="eyebrow">{k}</dt>
                  <dd className="num mt-0.5 text-sm">{v}</dd>
                </div>
              ))}
              <div>
                <dt className="eyebrow">24h</dt>
                <dd className={cn("num mt-0.5 text-sm", p.price_change_24h >= 0 ? "text-primary-text" : "text-danger")}>
                  {formatPct(p.price_change_24h, 2, { sign: true })}
                </dd>
              </div>
            </dl>
          </Link>
        </li>
      ))}
    </ul>
  );
}

export function PoolTable({ pools }: { pools: ApiPool[] }) {
  return (
    <>
      <PoolCards pools={pools} />
      <PoolTableDesktop pools={pools} />
    </>
  );
}

function PoolTableDesktop({ pools }: { pools: ApiPool[] }) {
  return (
    <div className="hidden overflow-x-auto border md:block">
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Pool</TableHead>
            <TableHead>Venue</TableHead>
            <TableHead className="text-right">Fee</TableHead>
            <TableHead className="text-right">TVL</TableHead>
            <TableHead className="text-right">24h volume</TableHead>
            <TableHead className="hidden text-right lg:table-cell">24h trades</TableHead>
            <TableHead className="text-right">24h change</TableHead>
            <TableHead className="hidden text-right md:table-cell">Last 24h</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {pools.map((p) => (
            <TableRow key={p.pool_id} className="relative">
              <TableCell>
                <Link href={`/pools/${encodeURIComponent(p.pool_id)}`} className="flex items-center gap-3 after:absolute after:inset-0">
                  <PairLabel pool={p} />
                  {p.is_fresh && <Badge variant="warning">New</Badge>}
                  {!p.enabled && <Badge variant="danger">Paused</Badge>}
                </Link>
              </TableCell>
              <TableCell>
                <span className="flex flex-wrap gap-1">
                  <VenueBadge venue={p.venue} external={p.external} />
                  <ModeBadge mode={p.mode} />
                  <ExternalBadge pool={p} />
                </span>
              </TableCell>
              <TableCell className="num text-right">{p.fee_pips === 0 && p.mode !== "plain" ? "Dynamic" : formatFeePips(p.fee_pips)}</TableCell>
              <TableCell className="num text-right">{formatUsd(p.tvl_usd, { compact: true })}</TableCell>
              <TableCell className="num text-right">{formatUsd(p.volume_24h_usd, { compact: true })}</TableCell>
              <TableCell className="num hidden text-right lg:table-cell">{formatNumber(p.trades_24h)}</TableCell>
              <TableCell className={cn("num text-right", p.price_change_24h >= 0 ? "text-primary-text" : "text-danger")}>
                {formatPct(p.price_change_24h, 2, { sign: true })}
              </TableCell>
              <TableCell className="hidden md:table-cell">
                <span className="flex justify-end">
                  <Sparkline values={p.sparkline} volume={p.volume_sparkline} />
                </span>
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </div>
  );
}
