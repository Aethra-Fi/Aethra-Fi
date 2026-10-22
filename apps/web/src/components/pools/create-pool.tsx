"use client";

import * as React from "react";
import type { Address } from "viem";
import { ConnectGate, KV, PageHeader, Panel, TokenSelect, TxNotice } from "@/components/kit";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { useTokenList, type TokenOption } from "@/hooks/use-token";
import { useTx } from "@/hooks/use-tx";
import { ABIS, addressOf } from "@/lib/contracts";
import { binFromPrice, priceFromBin } from "@/lib/dlmm";
import { formatNumber } from "@/lib/format";
import { DYNAMIC_FEE_FLAG, priceToSqrtPriceX96 } from "@/lib/v4math";
import { cn } from "@/lib/utils";

type Venue = "V4" | "DLMM" | "DAMM";

const VENUES: { v: Venue; title: string; body: string }[] = [
  { v: "V4", title: "v4 hook pool", body: "Uniswap v4 pool behind the Aethra hook. Dynamic fee, or oracle guard when a stock token is involved." },
  { v: "DLMM", title: "DLMM", body: "Discrete price bins. Pick the bin step; deposits can be shaped and limit orders placed in single bins." },
  { v: "DAMM", title: "DAMM", body: "One range per pool with fungible shares. Optional launch fee that decays to the base fee." },
];

const BIN_STEPS = [1, 5, 10, 25, 50, 100];
const DAMM_RANGES = [0, 50, 90];
const FEES = [500, 3000, 10_000]; // pips

