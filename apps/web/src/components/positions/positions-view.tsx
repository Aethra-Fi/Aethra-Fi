"use client";

import Link from "next/link";
import type { Address } from "viem";
import { useAccount, useReadContract } from "wagmi";
import { ConnectGate, EmptyState, KV, PageHeader, PairLabel, Panel, QueryState, TxNotice, VenueBadge } from "@/components/kit";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { usePositionsApi } from "@/hooks/use-api";
import { useTx } from "@/hooks/use-tx";
import type { ApiDammPosition, ApiDlmmPosition, ApiV4Position } from "@/lib/api";
import { ABIS, addressOf } from "@/lib/contracts";
import { FEATURES } from "@/lib/features";
import { formatDateTime, formatTokenAmount } from "@/lib/format";
import { CHAIN_ID } from "@/lib/network";
import { fullRangeTicks } from "@/lib/v4math";

const deadline = () => BigInt(Math.floor(Date.now() / 1000) + 600);
const PERMANENT = 2n ** 64n - 1n;

function lockLabel(p: ApiV4Position) {
  if (!p.locked) return null;
  if (p.lock_end !== null && BigInt(p.lock_end) >= PERMANENT) return <Badge variant="warning">Locked forever</Badge>;
  return <Badge variant="warning">Vesting until {formatDateTime((p.lock_end ?? 0) * 1000)}</Badge>;
}

function V4Card({ p, owner }: { p: ApiV4Position; owner: Address }) {
  const positions = addressOf("positions")!;
  const tx = useTx();
  const withdrawable = useReadContract({ address: positions, abi: ABIS.positions, functionName: "withdrawable", args: [BigInt(p.token_id)], chainId: CHAIN_ID });
  const amounts = useReadContract({ address: positions, abi: ABIS.positions, functionName: "positionAmounts", args: [BigInt(p.token_id)], chainId: CHAIN_ID });
  const id = BigInt(p.token_id);
  const spacing = p.pool?.tick_spacing ?? 60;
  const full = fullRangeTicks(spacing);
  const isFull = p.tick_lower === full[0] && p.tick_upper === full[1];
  const free = withdrawable.data ?? 0n;

  return (
    <Panel
      title={`#${p.token_id}`}
      aside={
        <span className="flex gap-1">
          {FEATURES.credit && p.pledged && <Badge variant="accent">Pledged</Badge>}
          {lockLabel(p)}
        </span>
      }
    >
      <div className="space-y-3">
        {p.pool && <PairLabel pool={p.pool} />}
        <div>
          <KV label="Range" value={isFull ? "Full range" : `${p.tick_lower} → ${p.tick_upper}`} />
          {amounts.data && p.pool && (
            <>
              <KV label={p.pool.token0.symbol} value={formatTokenAmount(amounts.data[0], p.pool.token0.decimals)} />
              <KV label={p.pool.token1.symbol} value={formatTokenAmount(amounts.data[1], p.pool.token1.decimals)} />
            </>
          )}
          <KV label="Withdrawable" value={p.liquidity === "0" ? "0%" : `${Number((free * 10_000n) / (BigInt(p.liquidity) || 1n)) / 100}%`} />
        </div>
        {FEATURES.credit && p.pledged ? (
          <Button asChild variant="secondary" className="w-full">
            <Link href="/credit">Manage loan</Link>
          </Button>
        ) : (
          <div className="grid grid-cols-2 gap-2">
            <Button variant="secondary" disabled={tx.busy} onClick={() => tx.send({ address: positions, abi: ABIS.positions, functionName: "collect", args: [id, owner] })}>
              Collect fees
            </Button>
            <Button
              variant="secondary"
              disabled={tx.busy || free === 0n}
              onClick={() => tx.send({ address: positions, abi: ABIS.positions, functionName: "decreaseLiquidity", args: [id, free, 0n, 0n, owner, deadline()] })}
            >
              Withdraw
            </Button>
            {!p.locked && (
              <Button
                variant="ghost"
                className="col-span-2"
                disabled={tx.busy}
                onClick={() => {
                  if (window.confirm("Lock this position forever? Fees stay claimable, liquidity can never be withdrawn.")) {
                    void tx.send({ address: positions, abi: ABIS.positions, functionName: "lock", args: [id, PERMANENT, PERMANENT] });
                  }
                }}
              >
                Lock forever
              </Button>
            )}
          </div>
        )}
        <TxNotice tx={tx} />
      </div>
    </Panel>
  );
}

