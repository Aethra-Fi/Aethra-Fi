"use client";

import * as React from "react";
import Link from "next/link";
import { parseEther } from "viem";
import { useReadContract } from "wagmi";
import { ConnectGate, EmptyState, KV, NotDeployed, PageHeader, Panel, QueryState, TokenIcon, TxNotice } from "@/components/kit";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { useLaunches } from "@/hooks/use-api";
import { useTx } from "@/hooks/use-tx";
import type { ApiLaunch } from "@/lib/api";
import { ABIS, addressOf } from "@/lib/contracts";
import { formatBps, formatFeePips, formatTokenAmount, formatUsd, timeAgo } from "@/lib/format";
import { CHAIN_ID } from "@/lib/network";
import { cn } from "@/lib/utils";

const SORTS = [
  { k: "new", l: "New" },
  { k: "progress", l: "Near graduation" },
  { k: "volume", l: "24h volume" },
  { k: "graduated", l: "Graduated" },
] as const;

export function Progress({ value, className }: { value: number; className?: string }) {
  const pct = Math.max(0, Math.min(1, value)) * 100;
  return (
    <div className={cn("h-1.5 w-full bg-surface-2", className)} role="progressbar" aria-valuenow={Math.round(pct)} aria-valuemin={0} aria-valuemax={100}>
      <div className="h-full bg-primary transition-[width] duration-500 ease-out" style={{ width: `${pct}%` }} />
    </div>
  );
}

function LaunchCard({ l }: { l: ApiLaunch }) {
  return (
    <Link href={`/launch/${l.token}`} className="group block space-y-4 bg-surface p-5 transition-ui hover:bg-surface-2">
      <div className="flex items-center gap-3">
        <TokenIcon symbol={l.symbol} className="size-10 text-[11px]" />
        <div className="min-w-0 flex-1">
          <p className="truncate font-medium group-hover:text-primary-text">{l.name}</p>
          <p className="font-mono text-xs text-muted">${l.symbol}</p>
        </div>
        {l.graduated ? <Badge>Graduated</Badge> : <Badge variant="warning">Curve</Badge>}
      </div>
      <div>
        <div className="mb-1.5 flex justify-between font-mono text-[11px] uppercase tracking-button text-muted">
          <span>Bonding curve</span>
          <span className="num">{Math.round(l.progress * 100)}%</span>
        </div>
        <Progress value={l.graduated ? 1 : l.progress} />
      </div>
      <div className="grid grid-cols-3 gap-2 font-mono text-xs">
        <span>
          <span className="block text-muted">MCAP</span>
          {formatUsd(l.market_cap_usd, { compact: true })}
        </span>
        <span>
          <span className="block text-muted">24H VOL</span>
          {formatUsd(l.volume_24h_usd, { compact: true })}
        </span>
        <span>
          <span className="block text-muted">AGE</span>
          {timeAgo(l.created_at)}
        </span>
      </div>
    </Link>
  );
}

function CreateLaunch() {
  const launchpad = addressOf("launchpad");
  const [name, setName] = React.useState("");
  const [symbol, setSymbol] = React.useState("");
  const [meta, setMeta] = React.useState("");
  const [buy, setBuy] = React.useState("");
  const tx = useTx();
  if (!launchpad) return <NotDeployed name="Launchpad" />;
  let value = 0n;
  try {
    value = buy ? parseEther(buy) : 0n;
  } catch {
    value = 0n;
  }
  const valid = name.trim().length > 0 && /^[A-Za-z0-9]{1,11}$/.test(symbol);
  return (
    <div className="space-y-3">
      <Input placeholder="Name" value={name} onChange={(e) => setName(e.target.value)} maxLength={32} />
      <Input placeholder="Ticker (A–Z, 0–9)" value={symbol} onChange={(e) => setSymbol(e.target.value.toUpperCase())} maxLength={11} className="font-mono" />
      <Input placeholder="Metadata URI (optional, ipfs:// or https://)" value={meta} onChange={(e) => setMeta(e.target.value)} />
      <Input placeholder="First buy in ETH (optional)" inputMode="decimal" value={buy} onChange={(e) => setBuy(e.target.value)} className="num" />
      <p className="text-xs text-muted">1,000,000,000 supply. 800M sell on the curve; 200M pair with the raised ETH in a locked v4 pool at graduation.</p>
      <ConnectGate>
        <Button
          className="w-full"
          size="lg"
          disabled={!valid || tx.busy}
          onClick={() => tx.send({ address: launchpad, abi: ABIS.launchpad, functionName: "create", args: [name.trim(), symbol, meta.trim(), 0n], value })}
        >
          {tx.busy ? "Launching…" : "Launch token"}
        </Button>
      </ConnectGate>
      <TxNotice tx={tx} />
    </div>
  );
}

