"use client";

import * as React from "react";
import type { Address } from "viem";
import { useAccount, useReadContract, useReadContracts } from "wagmi";
import { AmountField, ApproveGate, ConnectGate, EmptyState, KV, NotDeployed, PageHeader, PairLabel, Panel, Stat, StatGrid, TxNotice } from "@/components/kit";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { usePositionsApi } from "@/hooks/use-api";
import { useTokenBalance, type TokenOption } from "@/hooks/use-token";
import { useTx } from "@/hooks/use-tx";
import { ABIS, addressOf } from "@/lib/contracts";
import { aprFromPerSecondWad, healthState } from "@/lib/credit";
import { formatBps, formatPct, formatTokenAmount, formatUsd, parseAmount } from "@/lib/format";
import { CHAIN_ID } from "@/lib/network";
import { cn } from "@/lib/utils";

function useVault() {
  const vault = addressOf("lendingVault");
  const base = { address: vault ?? undefined, abi: ABIS.lendingVault, chainId: CHAIN_ID } as const;
  const r = useReadContracts({
    contracts: [
      { ...base, functionName: "asset" },
      { ...base, functionName: "totalAssets" },
      { ...base, functionName: "totalBorrows" },
      { ...base, functionName: "utilizationBps" },
      { ...base, functionName: "borrowRatePerSecondWad" },
      { ...base, functionName: "supplyRatePerSecondWad" },
    ],
    query: { enabled: !!vault, refetchInterval: 20_000 },
  });
  const asset = r.data?.[0]?.result as Address | undefined;
  const meta = useReadContracts({
    contracts: [
      { address: asset, abi: ABIS.erc20, functionName: "symbol", chainId: CHAIN_ID },
      { address: asset, abi: ABIS.erc20, functionName: "decimals", chainId: CHAIN_ID },
    ],
    query: { enabled: !!asset },
  });
  const token: TokenOption | undefined =
    asset && meta.data?.[1]?.result !== undefined
      ? { address: asset, symbol: String(meta.data[0]?.result ?? "USD"), name: "Vault asset", decimals: Number(meta.data[1].result), kind: "canonical", logo_url: null }
      : undefined;
  return {
    vault,
    token,
    totalAssets: r.data?.[1]?.result as bigint | undefined,
    totalBorrows: r.data?.[2]?.result as bigint | undefined,
    utilization: r.data?.[3]?.result as bigint | undefined,
    borrowApr: aprFromPerSecondWad(r.data?.[4]?.result as bigint | undefined),
    supplyApr: aprFromPerSecondWad(r.data?.[5]?.result as bigint | undefined),
  };
}

function LendPanel({ v }: { v: ReturnType<typeof useVault> }) {
  const { address } = useAccount();
  const [mode, setMode] = React.useState<"deposit" | "withdraw">("deposit");
  const [amount, setAmount] = React.useState("");
  const tx = useTx();
  const shares = useTokenBalance(v.vault ?? undefined);
  const max = useReadContract({ address: v.vault ?? undefined, abi: ABIS.lendingVault, functionName: "maxWithdraw", args: address ? [address] : undefined, chainId: CHAIN_ID, query: { enabled: !!address && !!v.vault } });
  if (!v.vault || !v.token) return <div className="skeleton h-48" />;
  const raw = parseAmount(amount, v.token.decimals);
  return (
    <div className="space-y-3">
      <div className="grid grid-cols-2 border">
        {(["deposit", "withdraw"] as const).map((m) => (
          <button key={m} onClick={() => setMode(m)} className={cn("py-2 font-mono text-[12px] uppercase tracking-button", mode === m ? "bg-surface-2 text-primary-text" : "text-fg-2")}>
            {m}
          </button>
        ))}
      </div>
      <AmountField label={mode === "deposit" ? "Supply" : "Withdraw"} value={amount} onChange={setAmount} token={mode === "deposit" ? v.token : undefined} right={<span className="font-mono text-sm">{v.token.symbol}</span>} />
      <KV label="Your supply" value={max.data !== undefined ? `${formatTokenAmount(max.data, v.token.decimals)} ${v.token.symbol}` : "—"} />
      <KV label="Vault shares" value={shares.value !== undefined ? formatTokenAmount(shares.value, v.token.decimals) : "—"} />
      <ConnectGate>
        {mode === "deposit" ? (
          <ApproveGate token={v.token} spender={v.vault} amount={raw ?? 0n}>
            <Button className="w-full" size="lg" disabled={!raw || tx.busy} onClick={() => tx.send({ address: v.vault!, abi: ABIS.lendingVault, functionName: "deposit", args: [raw!, address!] })}>
              {tx.busy ? "Supplying…" : "Supply"}
            </Button>
          </ApproveGate>
        ) : (
          <Button className="w-full" size="lg" disabled={!raw || tx.busy} onClick={() => tx.send({ address: v.vault!, abi: ABIS.lendingVault, functionName: "withdraw", args: [raw!, address!, address!] })}>
            {tx.busy ? "Withdrawing…" : "Withdraw"}
          </Button>
        )}
      </ConnectGate>
      <TxNotice tx={tx} />
    </div>
  );
}

