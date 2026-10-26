"use client";

import * as React from "react";
import Link from "next/link";
import { ArrowUpRight, Check, ChevronDown, Search } from "lucide-react";
import { erc20Abi, maxUint256, type Address } from "viem";
import { useAccount } from "wagmi";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import type { UseQueryResult } from "@tanstack/react-query";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { useHealth } from "@/hooks/use-api";
import { useAllowance, useTokenBalance, type TokenOption } from "@/hooks/use-token";
import { useTx } from "@/hooks/use-tx";
import { ApiError, type ApiPool } from "@/lib/api";
import { formatTokenAmount, shortAddress } from "@/lib/format";
import { CHAIN_ID, explorerAddress, explorerTx } from "@/lib/network";
import { VENUE_LABEL } from "@/lib/routing";
import { cn } from "@/lib/utils";

// ------------------------------------------------------------------ layout

export function PageHeader({
  eyebrow,
  title,
  description,
  actions,
}: {
  eyebrow: string;
  title: string;
  description?: React.ReactNode;
  actions?: React.ReactNode;
}) {
  return (
    <div className="flex flex-col gap-4 border-b pb-8 pt-10 md:flex-row md:items-end md:justify-between">
      <div className="max-w-2xl space-y-3">
        <p className="eyebrow">{eyebrow}</p>
        <h1 className="text-3xl font-medium tracking-tight md:text-4xl">{title}</h1>
        {description && <p className="text-fg-2">{description}</p>}
      </div>
      {actions && <div className="flex flex-wrap gap-2">{actions}</div>}
    </div>
  );
}

export function Panel({
  title,
  aside,
  brackets,
  className,
  children,
}: {
  title?: React.ReactNode;
  aside?: React.ReactNode;
  brackets?: boolean;
  className?: string;
  children: React.ReactNode;
}) {
  return (
    <section className={cn("relative border bg-surface", brackets && "brackets", className)}>
      {brackets && <span className="brackets-b" aria-hidden />}
      {(title || aside) && (
        <header className="flex min-h-11 items-center justify-between gap-3 border-b px-4">
          {title && <p className="eyebrow">{title}</p>}
          {aside}
        </header>
      )}
      <div className="p-4">{children}</div>
    </section>
  );
}

export function KV({ label, value, className }: { label: React.ReactNode; value: React.ReactNode; className?: string }) {
  return (
    <div className={cn("flex items-center justify-between gap-4 py-1.5 text-sm", className)}>
      <span className="font-mono text-[12px] uppercase tracking-button text-muted">{label}</span>
      <span className="num text-right">{value}</span>
    </div>
  );
}

export function Stat({ label, value, hint }: { label: string; value: React.ReactNode; hint?: React.ReactNode }) {
  return (
    <div className="space-y-1.5 bg-surface p-4">
      <p className="eyebrow">{label}</p>
      <p className="num text-2xl">{value}</p>
      {hint && <p className="text-xs text-muted">{hint}</p>}
    </div>
  );
}

export function StatGrid({ children, className }: { children: React.ReactNode; className?: string }) {
  return <div className={cn("hairline-grid grid grid-cols-2 border md:grid-cols-4", className)}>{children}</div>;
}

// ------------------------------------------------------------------ status

export type DotState = "live" | "degraded" | "down" | "idle";

export function StatusDot({ state, className }: { state: DotState; className?: string }) {
  const color = { live: "bg-primary", degraded: "bg-warning", down: "bg-danger", idle: "bg-muted" }[state];
  return <span className={cn("inline-block size-1.5 rounded-full", color, state === "live" && "animate-pulse", className)} />;
}

export function IndexerStatus({ className }: { className?: string }) {
  const h = useHealth();
  // only this app's network matters; other chains in the same indexer may be idle or behind
  const own = h.data?.indexing.find((i) => i.chain_id === CHAIN_ID);
  const stale = own && h.data ? Date.parse(h.data.timestamp) - Date.parse(own.updated_at) > 5 * 60_000 : true;
  const behind = own?.head_block && own.last_block ? own.head_block - own.last_block > 500 : false;
  const state: DotState = h.isError ? "down" : !h.data ? "idle" : !own ? "down" : stale || behind ? "degraded" : "live";
  const label = { live: "Indexer live", degraded: "Indexer lagging", down: "Indexer offline", idle: "Indexer…" }[state];
  return (
    <span className={cn("items-center gap-2 font-mono text-[11px] uppercase tracking-eyebrow text-muted", className)}>
      <StatusDot state={state} />
      {label}
    </span>
  );
}

