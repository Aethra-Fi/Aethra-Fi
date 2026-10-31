"use client";

import * as React from "react";
import Link from "next/link";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { Plus, Search } from "lucide-react";
import { EmptyState, PageHeader, QueryState, Stat, StatGrid } from "@/components/kit";
import { Button } from "@/components/ui/button";
import { useDashboard } from "@/hooks/use-api";
import type { ApiDashboard, ApiPool } from "@/lib/api";
import { formatNumber, formatUsd } from "@/lib/format";
import { cn } from "@/lib/utils";
import { PoolTable } from "./pool-table";

const FILTERS = [
  { key: "all", label: "All" },
  { key: "trending", label: "Trending" },
  { key: "most_traded", label: "Most traded" },
  { key: "highest_volume", label: "Highest volume" },
  { key: "fresh", label: "New" },
  { key: "stock", label: "Stock pools" },
] as const;
type FilterKey = (typeof FILTERS)[number]["key"];

const VENUES = ["ALL", "V4", "DLMM", "DAMM"] as const;
const SOURCES = [
  { key: "all", label: "All sources" },
  { key: "aethra", label: "Aethra pools" },
  { key: "external", label: "External v4" },
] as const;
type SourceKey = (typeof SOURCES)[number]["key"];

function select(d: ApiDashboard, f: FilterKey): ApiPool[] {
  if (f === "stock") return d.all.filter((p) => p.token0.kind === "stock" || p.token1.kind === "stock");
  return d[f];
}

export function PoolsExplorer() {
  const params = useSearchParams();
  const router = useRouter();
  const pathname = usePathname();
  const dash = useDashboard();
  const filter = (FILTERS.find((f) => f.key === params.get("filter"))?.key ?? "all") as FilterKey;
  const [venue, setVenue] = React.useState<(typeof VENUES)[number]>("ALL");
  const [source, setSource] = React.useState<SourceKey>("all");
  const [q, setQ] = React.useState("");

  const setFilter = (key: FilterKey) => {
    const sp = new URLSearchParams(params);
    if (key === "all") sp.delete("filter");
    else sp.set("filter", key);
    router.replace(`${pathname}${sp.size ? `?${sp}` : ""}`, { scroll: false });
  };

  const s = dash.data?.stats;
  return (
    <>
      <PageHeader
        eyebrow="Pools"
        title="Liquidity pools"
        description="Discover Aethra pools across Uniswap v4 hooks, DLMM bins and DAMM ranges, next to the most active external Uniswap v4 pools on Robinhood Chain. Totals below count Aethra pools only."
        actions={
          <Button asChild>
            <Link href="/pools/create">
              <Plus /> Create pool
            </Link>
          </Button>
        }
      />
      <StatGrid className="mt-8">
        <Stat label="TVL" value={s ? formatUsd(s.tvl_usd, { compact: true }) : "—"} />
        <Stat label="24h volume" value={s ? formatUsd(s.volume_24h_usd, { compact: true }) : "—"} />
        <Stat label="24h trades" value={s ? formatNumber(s.trades_24h) : "—"} />
        <Stat label="Active pools" value={s ? s.pools : "—"} />
      </StatGrid>

      <div className="mt-8 flex flex-col gap-4 lg:flex-row lg:items-center lg:justify-between">
        <div className="flex flex-wrap gap-1 border-b lg:border-b-0" role="tablist">
          {FILTERS.map((f) => (
            <button
              key={f.key}
              role="tab"
              aria-selected={filter === f.key}
              onClick={() => setFilter(f.key)}
              className={cn(
                "-mb-px border-b-2 border-transparent px-3 py-2 font-mono text-[12px] uppercase tracking-button text-fg-2 transition-ui hover:text-fg",
                filter === f.key && "border-primary text-primary-text",
              )}
            >
              {f.label}
            </button>
          ))}
        </div>
        <div className="flex gap-2">
          <select
            value={source}
            onChange={(e) => setSource(e.target.value as SourceKey)}
            className="h-9 rounded-sm border bg-surface-2 px-2 font-mono text-[12px] uppercase"
            aria-label="Source"
          >
            {SOURCES.map((o) => (
              <option key={o.key} value={o.key}>
                {o.label}
              </option>
            ))}
          </select>
          <select
            value={venue}
            onChange={(e) => setVenue(e.target.value as (typeof VENUES)[number])}
            className="h-9 rounded-sm border bg-surface-2 px-2 font-mono text-[12px] uppercase"
            aria-label="Venue"
          >
            {VENUES.map((v) => (
              <option key={v} value={v}>
                {v === "ALL" ? "All venues" : v}
              </option>
            ))}
          </select>
          <label className="flex h-9 items-center gap-2 rounded-sm border bg-surface-2 px-2">
            <Search className="size-4 text-muted" />
            <input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Token or address" className="w-40 bg-transparent text-sm outline-none" />
          </label>
        </div>
      </div>

      <div className="mt-4">
        <QueryState query={dash} skeleton={<div className="skeleton h-96 w-full" />}>
          {(d) => {
            const needle = q.trim().toLowerCase();
            const rows = select(d, filter).filter(
              (p) =>
                (venue === "ALL" || p.venue === venue) &&
                (source === "all" || (source === "external") === !!p.external) &&
                (!needle ||
                  [p.token0.symbol, p.token1.symbol, p.token0.address, p.token1.address, p.pool_id].some((x) => x.toLowerCase().includes(needle))),
            );
            return rows.length ? (
              <PoolTable pools={rows} />
            ) : (
              <EmptyState title="No pools match" action={<Button asChild variant="secondary"><Link href="/pools/create">Create one</Link></Button>}>
                Try another filter, or create the first pool for this pair.
              </EmptyState>
            );
          }}
        </QueryState>
      </div>
    </>
  );
}
