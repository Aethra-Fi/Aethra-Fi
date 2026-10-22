"use client";

import * as React from "react";
import { ArrowDownUp, Settings2 } from "lucide-react";
import { useSearchParams } from "next/navigation";
import type { Address } from "viem";
import { useAccount } from "wagmi";
import { Button } from "@/components/ui/button";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { AmountField, ApproveGate, ConnectGate, KV, NotDeployed, Panel, TokenSelect, TxNotice, VenueBadge } from "@/components/kit";
import { isNative, useTokenBalance, useTokenList, type TokenOption } from "@/hooks/use-token";
import { useTx } from "@/hooks/use-tx";
import { ABIS } from "@/lib/contracts";
import { formatFeePips, formatTokenAmount, parseAmount } from "@/lib/format";
import { DEPLOYMENT } from "@/lib/network";
import { minReceived } from "@/lib/routing";
import { cn } from "@/lib/utils";
import { ROUTER, useBestRoute } from "./use-best-route";

const SLIPPAGES = [0.1, 0.5, 1];

function pick(tokens: TokenOption[], q: string | null, fallback: string) {
  const want = (q ?? fallback).toLowerCase();
  return tokens.find((t) => t.symbol.toLowerCase() === want || t.address.toLowerCase() === want);
}

export function SwapCard() {
  const params = useSearchParams();
  const { tokens } = useTokenList();
  const { address } = useAccount();
  // user picks override the defaults derived from ?in=&out= (else ETH → first stock token)
  const [pickedIn, setTokenIn] = React.useState<TokenOption>();
  const [pickedOut, setTokenOut] = React.useState<TokenOption>();
  const tokenIn = pickedIn ?? pick(tokens, params.get("in"), "ETH");
  const tokenOut = pickedOut ?? pick(tokens, params.get("out"), "") ?? tokens.find((t) => t.kind === "stock") ?? tokens[2];
  const [amount, setAmount] = React.useState("");
  const [slippage, setSlippage] = React.useState(0.5);
  const tx = useTx();

  const amountIn = tokenIn ? parseAmount(amount, tokenIn.decimals) : null;
  const { best, routes, isQuoting, poolsState, wrapOnly } = useBestRoute(tokenIn?.address, tokenOut?.address, amountIn);
  const balance = useTokenBalance(tokenIn?.address);
  const insufficient = amountIn !== null && balance.value !== undefined && amountIn > balance.value;

  const flip = () => {
    setTokenIn(tokenOut);
    setTokenOut(tokenIn);
    setAmount("");
    tx.reset();
  };

  if (!ROUTER) return <div className="w-full max-w-lg"><NotDeployed name="Router" /></div>;

  const outText = best && tokenOut ? formatTokenAmount(best.amountOut, tokenOut.decimals) : "";
  const fees = best?.pools.map((p) => p.fee_pips) ?? [];

  async function execute() {
    if (!best || !amountIn || !tokenIn || !tokenOut || !address) return;
    const r = await tx.send({
      address: ROUTER!,
      abi: ABIS.router,
      functionName: "swap",
      args: [
        best.hops.map((h) => ({ ...h, pool: h.pool as Address })),
        amountIn,
        minReceived(best.amountOut, slippage),
        address,
        BigInt(Math.floor(Date.now() / 1000) + 600),
        isNative(tokenOut.address),
      ],
      value: isNative(tokenIn.address) ? amountIn : undefined,
    });
    if (r) setAmount("");
  }

  return (
    <div className="w-full max-w-lg space-y-4">
      <Panel
        brackets
        title="Swap"
        aside={
          <Popover>
            <PopoverTrigger asChild>
              <Button variant="ghost" size="icon-sm" aria-label="Slippage settings">
                <Settings2 />
              </Button>
            </PopoverTrigger>
            <PopoverContent align="end" className="w-64 space-y-3">
              <p className="eyebrow">Max slippage</p>
              <div className="flex gap-2">
                {SLIPPAGES.map((s) => (
                  <Button key={s} size="sm" variant={s === slippage ? "default" : "secondary"} onClick={() => setSlippage(s)}>
                    {s}%
                  </Button>
                ))}
              </div>
            </PopoverContent>
          </Popover>
        }
      >
        <div className="space-y-1">
          <AmountField
            label="You pay"
            value={amount}
            onChange={(v) => {
              setAmount(v);
              tx.reset();
            }}
            token={tokenIn}
            right={<TokenSelect tokens={tokens} value={tokenIn} onChange={setTokenIn} exclude={tokenOut?.address} />}
          />
          <div className="relative z-10 -my-3 flex justify-center">
            <button
              type="button"
              onClick={flip}
              aria-label="Flip tokens"
              className="flex size-9 items-center justify-center border bg-surface transition-ui hover:border-primary hover:text-primary-text"
            >
              <ArrowDownUp className="size-4" />
            </button>
          </div>
          <AmountField
            label="You receive"
            value={isQuoting && !outText ? "" : outText}
            readOnly
            token={tokenOut}
            right={<TokenSelect tokens={tokens} value={tokenOut} onChange={setTokenOut} exclude={tokenIn?.address} />}
            footer={isQuoting ? <span className="font-mono text-xs text-muted">Computing route<span className="animate-caret">▍</span></span> : null}
          />
        </div>

        {best && tokenOut && (
          <div className="mt-4 space-y-0.5 border-t pt-3">
            <KV
              label="Route"
              value={
                <span className="flex flex-wrap items-center justify-end gap-1.5">
                  {best.path.join(" → ")}
                </span>
              }
            />
            <KV
              label="Venues"
              value={
                <span className="flex flex-wrap justify-end gap-1">
                  {best.pools.map((p, i) => (
                    <VenueBadge key={i} venue={p.venue} />
                  ))}
                </span>
              }
            />
            <KV label="Pool fees" value={fees.map((f) => formatFeePips(f)).join(" + ")} />
            <KV label={`Min received (${slippage}%)`} value={`${formatTokenAmount(minReceived(best.amountOut, slippage), tokenOut.decimals)} ${tokenOut.symbol}`} />
            {routes.length > 1 && <KV label="Routes compared" value={routes.length} />}
          </div>
        )}

        <div className="mt-4 space-y-3">
          <ConnectGate>
            {wrapOnly ? (
              <p className="text-sm text-muted">ETH and WETH convert 1:1; pick a different output token to trade.</p>
            ) : !amountIn ? (
              <Button className="w-full" size="lg" disabled>
                Enter an amount
              </Button>
            ) : insufficient ? (
              <Button className="w-full" size="lg" disabled>
                Insufficient {tokenIn?.symbol}
              </Button>
            ) : !best ? (
              <Button className="w-full" size="lg" disabled>
                {isQuoting ? "Finding route…" : poolsState.isError ? "Indexer offline: no routes" : "No route found"}
              </Button>
            ) : (
              <ApproveGate token={tokenIn} spender={ROUTER} amount={amountIn}>
                <Button className={cn("w-full")} size="lg" disabled={tx.busy} onClick={execute}>
                  {tx.busy ? "Swapping…" : "Swap"}
                </Button>
              </ApproveGate>
            )}
          </ConnectGate>
          <TxNotice tx={tx} />
        </div>
      </Panel>
      <p className="text-center font-mono text-[11px] uppercase tracking-eyebrow text-muted">
        WETH {DEPLOYMENT.weth.slice(0, 6)}… · routes across v4 · DLMM · DAMM · launch
      </p>
    </div>
  );
}
