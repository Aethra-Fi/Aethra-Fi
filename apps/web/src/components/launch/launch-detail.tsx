"use client";

import * as React from "react";
import Link from "next/link";
import type { Address } from "viem";
import { encodeAbiParameters } from "viem";
import { useAccount, useReadContract } from "wagmi";
import { Venue } from "@aethrafi/sdk";
import { ThemedAreaChart } from "@/components/charts/area-chart";
import { EventTable } from "@/components/events/event-table";
import { AddressLink, AmountField, ApproveGate, ConnectGate, EmptyState, KV, NotDeployed, Panel, QueryState, TokenIcon, TxNotice } from "@/components/kit";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { useEvents, useLaunches } from "@/hooks/use-api";
import { NATIVE, type TokenOption } from "@/hooks/use-token";
import { useTx } from "@/hooks/use-tx";
import { ABIS, addressOf } from "@/lib/contracts";
import { formatNumber, formatPct, formatTokenAmount, parseAmount } from "@/lib/format";
import { CHAIN_ID, DEPLOYMENT } from "@/lib/network";
import { minReceived } from "@/lib/routing";
import { cn } from "@/lib/utils";
import { Progress } from "./launch-list";

const ETH: TokenOption = { address: NATIVE, symbol: "ETH", name: "Ether", decimals: 18, kind: "canonical", logo_url: null, native: true };

function TradePanel({ token, symbol, graduated }: { token: Address; symbol: string; graduated: boolean }) {
  const launchpad = addressOf("launchpad")!;
  const router = addressOf("router");
  const { address } = useAccount();
  const [side, setSide] = React.useState<"buy" | "sell">("buy");
  const [amount, setAmount] = React.useState("");
  const tx = useTx();
  const tokenOpt: TokenOption = { address: token, symbol, name: symbol, decimals: 18, kind: "launch", logo_url: null };
  const input = side === "buy" ? ETH : tokenOpt;
  const raw = parseAmount(amount, 18);
  const quote = useReadContract({
    address: launchpad,
    abi: ABIS.launchpad,
    functionName: "quoteExactInput",
    args: [token, side === "buy" ? DEPLOYMENT.weth : token, raw ?? 0n],
    chainId: CHAIN_ID,
    query: { enabled: !!raw && !graduated },
  });

  if (graduated) {
    return (
      <div className="space-y-3">
        <p className="text-sm text-fg-2">This launch graduated. It now trades in its v4 hook pool through the smart router.</p>
        <Button asChild className="w-full" size="lg">
          <Link href={`/swap?in=ETH&out=${token}`}>Trade on swap</Link>
        </Button>
      </div>
    );
  }
  if (!router) return <NotDeployed name="Router" />;

  const out = quote.data ?? 0n;
  const hop = {
    venue: Venue.LAUNCH,
    pool: launchpad,
    tokenIn: (side === "buy" ? DEPLOYMENT.weth : token) as Address,
    tokenOut: (side === "buy" ? token : DEPLOYMENT.weth) as Address,
    data: encodeAbiParameters([{ type: "address" }], [token]),
  };

  return (
    <div className="space-y-3">
      <div className="grid grid-cols-2 border">
        {(["buy", "sell"] as const).map((s) => (
          <button
            key={s}
            onClick={() => {
              setSide(s);
              setAmount("");
              tx.reset();
            }}
            className={cn("py-2 font-mono text-[12px] uppercase tracking-button transition-ui", side === s ? (s === "buy" ? "bg-primary text-primary-fg" : "bg-danger-soft text-danger") : "text-fg-2 hover:text-fg")}
          >
            {s}
          </button>
        ))}
      </div>
      <AmountField label="Amount" value={amount} onChange={setAmount} token={input} right={<span className="font-mono text-sm">{input.symbol}</span>} />
      <KV label="You receive" value={raw ? `${formatTokenAmount(out, 18)} ${side === "buy" ? symbol : "ETH"}` : "—"} />
      <ConnectGate>
        <ApproveGate token={input} spender={router} amount={raw ?? 0n}>
          <Button
            className="w-full"
            size="lg"
            variant={side === "buy" ? "default" : "destructive"}
            disabled={!raw || out === 0n || tx.busy}
            onClick={async () => {
              const r = await tx.send({
                address: router,
                abi: ABIS.router,
                functionName: "swap",
                args: [[hop], raw!, minReceived(out, 1), address!, BigInt(Math.floor(Date.now() / 1000) + 600), side === "sell"],
                value: side === "buy" ? raw! : undefined,
              });
              if (r) setAmount("");
            }}
          >
            {tx.busy ? "Submitting…" : side === "buy" ? `Buy ${symbol}` : `Sell ${symbol}`}
          </Button>
        </ApproveGate>
      </ConnectGate>
      <p className="text-xs text-muted">1% max slippage. A buy larger than the remaining curve only spends what it needs and graduates the launch.</p>
      <TxNotice tx={tx} />
    </div>
  );
}