export function EmptyState({ title, children, action }: { title: string; children?: React.ReactNode; action?: React.ReactNode }) {
  return (
    <div className="flex flex-col items-center justify-center gap-3 border border-dashed px-6 py-14 text-center">
      <p className="font-mono text-[12px] uppercase tracking-button text-fg-2">{title}</p>
      {children && <p className="max-w-md text-sm text-muted">{children}</p>}
      {action}
    </div>
  );
}

/** Loading / offline / error / empty handling around an indexer query. */
export function QueryState<T>({
  query,
  isEmpty,
  empty,
  skeleton,
  children,
}: {
  query: UseQueryResult<T>;
  isEmpty?: (d: T) => boolean;
  empty?: React.ReactNode;
  skeleton?: React.ReactNode;
  children: (data: T) => React.ReactNode;
}) {
  if (query.isLoading) return <>{skeleton ?? <div className="skeleton h-40 w-full" />}</>;
  if (query.isError) {
    const offline = query.error instanceof ApiError && query.error.offline;
    return (
      <EmptyState title={offline ? "Indexer offline" : "Could not load data"}>
        {offline
          ? "The indexer API is not reachable right now. On-chain actions still work; lists and charts will fill in once it is back."
          : (query.error as Error).message}
      </EmptyState>
    );
  }
  if (query.data === undefined || (isEmpty && isEmpty(query.data))) return <>{empty ?? <EmptyState title="Nothing here yet" />}</>;
  return <>{children(query.data)}</>;
}

export function NotDeployed({ name }: { name: string }) {
  return (
    <EmptyState title={`${name} not deployed on this network`}>
      The contract address is not set for this network yet. It appears here as soon as the deployment is published to the SDK.
    </EmptyState>
  );
}

export function ConnectGate({ children, label = "Connect wallet" }: { children: React.ReactNode; label?: string }) {
  const { isConnected } = useAccount();
  if (isConnected) return <>{children}</>;
  return (
    <ConnectButton.Custom>
      {({ openConnectModal }) => (
        <Button className="w-full" size="lg" onClick={openConnectModal}>
          {label}
        </Button>
      )}
    </ConnectButton.Custom>
  );
}

// ------------------------------------------------------------------ links & badges

export function AddressLink({ address, label, className }: { address: string | null | undefined; label?: string; className?: string }) {
  if (!address) return <span className="text-muted">—</span>;
  const href = explorerAddress(address);
  const text = label ?? shortAddress(address);
  if (!href) return <span className={cn("font-mono", className)}>{text}</span>;
  return (
    <a href={href} target="_blank" rel="noreferrer" className={cn("inline-flex items-center gap-1 font-mono hover:text-primary-text", className)}>
      {text}
      <ArrowUpRight className="size-3" />
    </a>
  );
}

export function TxLink({ hash }: { hash: string }) {
  const href = explorerTx(hash);
  return href ? (
    <a href={href} target="_blank" rel="noreferrer" className="inline-flex items-center gap-1 font-mono hover:text-primary-text">
      {shortAddress(hash, 8, 6)}
      <ArrowUpRight className="size-3" />
    </a>
  ) : (
    <span className="font-mono">{shortAddress(hash, 8, 6)}</span>
  );
}

export function VenueBadge({ venue }: { venue: string }) {
  const variant = venue === "V4" ? "default" : venue === "LAUNCH" ? "warning" : "accent";
  return <Badge variant={variant}>{VENUE_LABEL[venue] ?? venue}</Badge>;
}

export function ModeBadge({ mode }: { mode: ApiPool["mode"] }) {
  if (mode === "oracle") return <Badge variant="accent">Oracle guarded</Badge>;
  if (mode === "dynamic") return <Badge variant="default">Dynamic fee</Badge>;
  return null;
}

export function TokenIcon({ symbol, className }: { symbol: string; className?: string }) {
  // Deterministic monogram; no third-party logos.
  let h = 0;
  for (const ch of symbol) h = (h * 31 + ch.charCodeAt(0)) % 6;
  return (
    <span
      className={cn("inline-flex size-6 shrink-0 items-center justify-center rounded-full border font-mono text-[9px] font-semibold", className)}
      style={{ background: `rgb(var(--chart-${h + 1}) / 0.18)`, color: `rgb(var(--chart-${h + 1}))` }}
      aria-hidden
    >
      {symbol.slice(0, 3)}
    </span>
  );
}

