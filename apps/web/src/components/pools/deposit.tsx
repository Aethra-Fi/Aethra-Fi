"use client";

import * as React from "react";
import type { Address } from "viem";
import { useAccount } from "wagmi";
import { AmountField, ApproveGate, ConnectGate, KV, NotDeployed, TxNotice } from "@/components/kit";
import { Button } from "@/components/ui/button";
import { useTx } from "@/hooks/use-tx";
import type { ApiPool } from "@/lib/api";
import { ABIS, addressOf } from "@/lib/contracts";
import { distributeBins, priceFromBin, type BinShape } from "@/lib/dlmm";
import { formatNumber, parseAmount } from "@/lib/format";
import { poolKeyFromApi } from "@/lib/routing";
import { fullRangeTicks, liquidityForAmounts, Q96 } from "@/lib/v4math";
import { cn } from "@/lib/utils";

const deadline = () => BigInt(Math.floor(Date.now() / 1000) + 600);

function Choice<T extends string | number>({ options, value, onChange, label }: { options: { v: T; l: string }[]; value: T; onChange: (v: T) => void; label: string }) {
  return (
    <div className="space-y-2">
      <p className="eyebrow">{label}</p>
      <div className="flex flex-wrap gap-1">
        {options.map((o) => (
          <Button key={String(o.v)} size="sm" variant={o.v === value ? "default" : "secondary"} onClick={() => onChange(o.v)}>
            {o.l}
          </Button>
        ))}
      </div>
    </div>
  );
}

/** Two amount inputs, both approvals, then the venue-specific submit button. */
function TwoTokenForm({
  pool,
  spender,
  a0,
  a1,
  setA0,
  setA1,
  submit,
  busy,
  children,
}: {
  pool: ApiPool;
  spender: Address | null;
  a0: string;
  a1: string;
  setA0: (v: string) => void;
  setA1: (v: string) => void;
  submit: React.ReactNode;
  busy?: boolean;
  children?: React.ReactNode;
}) {
  const r0 = parseAmount(a0, pool.token0.decimals) ?? 0n;
  const r1 = parseAmount(a1, pool.token1.decimals) ?? 0n;
  return (
    <div className="space-y-3">
      {children}
      <AmountField label={`${pool.token0.symbol} max`} value={a0} onChange={setA0} token={pool.token0} right={<span className="font-mono text-sm">{pool.token0.symbol}</span>} />
      <AmountField label={`${pool.token1.symbol} max`} value={a1} onChange={setA1} token={pool.token1} right={<span className="font-mono text-sm">{pool.token1.symbol}</span>} />
      <ConnectGate>
        <ApproveGate token={pool.token0} spender={spender} amount={r0}>
          <ApproveGate token={pool.token1} spender={spender} amount={r1}>
            <div className={cn(busy && "pointer-events-none opacity-60")}>{submit}</div>
          </ApproveGate>
        </ApproveGate>
      </ConnectGate>
    </div>
  );
}

// ------------------------------------------------------------------ v4

const V4_RANGES = [
  { v: 0, l: "Full range" },
  { v: 50, l: "±50%" },
  { v: 20, l: "±20%" },
  { v: 5, l: "±5%" },
];

function V4Deposit({ pool }: { pool: ApiPool }) {
  const positions = addressOf("positions");
  const { address } = useAccount();
  const [a0, setA0] = React.useState("");
  const [a1, setA1] = React.useState("");
  const [range, setRange] = React.useState(0);
  const tx = useTx();
  if (!positions) return <NotDeployed name="Positions" />;
  if (!pool.sqrt_price_x96) return <p className="text-sm text-muted">Pool price not indexed yet.</p>;

  const spacing = pool.tick_spacing ?? 60;
  const sqrtP = BigInt(pool.sqrt_price_x96);
  const tick = Math.log((Number(sqrtP) / Q96) ** 2) / Math.log(1.0001);
  const [fullLo, fullHi] = fullRangeTicks(spacing);
  const span = range === 0 ? 0 : Math.log(1 + range / 100) / Math.log(1.0001);
  const lo = range === 0 ? fullLo : Math.max(fullLo, Math.floor((tick - span) / spacing) * spacing);
  const hi = range === 0 ? fullHi : Math.min(fullHi, Math.ceil((tick + span) / spacing) * spacing);
  const r0 = parseAmount(a0, pool.token0.decimals) ?? 0n;
  const r1 = parseAmount(a1, pool.token1.decimals) ?? 0n;
  const liquidity = liquidityForAmounts(sqrtP, lo, hi, r0, r1);

  return (
    <TwoTokenForm
      pool={pool}
      spender={positions}
      a0={a0}
      a1={a1}
      setA0={setA0}
      setA1={setA1}
      busy={tx.busy}
      submit={
        <div className="space-y-2">
          <Button
            className="w-full"
            size="lg"
            disabled={liquidity === 0n || tx.busy}
            onClick={() =>
              tx.send({
                address: positions,
                abi: ABIS.positions,
                functionName: "mint",
                args: [{ key: poolKeyFromApi(pool), tickLower: lo, tickUpper: hi, liquidity, amount0Max: r0, amount1Max: r1, recipient: address!, deadline: deadline() }],
              })
            }
          >
            {tx.busy ? "Minting…" : "Mint position"}
          </Button>
          <TxNotice tx={tx} />
        </div>
      }
    >
      <Choice label="Range" options={V4_RANGES} value={range} onChange={setRange} />
      <KV label="Ticks" value={`${lo} → ${hi}`} />
    </TwoTokenForm>
  );
}