export function LaunchDetail({ token }: { token: Address }) {
  const launchpad = addressOf("launchpad");
  const onchain = useReadContract({ address: launchpad ?? undefined, abi: ABIS.launchpad, functionName: "launch", args: [token], chainId: CHAIN_ID, query: { enabled: !!launchpad, refetchInterval: 15_000 } });
  const cfg = useReadContract({ address: launchpad ?? undefined, abi: ABIS.launchpad, functionName: "config", chainId: CHAIN_ID, query: { enabled: !!launchpad } });
  const spot = useReadContract({ address: launchpad ?? undefined, abi: ABIS.launchpad, functionName: "spotPrice", args: [token], chainId: CHAIN_ID, query: { enabled: !!launchpad, refetchInterval: 15_000 } });
  const symbol = useReadContract({ address: token, abi: ABIS.erc20, functionName: "symbol", chainId: CHAIN_ID });
  const name = useReadContract({ address: token, abi: ABIS.erc20, functionName: "name", chainId: CHAIN_ID });
  const launches = useLaunches();
  const events = useEvents({ pool: token, limit: 25 });
  const api = launches.data?.find((l) => l.token.toLowerCase() === token.toLowerCase());

  if (!launchpad) return <div className="py-10"><NotDeployed name="Launchpad" /></div>;
  const l = onchain.data;
  if (onchain.isLoading) return <div className="skeleton mt-10 h-[60vh]" />;
  if (!l || l.token === "0x0000000000000000000000000000000000000000") return <div className="py-10"><EmptyState title="Launch not found" /></div>;

  const curveSupply = cfg.data?.curveSupply ?? 800_000_000n * 10n ** 18n;
  const progress = l.graduated ? 1 : 1 - Number(l.realToken) / Number(curveSupply);
  const sym = symbol.data ?? "TOKEN";
  const series = (api?.curve ?? []).map((c) => ({ t: c.t, v: c.price_weth }));

  return (
    <>
      <div className="flex flex-col gap-4 border-b pb-8 pt-10 md:flex-row md:items-end md:justify-between">
        <div className="flex items-center gap-4">
          <TokenIcon symbol={sym} className="size-14 text-sm" />
          <div className="space-y-1">
            <p className="eyebrow">
              <Link href="/launch" className="hover:text-primary-text">
                Launch
              </Link>{" "}
              / ${sym}
            </p>
            <h1 className="text-3xl font-medium tracking-tight">{name.data ?? "…"}</h1>
          </div>
          {l.graduated ? <Badge>Graduated</Badge> : <Badge variant="warning">On curve</Badge>}
        </div>
      </div>

      <div className="mt-8 grid gap-6 lg:grid-cols-[1.6fr_1fr]">
        <div className="space-y-6">
          <Panel title="Bonding curve" aside={<span className="num text-sm">{formatPct(progress * 100, 1)}</span>}>
            <Progress value={progress} className="mb-4" />
            <div className="grid gap-x-8 sm:grid-cols-2">
              <KV label="ETH raised" value={formatTokenAmount(l.realWeth, 18, 4)} />
              <KV label="Left on curve" value={`${formatNumber(Number(l.realToken) / 1e18)} ${sym}`} />
              <KV label="Price" value={spot.data !== undefined ? `${formatNumber(Number(spot.data) / 1e18, 4)} ETH` : "—"} />
              <KV label="Holders" value={api?.holders ?? "—"} />
            </div>
          </Panel>
          {series.length > 1 && (
            <Panel title="Price in ETH">
              <ThemedAreaChart data={series} format={(v) => formatNumber(v, 3)} />
            </Panel>
          )}
          <div className="space-y-3">
            <p className="eyebrow">Trades</p>
            <QueryState query={events} isEmpty={(d) => d.length === 0} empty={<EmptyState title="No trades yet" />}>
              {(rows) => <EventTable events={rows} showPool={false} />}
            </QueryState>
          </div>
        </div>
        <div className="space-y-6">
          <Panel title="Trade" brackets>
            <TradePanel token={token} symbol={sym} graduated={l.graduated} />
          </Panel>
          <Panel title="Token">
            <KV label="Contract" value={<AddressLink address={token} />} />
            <KV label="Creator" value={<AddressLink address={l.creator} />} />
            <KV label="Supply" value="1,000,000,000" />
            {l.graduated && <KV label="Locked LP NFT" value={`#${l.positionId.toString()}`} />}
          </Panel>
          {api?.top_holders?.length ? (
            <Panel title="Top holders">
              {api.top_holders.slice(0, 10).map((h) => (
                <KV key={h.address} label={<AddressLink address={h.address} />} value={formatPct(h.share * 100, 2)} />
              ))}
            </Panel>
          ) : null}
        </div>
      </div>
    </>
  );
}