export function PairLabel({ pool }: { pool: Pick<ApiPool, "token0" | "token1"> }) {
  return (
    <span className="flex items-center gap-2">
      <span className="flex -space-x-2">
        <TokenIcon symbol={pool.token0.symbol} />
        <TokenIcon symbol={pool.token1.symbol} />
      </span>
      <span className="font-medium">
        {pool.token0.symbol}
        <span className="text-muted"> / </span>
        {pool.token1.symbol}
      </span>
    </span>
  );
}

/**
 * 24h price line with an area fill, hourly volume bars and an end marker. The line is scaled to its own
 * range so small moves still read; a series that never moves draws a steady dashed line at mid height.
 */
export function Sparkline({ values, volume, className }: { values: number[]; volume?: number[]; className?: string }) {
  const id = React.useId();
  if (values.length < 2) return <span className="text-muted">—</span>;
  const W = 100;
  const H = 32;
  const padY = 4;
  const min = Math.min(...values);
  const max = Math.max(...values);
  const mid = (min + max) / 2 || 1;
  const flat = (max - min) / Math.abs(mid) < 1e-6;
  const x = (i: number) => (i / (values.length - 1)) * W;
  const y = (v: number) => (flat ? H / 2 : H - padY - ((v - min) / (max - min)) * (H - padY * 2));
  const up = values[values.length - 1]! >= values[0]!;
  const line = values.map((v, i) => `${x(i).toFixed(2)},${y(v).toFixed(2)}`);
  const area = `M0,${H} L${line.join(" L")} L${W},${H} Z`;
  const vmax = volume?.length ? Math.max(...volume) : 0;
  const bars = volume && vmax > 0 ? volume.slice(-values.length) : [];
  const lastY = y(values[values.length - 1]!);
  return (
    <svg viewBox={`0 0 ${W + 4} ${H}`} preserveAspectRatio="none" className={cn("h-8 w-24 overflow-visible", up ? "text-primary" : "text-danger", className)} aria-hidden>
      <defs>
        <linearGradient id={id} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor="currentColor" stopOpacity="0.28" />
          <stop offset="100%" stopColor="currentColor" stopOpacity="0" />
        </linearGradient>
      </defs>
      {bars.map((v, i) => {
        const h = (v / vmax) * (H * 0.4);
        return h > 0.4 ? <rect key={i} x={x(i) - 0.8} y={H - h} width="1.6" height={h} fill="currentColor" opacity="0.35" /> : null;
      })}
      {!flat && <path d={area} fill={`url(#${id})`} />}
      <polyline
        points={line.join(" ")}
        fill="none"
        stroke="currentColor"
        strokeWidth="1.5"
        strokeDasharray={flat ? "3 3" : undefined}
        strokeLinejoin="round"
        strokeLinecap="round"
        vectorEffect="non-scaling-stroke"
      />
      <circle cx={W} cy={lastY} r="1.6" fill="currentColor" vectorEffect="non-scaling-stroke" />
    </svg>
  );
}

// ------------------------------------------------------------------ tokens & amounts

export function TokenSelect({
  tokens,
  value,
  onChange,
  exclude,
}: {
  tokens: TokenOption[];
  value: TokenOption | undefined;
  onChange: (t: TokenOption) => void;
  exclude?: string;
}) {
  const [open, setOpen] = React.useState(false);
  const [q, setQ] = React.useState("");
  const list = tokens.filter(
    (t) =>
      t.address.toLowerCase() !== exclude?.toLowerCase() &&
      (!q || t.symbol.toLowerCase().includes(q.toLowerCase()) || t.name.toLowerCase().includes(q.toLowerCase()) || t.address.toLowerCase() === q.toLowerCase()),
  );
  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <button type="button" className="flex h-10 shrink-0 items-center gap-2 rounded-sm border border-border-strong bg-surface px-3 transition-ui hover:border-primary">
          {value ? (
            <>
              <TokenIcon symbol={value.symbol} />
              <span className="font-mono text-sm">{value.symbol}</span>
            </>
          ) : (
            <span className="font-mono text-[12px] uppercase tracking-button">Select</span>
          )}
          <ChevronDown className="size-3.5 text-muted" />
        </button>
      </PopoverTrigger>
      <PopoverContent align="end" className="w-72 p-0">
        <div className="flex items-center gap-2 border-b px-3">
          <Search className="size-4 text-muted" />
          <input
            autoFocus
            value={q}
            onChange={(e) => setQ(e.target.value)}
            placeholder="Search symbol or address"
            className="h-10 w-full bg-transparent text-sm outline-none placeholder:text-muted"
          />
        </div>
        <ul className="max-h-72 overflow-y-auto py-1">
          {list.map((t) => (
            <li key={t.address}>
              <button
                type="button"
                onClick={() => {
                  onChange(t);
                  setOpen(false);
                  setQ("");
                }}
                className="flex w-full items-center gap-3 px-3 py-2 text-left transition-ui hover:bg-surface-2"
              >
                <TokenIcon symbol={t.symbol} />
                <span className="flex-1">
                  <span className="block text-sm">{t.symbol}</span>
                  <span className="block text-xs text-muted">{t.name}</span>
                </span>
                {t.kind !== "canonical" && <Badge variant="neutral">{t.kind}</Badge>}
                {value?.address === t.address && <Check className="size-4 text-primary-text" />}
              </button>
            </li>
          ))}
          {!list.length && <li className="px-3 py-6 text-center text-sm text-muted">No tokens match.</li>}
        </ul>
      </PopoverContent>
    </Popover>
  );
}

