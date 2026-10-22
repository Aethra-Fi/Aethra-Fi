"use client";

import { useBlockNumber } from "wagmi";
import { useDashboard } from "@/hooks/use-api";
import { formatNumber, formatUsd } from "@/lib/format";
import { CHAIN, CHAIN_ID } from "@/lib/network";

/** Full-width mono marquee of live protocol figures. Pauses on hover. */
export function Ticker() {
  const d = useDashboard();
  const block = useBlockNumber({ chainId: CHAIN_ID, watch: true });
  const s = d.data?.stats;
  const cells: [string, string][] = [
    ["Network", CHAIN.name],
    ["Block", block.data ? formatNumber(Number(block.data)) : "—"],
    ["TVL", s ? formatUsd(s.tvl_usd, { compact: true }) : "—"],
    ["24h volume", s ? formatUsd(s.volume_24h_usd, { compact: true }) : "—"],
    ["24h trades", s ? formatNumber(s.trades_24h) : "—"],
    ["Pools", s ? String(s.pools) : "—"],
    ["Assets", s ? String(s.assets) : "—"],
  ];
  const row = (key: string) => (
    <div key={key} className="flex shrink-0">
      {cells.map(([label, value]) => (
        <span key={label} className="flex items-center gap-3 border-r px-6 py-3 font-mono text-[12px] uppercase tracking-button">
          <span className="text-muted">{label}</span>
          <span className="num text-fg">{value}</span>
        </span>
      ))}
    </div>
  );
  return (
    <div className="group overflow-hidden border-y bg-bg-elevated" aria-label="Protocol stats">
      <div className="flex w-max animate-marquee group-hover:[animation-play-state:paused]">
        {row("a")}
        {row("b")}
      </div>
    </div>
  );
}
