"use client";

import * as React from "react";
import { EventTable } from "@/components/events/event-table";
import { EmptyState, PageHeader, QueryState, StatusDot } from "@/components/kit";
import { useEvents } from "@/hooks/use-api";
import type { EventType } from "@/lib/api";
import { cn } from "@/lib/utils";

const TYPES: { k: EventType | ""; l: string }[] = [
  { k: "", l: "All" },
  { k: "swap", l: "Swaps" },
  { k: "liquidity", l: "Liquidity" },
  { k: "order", l: "Orders" },
];

export function EventsView() {
  const [type, setType] = React.useState<EventType | "">("");
  const [live, setLive] = React.useState(true);
  const q = useEvents({ type, limit: 100 }, live);
  return (
    <>
      <PageHeader
        eyebrow="Event feed"
        title="On-chain activity"
        description="Every swap, deposit and order across Aethra, newest first."
        actions={
          <button onClick={() => setLive((v) => !v)} className="flex items-center gap-2 border px-3 py-2 font-mono text-[12px] uppercase tracking-button">
            <StatusDot state={live ? "live" : "idle"} />
            {live ? "Live" : "Paused"}
          </button>
        }
      />
      <div className="mt-8 flex flex-wrap gap-1 border-b">
        {TYPES.map((t) => (
          <button
            key={t.k}
            onClick={() => setType(t.k)}
            className={cn("-mb-px border-b-2 border-transparent px-3 py-2 font-mono text-[12px] uppercase tracking-button text-fg-2 hover:text-fg", type === t.k && "border-primary text-primary-text")}
          >
            {t.l}
          </button>
        ))}
      </div>
      <div className="mt-4">
        <QueryState query={q} isEmpty={(d) => d.length === 0} empty={<EmptyState title="No events yet" />}>
          {(rows) => <EventTable events={rows} />}
        </QueryState>
      </div>
    </>
  );
}