function LaunchConfig() {
  const launchpad = addressOf("launchpad");
  const cfg = useReadContract({ address: launchpad ?? undefined, abi: ABIS.launchpad, functionName: "config", chainId: CHAIN_ID, query: { enabled: !!launchpad } });
  const threshold = useReadContract({ address: launchpad ?? undefined, abi: ABIS.launchpad, functionName: "graduationThreshold", chainId: CHAIN_ID, query: { enabled: !!launchpad } });
  const c = cfg.data;
  return (
    <Panel title="How it works">
      <KV label="Curve" value="Virtual x·y = k" />
      <KV label="Trade fee" value={c ? formatFeePips(c.tradeFeePips) : "—"} />
      <KV label="Graduates at" value={threshold.data !== undefined ? `${formatTokenAmount(threshold.data, 18, 3)} ETH raised` : "—"} />
      <KV label="LP after graduation" value="Locked forever" />
      <KV label="Creator share of LP fees" value={c ? formatBps(c.creatorFeeBps) : "—"} />
    </Panel>
  );
}

export function LaunchList() {
  const q = useLaunches();
  const [sort, setSort] = React.useState<(typeof SORTS)[number]["k"]>("new");
  return (
    <>
      <PageHeader
        eyebrow="Launch"
        title="Launch markets"
        description="Fair bonding curves priced in ETH. When a curve sells out it graduates into a v4 hook pool with liquidity locked forever."
      />
      <div className="mt-8 grid gap-6 lg:grid-cols-[1fr_360px]">
        <div className="space-y-4">
          <div className="flex flex-wrap gap-1 border-b">
            {SORTS.map((s) => (
              <button
                key={s.k}
                onClick={() => setSort(s.k)}
                className={cn(
                  "-mb-px border-b-2 border-transparent px-3 py-2 font-mono text-[12px] uppercase tracking-button text-fg-2 hover:text-fg",
                  sort === s.k && "border-primary text-primary-text",
                )}
              >
                {s.l}
              </button>
            ))}
          </div>
          <QueryState query={q} isEmpty={(d) => d.length === 0} empty={<EmptyState title="No launches yet">Be the first: launch a token on the right.</EmptyState>}>
            {(rows) => {
              const list = [...rows]
                .filter((l) => (sort === "graduated" ? l.graduated : sort === "progress" ? !l.graduated : true))
                .sort((a, b) =>
                  sort === "progress" ? b.progress - a.progress : sort === "volume" ? b.volume_24h_usd - a.volume_24h_usd : +new Date(b.created_at) - +new Date(a.created_at),
                );
              return list.length ? (
                <div className="hairline-grid grid border sm:grid-cols-2 xl:grid-cols-3">
                  {list.map((l) => (
                    <LaunchCard key={l.token} l={l} />
                  ))}
                </div>
              ) : (
                <EmptyState title="Nothing in this view" />
              );
            }}
          </QueryState>
        </div>
        <div className="space-y-4">
          <Panel title="New launch" brackets>
            <CreateLaunch />
          </Panel>
          <LaunchConfig />
        </div>
      </div>
    </>
  );
}
