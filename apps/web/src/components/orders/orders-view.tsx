"use client";

import * as React from "react";
import type { Address } from "viem";
import { useAccount, useReadContract, useReadContracts } from "wagmi";
import { AmountField, ApproveGate, ConnectGate, EmptyState, KV, NotDeployed, PageHeader, PairLabel, Panel, QueryState, TxNotice } from "@/components/kit";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { usePools } from "@/hooks/use-api";
import { useTx } from "@/hooks/use-tx";
import { useOpenVenues } from "@/hooks/use-venues";
import type { ApiPool } from "@/lib/api";
import { ABIS, addressOf } from "@/lib/contracts";
import { binFromPrice, priceFromBin } from "@/lib/dlmm";
import { formatNumber, formatTokenAmount, parseAmount } from "@/lib/format";
import { CHAIN_ID } from "@/lib/network";
import { cn } from "@/lib/utils";

const SIDE = { SELL_TOKEN0: 0, SELL_TOKEN1: 1 } as const;
const STATUS = ["NONE", "OPEN", "PARTIAL", "FILLED", "CLOSED"] as const;

function PlaceOrder({ pool, orders }: { pool: ApiPool; orders: Address }) {
  const [side, setSide] = React.useState<0 | 1>(SIDE.SELL_TOKEN0);
  const [price, setPrice] = React.useState("");
  const [amount, setAmount] = React.useState("");
  const tx = useTx();
  const active = useReadContract({ address: pool.pool_address as Address, abi: ABIS.dlmmPool, functionName: "activeId", chainId: CHAIN_ID, query: { refetchInterval: 15_000 } });
  const step = pool.bin_step_bps ?? 25;
  const d0 = pool.token0.decimals;
  const d1 = pool.token1.decimals;
  const activeId = active.data ?? pool.active_index ?? 0;
  const spot = priceFromBin(activeId, step, d0, d1);
  const sell = side === SIDE.SELL_TOKEN0 ? pool.token0 : pool.token1;
  const buy = side === SIDE.SELL_TOKEN0 ? pool.token1 : pool.token0;

  const p = Number(price);
  // selling token0 must sit above the active bin, selling token1 below it
  const bin = p > 0 ? binFromPrice(p, step, d0, d1, side === SIDE.SELL_TOKEN0 ? "up" : "down") : null;
  const valid = bin !== null && (side === SIDE.SELL_TOKEN0 ? bin > activeId : bin < activeId);
  const raw = parseAmount(amount, sell.decimals);
  const binPrice = bin !== null ? priceFromBin(bin, step, d0, d1) : null;
  const expected = raw && binPrice ? (side === SIDE.SELL_TOKEN0 ? (Number(raw) / 10 ** d0) * binPrice : Number(raw) / 10 ** d1 / binPrice) : null;

  return (
    <div className="space-y-3">
      <div className="grid grid-cols-2 border">
        {([SIDE.SELL_TOKEN0, SIDE.SELL_TOKEN1] as const).map((s) => (
          <button
            key={s}
            onClick={() => setSide(s)}
            className={cn("py-2 font-mono text-[12px] uppercase tracking-button", side === s ? "bg-surface-2 text-primary-text" : "text-fg-2")}
          >
            Sell {s === SIDE.SELL_TOKEN0 ? pool.token0.symbol : pool.token1.symbol}
          </button>
        ))}
      </div>
      <KV label="Spot" value={`${formatNumber(spot)} ${pool.token1.symbol} / ${pool.token0.symbol}`} />
      <label className="block space-y-2">
        <span className="eyebrow">
          Limit price ({pool.token1.symbol} per {pool.token0.symbol}) · {side === SIDE.SELL_TOKEN0 ? "above" : "below"} spot
        </span>
        <Input inputMode="decimal" value={price} onChange={(e) => setPrice(e.target.value)} placeholder={formatNumber(spot)} className="num" />
      </label>
      <AmountField label={`Sell ${sell.symbol}`} value={amount} onChange={setAmount} token={sell} right={<span className="font-mono text-sm">{sell.symbol}</span>} />
      {bin !== null && (
        <div className="border-t pt-2">
          <KV label="Bin" value={`${bin} @ ${formatNumber(binPrice)}`} />
          <KV label="Receive when filled" value={expected ? `≈ ${formatNumber(expected)} ${buy.symbol} + fees` : "—"} />
          {!valid && <p className="text-sm text-warning">Price must be on the {side === SIDE.SELL_TOKEN0 ? "upper" : "lower"} side of the active bin.</p>}
        </div>
      )}
      <ConnectGate>
        <ApproveGate token={sell} spender={orders} amount={raw ?? 0n}>
          <Button
            className="w-full"
            size="lg"
            disabled={!valid || !raw || tx.busy}
            onClick={() =>
              tx.send({ address: orders, abi: ABIS.dlmmLimitOrders, functionName: "place", args: [pool.pool_address as Address, bin!, side, raw!, BigInt(Math.floor(Date.now() / 1000) + 600)] })
            }
          >
            {tx.busy ? "Placing…" : "Place limit order"}
          </Button>
        </ApproveGate>
      </ConnectGate>
      <TxNotice tx={tx} />
    </div>
  );
}