export function AmountField({
  label,
  value,
  onChange,
  token,
  readOnly,
  right,
  footer,
}: {
  label: string;
  value: string;
  onChange?: (v: string) => void;
  token: TokenOption | undefined;
  readOnly?: boolean;
  right?: React.ReactNode;
  footer?: React.ReactNode;
}) {
  const bal = useTokenBalance(token?.address);
  return (
    <div className="space-y-3 border bg-surface-2 p-4 transition-ui focus-within:border-ring">
      <div className="flex items-center justify-between">
        <span className="eyebrow">{label}</span>
        {token && bal.value !== undefined && (
          <button
            type="button"
            disabled={readOnly}
            onClick={() => onChange?.(formatTokenAmount(bal.value!, token.decimals, token.decimals).replace(/,/g, ""))}
            className="font-mono text-[11px] uppercase tracking-button text-muted transition-ui enabled:hover:text-primary-text"
          >
            Bal {formatTokenAmount(bal.value, token.decimals)}
          </button>
        )}
      </div>
      <div className="flex items-center gap-3">
        <input
          inputMode="decimal"
          placeholder="0.0"
          value={value}
          readOnly={readOnly}
          onChange={(e) => {
            const v = e.target.value.replace(",", ".");
            if (/^\d*\.?\d*$/.test(v)) onChange?.(v);
          }}
          className="num w-full min-w-0 bg-transparent text-[28px] leading-none outline-none placeholder:text-muted"
        />
        {right}
      </div>
      {footer}
    </div>
  );
}

// ------------------------------------------------------------------ transactions

export function TxNotice({ tx }: { tx: ReturnType<typeof useTx> }) {
  if (tx.status === "idle") return null;
  const text = {
    wallet: "Confirm in your wallet…",
    pending: "Transaction pending…",
    success: "Transaction confirmed.",
    error: tx.error ?? "Transaction failed.",
    idle: "",
  }[tx.status];
  return (
    <div
      role="status"
      className={cn(
        "flex items-center justify-between gap-3 border px-3 py-2 text-sm",
        tx.status === "error" && "border-danger/50 bg-danger-soft text-danger",
        tx.status === "success" && "border-primary/40 bg-primary-soft text-primary-text",
      )}
    >
      <span className="break-words">{text}</span>
      {tx.hash && <TxLink hash={tx.hash} />}
    </div>
  );
}

/**
 * Renders an Approve button while the allowance for `spender` is below `amount`, then `children`.
 * Native ETH never needs approval.
 */
export function ApproveGate({
  token,
  spender,
  amount,
  children,
}: {
  token: TokenOption | undefined;
  spender: Address | null;
  amount: bigint;
  children: React.ReactNode;
}) {
  const { allowance, refetch } = useAllowance(token?.address, spender);
  const tx = useTx();
  if (!token || !spender || amount === 0n || allowance === undefined || allowance >= amount) return <>{children}</>;
  return (
    <div className="space-y-2">
      <Button
        className="w-full"
        size="lg"
        disabled={tx.busy}
        onClick={async () => {
          await tx.send({ address: token.address as Address, abi: erc20Abi, functionName: "approve", args: [spender, maxUint256] });
          void refetch();
        }}
      >
        {tx.busy ? "Approving…" : `Approve ${token.symbol}`}
      </Button>
      <TxNotice tx={tx} />
    </div>
  );
}

export function InlineLink({ href, children }: { href: string; children: React.ReactNode }) {
  return (
    <Link href={href} className="text-primary-text underline-offset-4 hover:underline">
      {children}
    </Link>
  );
}