export function CreatePool() {
  const { tokens } = useTokenList();
  const erc20s = tokens.filter((t) => !t.native);
  const [venue, setVenue] = React.useState<Venue>("V4");
  const [a, setA] = React.useState<TokenOption>();
  const [b, setB] = React.useState<TokenOption>();
  const [price, setPrice] = React.useState("");
  const [fee, setFee] = React.useState(3000);
  const [binStep, setBinStep] = React.useState(25);
  const [range, setRange] = React.useState(0);
  const [launchFee, setLaunchFee] = React.useState(false);
  const tx = useTx();

  const poolManager = addressOf("poolManager");
  const hook = addressOf("hook");
  const dlmm = addressOf("dlmmFactory");
  const damm = addressOf("dammFactory");

  const p = Number(price);
  const ready = a && b && p > 0;
  // sort like the contracts do; the user's price is "1 A = p B"
  const aIs0 = a && b ? a.address.toLowerCase() < b.address.toLowerCase() : true;
  const [t0, t1] = aIs0 ? [a, b] : [b, a];
  const price01 = aIs0 ? p : 1 / p;

  const sqrtP = ready ? priceToSqrtPriceX96(price01, t0!.decimals, t1!.decimals) : 0n;
  const activeId = ready ? binFromPrice(price01, binStep, t0!.decimals, t1!.decimals) : 0;
  const snapped = ready ? priceFromBin(activeId, binStep, t0!.decimals, t1!.decimals) : 0;

  const target = venue === "V4" ? poolManager && hook : venue === "DLMM" ? dlmm : damm;

  async function create() {
    if (!ready) return;
    if (venue === "V4") {
      await tx.send({
        address: poolManager!,
        abi: ABIS.poolManager,
        functionName: "initialize",
        args: [{ currency0: t0!.address as Address, currency1: t1!.address as Address, fee: DYNAMIC_FEE_FLAG, tickSpacing: 60, hooks: hook! }, sqrtP],
      });
    } else if (venue === "DLMM") {
      await tx.send({
        address: dlmm!,
        abi: ABIS.dlmmFactory,
        functionName: "createPool",
        args: [{ tokenA: a!.address as Address, tokenB: b!.address as Address, binStepBps: binStep, activeId, baseFee: fee, maxFee: Math.max(fee * 10, 50_000) }],
      });
    } else {
      const lower = range === 0 ? 0n : priceToSqrtPriceX96(price01 * (1 - range / 100), t0!.decimals, t1!.decimals);
      const upper = range === 0 ? 0n : priceToSqrtPriceX96(price01 / (1 - range / 100), t0!.decimals, t1!.decimals);
      await tx.send({
        address: damm!,
        abi: ABIS.dammFactory,
        functionName: "createPool",
        args: [
          {
            tokenA: t0!.address as Address,
            tokenB: t1!.address as Address,
            sqrtPriceX96: sqrtP,
            sqrtPriceLowerX96: lower,
            sqrtPriceUpperX96: upper,
            baseFee: fee,
            maxFee: Math.max(fee * 10, 50_000),
            launchFeeStart: launchFee ? 100_000 : 0,
            launchFeeDuration: launchFee ? 6 * 3600 : 0,
          },
        ],
      });
    }
  }

  return (
    <>
      <PageHeader eyebrow="Pools / Create" title="Create a pool" description="Pick a venue, a pair and a starting price. Add liquidity from the pool page once it exists." />
      <div className="mt-8 grid gap-6 lg:grid-cols-[1fr_1fr]">
        <div className="hairline-grid grid border">
          {VENUES.map((v) => (
            <button
              key={v.v}
              onClick={() => setVenue(v.v)}
              className={cn("space-y-2 bg-surface p-5 text-left transition-ui hover:bg-surface-2", venue === v.v && "bg-surface-2 outline outline-1 -outline-offset-1 outline-primary")}
            >
              <p className={cn("font-mono text-[11px] uppercase tracking-eyebrow", venue === v.v ? "text-primary-text" : "text-muted")}>{v.v}</p>
              <p className="text-lg font-medium">{v.title}</p>
              <p className="text-sm text-fg-2">{v.body}</p>
            </button>
          ))}
        </div>

        <Panel title="Parameters" brackets>
          <div className="space-y-5">
            <div className="flex flex-wrap items-center gap-3">
              <span className="eyebrow w-16">Pair</span>
              <TokenSelect tokens={erc20s} value={a} onChange={setA} exclude={b?.address} />
              <span className="text-muted">/</span>
              <TokenSelect tokens={erc20s} value={b} onChange={setB} exclude={a?.address} />
            </div>
            <label className="block space-y-2">
              <span className="eyebrow">Starting price {a && b ? `(1 ${a.symbol} = ? ${b.symbol})` : ""}</span>
              <Input inputMode="decimal" value={price} onChange={(e) => setPrice(e.target.value)} placeholder="0.0" className="num" />
            </label>

            {venue !== "V4" && (
              <div className="space-y-2">
                <p className="eyebrow">Base fee</p>
                <div className="flex gap-1">
                  {FEES.map((f) => (
                    <Button key={f} size="sm" variant={f === fee ? "default" : "secondary"} onClick={() => setFee(f)}>
                      {f / 10_000}%
                    </Button>
                  ))}
                </div>
              </div>
            )}
            {venue === "DLMM" && (
              <div className="space-y-2">
                <p className="eyebrow">Bin step</p>
                <div className="flex flex-wrap gap-1">
                  {BIN_STEPS.map((s) => (
                    <Button key={s} size="sm" variant={s === binStep ? "default" : "secondary"} onClick={() => setBinStep(s)}>
                      {s} bps
                    </Button>
                  ))}
                </div>
              </div>
            )}
            {venue === "DAMM" && (
              <>
                <div className="space-y-2">
                  <p className="eyebrow">Range</p>
                  <div className="flex gap-1">
                    {DAMM_RANGES.map((r) => (
                      <Button key={r} size="sm" variant={r === range ? "default" : "secondary"} onClick={() => setRange(r)}>
                        {r === 0 ? "Full range" : `-${r}% / +${Math.round((1 / (1 - r / 100) - 1) * 100)}%`}
                      </Button>
                    ))}
                  </div>
                </div>
                <label className="flex items-center gap-2 text-sm">
                  <input type="checkbox" checked={launchFee} onChange={(e) => setLaunchFee(e.target.checked)} className="accent-[rgb(var(--primary))]" />
                  Launch fee: start at 10%, decay to the base fee over 6 hours
                </label>
              </>
            )}

            <div className="border-t pt-3">
              {venue === "V4" && <KV label="Fee" value="Dynamic (hook)" />}
              {venue === "V4" && <KV label="Tick spacing" value="60" />}
              {venue === "DLMM" && ready && <KV label="Active bin" value={`${activeId} @ ${formatNumber(aIs0 ? snapped : 1 / snapped)}`} />}
              {ready && <KV label="Sorted pair" value={`${t0!.symbol} / ${t1!.symbol}`} />}
            </div>

            <ConnectGate>
              <Button className="w-full" size="lg" disabled={!ready || !target || tx.busy} onClick={create}>
                {!target ? `${venue} not deployed` : tx.busy ? "Creating…" : "Create pool"}
              </Button>
            </ConnectGate>
            <TxNotice tx={tx} />
          </div>
        </Panel>
      </div>
    </>
  );
}
