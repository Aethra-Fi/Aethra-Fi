"use client";

import Link from "next/link";
import { ModeBadge, PairLabel, Sparkline, VenueBadge } from "@/components/kit";
import { Badge } from "@/components/ui/badge";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import type { ApiPool } from "@/lib/api";
import { formatFeePips, formatNumber, formatPct, formatUsd } from "@/lib/format";
import { cn } from "@/lib/utils";

export function PoolTable({ pools }: { pools: ApiPool[] }) {
  return (
    <div className="overflow-x-auto border">
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Pool</TableHead>
            <TableHead>Venue</TableHead>
            <TableHead className="text-right">Fee</TableHead>
            <TableHead className="text-right">TVL</TableHead>
            <TableHead className="text-right">24h volume</TableHead>
            <TableHead className="text-right">24h trades</TableHead>
            <TableHead className="text-right">24h</TableHead>
            <TableHead className="hidden text-right md:table-cell">7d</TableHead>
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
                  <VenueBadge venue={p.venue} />
                  <ModeBadge mode={p.mode} />
                </span>
              </TableCell>
              <TableCell className="num text-right">{p.fee_pips === 0 && p.mode !== "plain" ? "Dynamic" : formatFeePips(p.fee_pips)}</TableCell>
              <TableCell className="num text-right">{formatUsd(p.tvl_usd, { compact: true })}</TableCell>
              <TableCell className="num text-right">{formatUsd(p.volume_24h_usd, { compact: true })}</TableCell>
              <TableCell className="num text-right">{formatNumber(p.trades_24h)}</TableCell>
              <TableCell className={cn("num text-right", p.price_change_24h >= 0 ? "text-primary-text" : "text-danger")}>
                {formatPct(p.price_change_24h, 2, { sign: true })}
              </TableCell>
              <TableCell className="hidden md:table-cell">
                <span className="flex justify-end">
                  <Sparkline values={p.sparkline} />
                </span>
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </div>
  );
}