function HealthBadge({ hf }: { hf: number | null }) {
  const s = healthState(hf);
  const variant = s === "safe" ? "default" : s === "warning" ? "warning" : s === "danger" ? "danger" : "neutral";
  return <Badge variant={variant}>{hf === null ? "No debt" : `Health ${hf.toFixed(2)}`}</Badge>;
}

function LoanCard({ tokenId, token, cm }: { tokenId: bigint; token: TokenOption; cm: Address }) {
  const { address } = useAccount();
  const [amount, setAmount] = React.useState("");
  const tx = useTx();
  const h = useReadContract({ address: cm, abi: ABIS.creditManager, functionName: "health", args: [tokenId], chainId: CHAIN_ID, query: { refetchInterval: 20_000 } });
  const debt = useReadContract({ address: cm, abi: ABIS.creditManager, functionName: "debtOf", args: [tokenId], chainId: CHAIN_ID, query: { refetchInterval: 20_000 } });
  const [valueUsd, maxBorrow, hfRaw] = h.data ?? [0n, 0n, 0n];
  const hf = debt.data && debt.data > 0n ? Number(hfRaw) / 1e18 : null;
  const raw = parseAmount(amount, token.decimals);
  const available = maxBorrow > (debt.data ?? 0n) ? maxBorrow - (debt.data ?? 0n) : 0n;
  return (
    <Panel title={`Loan · NFT #${tokenId}`} aside={<HealthBadge hf={hf} />}>
      <div className="space-y-3">
        <div>
          <KV label="Collateral" value={formatUsd(Number(valueUsd) / 1e18)} />
          <KV label="Debt" value={`${formatTokenAmount(debt.data ?? 0n, token.decimals)} ${token.symbol}`} />
          <KV label="Can borrow" value={`${formatTokenAmount(available, token.decimals)} ${token.symbol}`} />
        </div>
        <AmountField label="Amount" value={amount} onChange={setAmount} token={token} right={<span className="font-mono text-sm">{token.symbol}</span>} />
        <div className="grid grid-cols-2 gap-2">
          <Button disabled={!raw || raw > available || tx.busy} onClick={() => tx.send({ address: cm, abi: ABIS.creditManager, functionName: "borrow", args: [tokenId, raw!, address!] })}>
            Borrow
          </Button>
          <ApproveGate token={token} spender={cm} amount={raw ?? 0n}>
            <Button variant="secondary" className="w-full" disabled={!raw || tx.busy} onClick={() => tx.send({ address: cm, abi: ABIS.creditManager, functionName: "repay", args: [tokenId, raw!] })}>
              Repay
            </Button>
          </ApproveGate>
          <Button variant="ghost" disabled={tx.busy} onClick={() => tx.send({ address: cm, abi: ABIS.creditManager, functionName: "harvest", args: [tokenId] })}>
            Harvest fees
          </Button>
          <Button variant="ghost" disabled={tx.busy || (debt.data ?? 0n) > 0n} onClick={() => tx.send({ address: cm, abi: ABIS.creditManager, functionName: "release", args: [tokenId] })}>
            Release NFT
          </Button>
        </div>
        <TxNotice tx={tx} />
      </div>
    </Panel>
  );
}