function DlmmCard({ p, owner }: { p: ApiDlmmPosition; owner: Address }) {
  const tx = useTx();
  const live = p.bins.filter((b) => b.shares !== "0");
  return (
    <Panel title="DLMM" aside={<VenueBadge venue="DLMM" />}>
      <div className="space-y-3">
        {p.pool && <PairLabel pool={p.pool} />}
        <KV label="Bins" value={live.length ? `${live[0]!.id} → ${live[live.length - 1]!.id} (${live.length})` : "—"} />
        <Button
          variant="secondary"
          className="w-full"
          disabled={!live.length || tx.busy}
          onClick={() =>
            tx.send({
              address: p.pool_address as Address,
              abi: ABIS.dlmmPool,
              functionName: "removeLiquidity",
              args: [live.map((b) => b.id), live.map((b) => BigInt(b.shares)), 0n, 0n, owner, deadline()],
            })
          }
        >
          Remove all
        </Button>
        <TxNotice tx={tx} />
      </div>
    </Panel>
  );
}

function DammCard({ p, owner }: { p: ApiDammPosition; owner: Address }) {
  const tx = useTx();
  const addr = p.pool_address as Address;
  return (
    <Panel title="DAMM" aside={<VenueBadge venue="DAMM" />}>
      <div className="space-y-3">
        {p.pool && <PairLabel pool={p.pool} />}
        <KV label="Shares" value={formatTokenAmount(BigInt(p.shares), 0)} />
        <div className="grid grid-cols-2 gap-2">
          <Button variant="secondary" disabled={tx.busy} onClick={() => tx.send({ address: addr, abi: ABIS.dammPool, functionName: "claimFees", args: [owner] })}>
            Claim fees
          </Button>
          <Button
            variant="secondary"
            disabled={tx.busy || p.shares === "0"}
            onClick={() => tx.send({ address: addr, abi: ABIS.dammPool, functionName: "removeLiquidity", args: [BigInt(p.shares), 0n, 0n, owner, deadline()] })}
          >
            Remove all
          </Button>
        </div>
        <TxNotice tx={tx} />
      </div>
    </Panel>
  );
}

export function PositionsView() {
  const { address } = useAccount();
  const q = usePositionsApi(address);
  return (
    <>
      <PageHeader
        eyebrow="Positions"
        title="Your positions"
        description="Manage v4 position NFTs (with locks and vesting), DLMM bin shares and DAMM range shares across every venue."
        actions={
          <Button asChild variant="secondary">
            <Link href="/pools">Find a pool</Link>
          </Button>
        }
      />
      <div className="mt-8">
        {!address ? (
          <div className="mx-auto max-w-sm">
            <ConnectGate label="Connect to see positions">{null}</ConnectGate>
          </div>
        ) : (
          <QueryState
            query={q}
            isEmpty={(d) => !d.v4.length && !d.dlmm.length && !d.damm.length}
            empty={<EmptyState title="No positions yet" action={<Button asChild><Link href="/pools">Add liquidity</Link></Button>}>Provide liquidity to any pool and your position appears here.</EmptyState>}
          >
            {(d) => (
              <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
                {!addressOf("positions") ? null : d.v4.map((p) => <V4Card key={p.token_id} p={p} owner={address} />)}
                {d.dlmm.map((p) => (
                  <DlmmCard key={p.pool_address} p={p} owner={address} />
                ))}
                {d.damm.map((p) => (
                  <DammCard key={p.pool_address} p={p} owner={address} />
                ))}
              </div>
            )}
          </QueryState>
        )}
      </div>
    </>
  );
}