function MyOrders({ orders, pools }: { orders: Address; pools: ApiPool[] }) {
  const { address } = useAccount();
  const tx = useTx();
  const ids = useReadContract({ address: orders, abi: ABIS.dlmmLimitOrders, functionName: "ordersOf", args: address ? [address] : undefined, chainId: CHAIN_ID, query: { enabled: !!address, refetchInterval: 20_000 } });
  const list = [...(ids.data ?? [])].reverse();
  const details = useReadContracts({
    contracts: list.flatMap((id) => [
      { address: orders, abi: ABIS.dlmmLimitOrders, functionName: "getOrder", args: [id], chainId: CHAIN_ID } as const,
      { address: orders, abi: ABIS.dlmmLimitOrders, functionName: "status", args: [id], chainId: CHAIN_ID } as const,
      { address: orders, abi: ABIS.dlmmLimitOrders, functionName: "orderValue", args: [id], chainId: CHAIN_ID } as const,
    ]),
    query: { enabled: list.length > 0, refetchInterval: 20_000 },
  });
  if (!address) return <ConnectGate label="Connect to see orders">{null}</ConnectGate>;
  if (!list.length) return <EmptyState title="No orders yet" />;
  return (
    <div className="overflow-x-auto border">
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>#</TableHead>
            <TableHead>Pair</TableHead>
            <TableHead>Side</TableHead>
            <TableHead className="text-right">Amount</TableHead>
            <TableHead className="text-right">Value now</TableHead>
            <TableHead>Status</TableHead>
            <TableHead />
          </TableRow>
        </TableHeader>
        <TableBody>
          {list.map((id, i) => {
            const o = details.data?.[i * 3]?.result as { pool: Address; side: number; amountIn: bigint; binId: number } | undefined;
            const st = STATUS[Number(details.data?.[i * 3 + 1]?.result ?? 0)]!;
            const val = details.data?.[i * 3 + 2]?.result as readonly [bigint, bigint] | undefined;
            const pool = o && pools.find((p) => p.pool_address?.toLowerCase() === o.pool.toLowerCase());
            const sellTok = pool && (o.side === 0 ? pool.token0 : pool.token1);
            return (
              <TableRow key={id.toString()}>
                <TableCell className="num">{id.toString()}</TableCell>
                <TableCell>{pool ? <PairLabel pool={pool} /> : <span className="font-mono text-xs">{o?.pool.slice(0, 10)}</span>}</TableCell>
                <TableCell>{sellTok ? `Sell ${sellTok.symbol}` : "—"}</TableCell>
                <TableCell className="num text-right">{o && sellTok ? formatTokenAmount(o.amountIn, sellTok.decimals) : "—"}</TableCell>
                <TableCell className="num text-right">
                  {val && pool ? `${formatTokenAmount(val[0], pool.token0.decimals, 4)} / ${formatTokenAmount(val[1], pool.token1.decimals, 4)}` : "—"}
                </TableCell>
                <TableCell>
                  <Badge variant={st === "FILLED" ? "default" : st === "PARTIAL" ? "warning" : st === "CLOSED" ? "neutral" : "accent"}>{st}</Badge>
                </TableCell>
                <TableCell className="text-right">
                  {st === "FILLED" && (
                    <Button size="sm" disabled={tx.busy} onClick={() => tx.send({ address: orders, abi: ABIS.dlmmLimitOrders, functionName: "claim", args: [id, address] })}>
                      Claim
                    </Button>
                  )}
                  {(st === "OPEN" || st === "PARTIAL") && (
                    <Button size="sm" variant="secondary" disabled={tx.busy} onClick={() => tx.send({ address: orders, abi: ABIS.dlmmLimitOrders, functionName: "cancel", args: [id, address] })}>
                      Cancel
                    </Button>
                  )}
                </TableCell>
              </TableRow>
            );
          })}
        </TableBody>
      </Table>
      <div className="p-3">
        <TxNotice tx={tx} />
      </div>
    </div>
  );
}

export function OrdersView() {
  const orders = addressOf("dlmmLimitOrders");
  const venues = useOpenVenues();
  const pools = usePools();
  const [poolId, setPoolId] = React.useState<string>();
  return (
    <>
      <PageHeader
        eyebrow="Limit orders"
        title="Limit orders on DLMM bins"
        description="A limit order is single-sided liquidity in one bin away from the current price. It fills as trades cross the bin and earns swap fees while it waits."
      />
      {!orders ? (
        <div className="mt-8">
          <NotDeployed name="Limit orders" />
        </div>
      ) : !venues.dlmm ? (
        <div className="mt-8">
          <EmptyState title={venues.loading ? "Loading…" : "Limit orders are not open on this network yet"}>
            {venues.loading ? null : "Limit orders live on DLMM pools, which open in a later release on this network."}
          </EmptyState>
        </div>
      ) : (
        <QueryState query={pools}>
          {(all) => {
            const dlmm = all.filter((p) => p.venue === "DLMM" && p.pool_address);
            const pool = dlmm.find((p) => p.pool_id === poolId) ?? dlmm[0];
            return (
              <div className="mt-8 grid gap-6 lg:grid-cols-[400px_1fr]">
                <Panel title="New order" brackets>
                  {pool ? (
                    <div className="space-y-4">
                      <select
                        value={pool.pool_id}
                        onChange={(e) => setPoolId(e.target.value)}
                        className="h-10 w-full rounded-sm border bg-surface-2 px-2 text-sm"
                        aria-label="DLMM pool"
                      >
                        {dlmm.map((p) => (
                          <option key={p.pool_id} value={p.pool_id}>
                            {p.token0.symbol}/{p.token1.symbol} · {p.bin_step_bps} bps
                          </option>
                        ))}
                      </select>
                      <PlaceOrder key={pool.pool_id} pool={pool} orders={orders} />
                    </div>
                  ) : (
                    <EmptyState title="No DLMM pools yet">Create a DLMM pool first.</EmptyState>
                  )}
                </Panel>
                <div className="space-y-3">
                  <p className="eyebrow">Your orders</p>
                  <MyOrders orders={orders} pools={all} />
                </div>
              </div>
            );
          }}
        </QueryState>
      )}
    </>
  );
}
