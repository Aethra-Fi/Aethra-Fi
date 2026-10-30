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

/** Phones get stacked cards; the 7-column table only fits from md up. */
function EventCards({ events, showPool }: { events: ApiEvent[]; showPool: boolean }) {
  return (
    <ul className="divide-y border md:hidden">
      {events.map((e) => (
        <li key={`${e.tx_hash}-${e.log_index}`} className="space-y-2 px-4 py-3">
          <div className="flex items-center justify-between gap-3">
            <span className="flex flex-wrap items-center gap-1.5">
              <Badge variant={TYPE_VARIANT[e.type] ?? "neutral"}>{e.name}</Badge>
              {showPool && e.venue && <VenueBadge venue={e.venue} />}
            </span>
            <span className="num shrink-0 text-xs text-muted">{timeAgo(e.timestamp)}</span>
          </div>
          {e.summary && <p className="break-words text-sm text-fg-2">{e.summary}</p>}
          <div className="flex items-center justify-between gap-3 text-xs">
            <span className="num">{formatUsd(e.amount_usd)}</span>
            <span className="flex items-center gap-3">
              <AddressLink address={e.actor} />
              <TxLink hash={e.tx_hash} />
            </span>
          </div>
        </li>
      ))}
    </ul>
  );
}

export function EventTable({ events, showPool = true }: { events: ApiEvent[]; showPool?: boolean }) {
  return (
    <>
      <EventCards events={events} showPool={showPool} />
      <EventTableDesktop events={events} showPool={showPool} />
    </>
  );
}

function EventTableDesktop({ events, showPool }: { events: ApiEvent[]; showPool: boolean }) {
  return (
    <div className="hidden overflow-x-auto border md:block">
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