function PledgePanel({ cm }: { cm: Address }) {
  const { address } = useAccount();
  const positions = addressOf("positions");
  const pos = usePositionsApi(address);
  const tx = useTx();
  const approved = useReadContract({
    address: positions ?? undefined,
    abi: ABIS.positions,
    functionName: "isApprovedForAll",
    args: address ? [address, cm] : undefined,
    chainId: CHAIN_ID,
    query: { enabled: !!address && !!positions },
  });
  if (!positions) return <NotDeployed name="Positions" />;
  const free = pos.data?.v4.filter((p) => !p.pledged) ?? [];
  if (!address) return <ConnectGate>{null}</ConnectGate>;
  if (!free.length) return <EmptyState title="No position to pledge">Mint a v4 position on a pool with a priced pair first.</EmptyState>;
  return (
    <div className="space-y-3">
      {!approved.data && (
        <Button
          className="w-full"
          disabled={tx.busy}
          onClick={async () => {
            await tx.send({ address: positions, abi: ABIS.positions, functionName: "setApprovalForAll", args: [cm, true] });
            void approved.refetch();
          }}
        >
          Allow credit manager to hold positions
        </Button>
      )}
      {free.map((p) => (
        <div key={p.token_id} className="flex items-center justify-between gap-3 border px-3 py-2">
          <span className="flex items-center gap-3">
            <span className="font-mono text-xs text-muted">#{p.token_id}</span>
            {p.pool && <PairLabel pool={p.pool} />}
          </span>
          <Button size="sm" disabled={!approved.data || tx.busy} onClick={() => tx.send({ address: cm, abi: ABIS.creditManager, functionName: "pledge", args: [BigInt(p.token_id)] })}>
            Pledge
          </Button>
        </div>
      ))}
      <TxNotice tx={tx} />
    </div>
  );
}

export function CreditView() {
  const { address } = useAccount();
  const v = useVault();
  const cm = addressOf("creditManager");
  const risk = useReadContract({ address: cm ?? undefined, abi: ABIS.creditManager, functionName: "riskParams", chainId: CHAIN_ID, query: { enabled: !!cm } });
  const loans = useReadContract({ address: cm ?? undefined, abi: ABIS.creditManager, functionName: "loansOf", args: address ? [address] : undefined, chainId: CHAIN_ID, query: { enabled: !!cm && !!address } });
  const d = v.token?.decimals ?? 6;

  return (
    <>
      <PageHeader eyebrow="Credit" title="Borrow against LP positions" description="Supply the vault stablecoin to earn interest, or pledge a v4 position NFT and borrow against it while it keeps earning fees." />
      {!v.vault || !cm ? (
        <div className="mt-8">
          <NotDeployed name="Credit" />
        </div>
      ) : (
        <>
          <StatGrid className="mt-8">
            <Stat label="Supplied" value={v.totalAssets !== undefined ? formatTokenAmount(v.totalAssets, d, 0) : "—"} hint={v.token?.symbol} />
            <Stat label="Borrowed" value={v.totalBorrows !== undefined ? formatTokenAmount(v.totalBorrows, d, 0) : "—"} hint={v.utilization !== undefined ? `${formatBps(Number(v.utilization))} utilized` : undefined} />
            <Stat label="Supply APR" value={formatPct(v.supplyApr)} />
            <Stat label="Borrow APR" value={formatPct(v.borrowApr)} />
          </StatGrid>
          <div className="mt-8 grid gap-6 lg:grid-cols-[1fr_1.4fr]">
            <div className="space-y-6">
              <Panel title="Lend" brackets>
                <LendPanel v={v} />
              </Panel>
              {risk.data && (
                <Panel title="Risk parameters">
                  <KV label="Max LTV" value={formatBps(risk.data[0])} />
                  <KV label="Liquidation threshold" value={formatBps(risk.data[1])} />
                  <KV label="Liquidation bonus" value={formatBps(risk.data[2])} />
                </Panel>
              )}
            </div>
            <div className="space-y-6">
              <Panel title="Pledge a position">
                <PledgePanel cm={cm} />
              </Panel>
              {v.token && loans.data?.map((id) => <LoanCard key={id.toString()} tokenId={id} token={v.token!} cm={cm} />)}
            </div>
          </div>
        </>
      )}
    </>
  );
}
