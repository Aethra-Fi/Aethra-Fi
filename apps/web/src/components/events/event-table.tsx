"use client";

import { AddressLink, TxLink, VenueBadge } from "@/components/kit";
import { Badge } from "@/components/ui/badge";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import type { ApiEvent } from "@/lib/api";
import { formatUsd, timeAgo } from "@/lib/format";

const TYPE_VARIANT = {
  swap: "default",
  liquidity: "accent",
  launch: "warning",
  order: "neutral",
  loan: "outline",
  buyback: "default",
} as const;

export function EventTable({ events, showPool = true }: { events: ApiEvent[]; showPool?: boolean }) {
  return (
    <div className="overflow-x-auto border">
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Event</TableHead>
            {showPool && <TableHead>Venue</TableHead>}
            <TableHead>Details</TableHead>
            <TableHead className="text-right">Value</TableHead>
            <TableHead>Account</TableHead>
            <TableHead>Tx</TableHead>
            <TableHead className="text-right">Age</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {events.map((e) => (
            <TableRow key={`${e.tx_hash}-${e.log_index}`} className="animate-rise">
              <TableCell>
                <Badge variant={TYPE_VARIANT[e.type] ?? "neutral"}>{e.name}</Badge>
              </TableCell>
              {showPool && <TableCell>{e.venue ? <VenueBadge venue={e.venue} /> : <span className="text-muted">—</span>}</TableCell>}
              <TableCell className="max-w-xs truncate text-sm text-fg-2">{e.summary ?? "—"}</TableCell>
              <TableCell className="num text-right">{formatUsd(e.amount_usd)}</TableCell>
              <TableCell>
                <AddressLink address={e.actor} />
              </TableCell>
              <TableCell>
                <TxLink hash={e.tx_hash} />
              </TableCell>
              <TableCell className="num text-right text-muted">{timeAgo(e.timestamp)}</TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </div>
  );
}