// ------------------------------------------------------------------ DAMM

function DammDeposit({ pool }: { pool: ApiPool }) {
  const { address } = useAccount();
  const [a0, setA0] = React.useState("");
  const [a1, setA1] = React.useState("");
  const tx = useTx();
  const addr = pool.pool_address as Address | null;
  if (!addr) return null;
  const r0 = parseAmount(a0, pool.token0.decimals) ?? 0n;
  const r1 = parseAmount(a1, pool.token1.decimals) ?? 0n;
  return (
    <TwoTokenForm
      pool={pool}
      spender={addr}
      a0={a0}
      a1={a1}
      setA0={setA0}
      setA1={setA1}
      busy={tx.busy}
      submit={
        <div className="space-y-2">
          <Button
            className="w-full"
            size="lg"
            disabled={(r0 === 0n && r1 === 0n) || tx.busy}
            onClick={() => tx.send({ address: addr, abi: ABIS.dammPool, functionName: "addLiquidity", args: [r0, r1, 0n, address!, deadline()] })}
          >
            {tx.busy ? "Depositing…" : "Deposit"}
          </Button>
          <TxNotice tx={tx} />
        </div>
      }
    >
      <p className="text-sm text-muted">The pool takes the amounts that fit its range at the current price; the rest stays in your wallet.</p>
    </TwoTokenForm>
  );
}

// ------------------------------------------------------------------ DLMM

const SHAPES: { v: BinShape; l: string }[] = [
  { v: "spot", l: "Spot" },
  { v: "curve", l: "Curve" },
  { v: "bidask", l: "Bid-ask" },
];

function DlmmDeposit({ pool }: { pool: ApiPool }) {
  const { address } = useAccount();
  const [a0, setA0] = React.useState("");
  const [a1, setA1] = React.useState("");
  const [shape, setShape] = React.useState<BinShape>("spot");
  const [radius, setRadius] = React.useState(10);
  const tx = useTx();
  const addr = pool.pool_address as Address | null;
  if (!addr || pool.active_index === null || !pool.bin_step_bps) return null;
  const r0 = parseAmount(a0, pool.token0.decimals) ?? 0n;
  const r1 = parseAmount(a1, pool.token1.decimals) ?? 0n;
  const dist = distributeBins({ activeId: pool.active_index, radius, shape, amount0: r0, amount1: r1 });
  const step = pool.bin_step_bps;
  const lowP = priceFromBin(dist.ids[0]!, step, pool.token0.decimals, pool.token1.decimals);
  const highP = priceFromBin(dist.ids[dist.ids.length - 1]!, step, pool.token0.decimals, pool.token1.decimals);

  return (
    <TwoTokenForm
      pool={pool}
      spender={addr}
      a0={a0}
      a1={a1}
      setA0={setA0}
      setA1={setA1}
      busy={tx.busy}
      submit={
        <div className="space-y-2">
          <Button
            className="w-full"
            size="lg"
            disabled={(r0 === 0n && r1 === 0n) || tx.busy}
            onClick={() =>
              tx.send({ address: addr, abi: ABIS.dlmmPool, functionName: "addLiquidity", args: [dist.ids, dist.amounts0, dist.amounts1, address!, deadline()] })
            }
          >
            {tx.busy ? "Depositing…" : `Deposit into ${dist.ids.length} bins`}
          </Button>
          <TxNotice tx={tx} />
        </div>
      }
    >
      <Choice label="Shape" options={SHAPES} value={shape} onChange={setShape} />
      <Choice label="Bins each side" options={[2, 5, 10, 25].map((v) => ({ v, l: String(v) }))} value={radius} onChange={setRadius} />
      <div className="flex h-16 items-end gap-px border-b" aria-hidden>
        {dist.ids.map((id, i) => (
          <div key={id} className="flex flex-1 flex-col justify-end">
            <div className="bg-accent" style={{ height: `${dist.weights1[i]! * 100}%` }} />
            <div className="bg-primary" style={{ height: `${dist.weights0[i]! * 100}%` }} />
          </div>
        ))}
      </div>
      <KV label="Price range" value={`${formatNumber(lowP)} → ${formatNumber(highP)}`} />
    </TwoTokenForm>
  );
}

export function DepositPanel({ pool }: { pool: ApiPool }) {
  if (pool.venue === "V4") return <V4Deposit pool={pool} />;
  if (pool.venue === "DAMM") return <DammDeposit pool={pool} />;
  if (pool.venue === "DLMM") return <DlmmDeposit pool={pool} />;
  return <p className="text-sm text-muted">Launch curves take no deposits. Trade on the curve; liquidity is added automatically at graduation.</p>;
}
