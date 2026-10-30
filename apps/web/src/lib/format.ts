import { formatUnits } from "viem";

const compact = new Intl.NumberFormat("en-US", { notation: "compact", maximumFractionDigits: 2 });

export function formatUsd(v: number | null | undefined, opts: { compact?: boolean } = {}): string {
  if (v === null || v === undefined || !Number.isFinite(v)) return "—";
  const abs = Math.abs(v);
  if (opts.compact && abs >= 1_000) return `$${compact.format(v)}`;
  const digits = abs > 0 && abs < 1 ? Math.min(6, Math.max(2, 1 - Math.floor(Math.log10(abs)) + 2)) : 2;
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
    minimumFractionDigits: 2,
    maximumFractionDigits: digits,
  }).format(v);
}

export function formatCompact(v: number | null | undefined): string {
  if (v === null || v === undefined || !Number.isFinite(v)) return "—";
  return compact.format(v);
}

/** Significant-digit aware number formatting for prices and token amounts. */
export function formatNumber(v: number | null | undefined, maxSig = 6): string {
  if (v === null || v === undefined || !Number.isFinite(v)) return "—";
  if (v === 0) return "0";
  const abs = Math.abs(v);
  if (abs >= 1e9) return compact.format(v);
  if (abs >= 1) return new Intl.NumberFormat("en-US", { maximumFractionDigits: Math.max(0, maxSig - Math.floor(Math.log10(abs)) - 1) }).format(v);
  if (abs < 1e-9) return v.toExponential(2);
  return new Intl.NumberFormat("en-US", { maximumSignificantDigits: maxSig }).format(v);
}

export function formatPct(v: number | null | undefined, digits = 2, opts: { sign?: boolean } = {}): string {
  if (v === null || v === undefined || !Number.isFinite(v)) return "—";
  const s = `${v.toFixed(digits)}%`;
  return opts.sign && v > 0 ? `+${s}` : s;
}

/** Fee in pips (1e-6) → "0.30%". */
export function formatFeePips(pips: number | null | undefined): string {
  if (pips === null || pips === undefined) return "—";
  const pct = pips / 10_000;
  return `${pct.toFixed(pct < 0.1 ? 3 : 2).replace(/0$/, "")}%`;
}

export function formatBps(bps: number | null | undefined): string {
  if (bps === null || bps === undefined) return "—";
  return `${(bps / 100).toFixed(2)}%`;
}

export function shortAddress(a: string | null | undefined, head = 6, tail = 4): string {
  if (!a) return "—";
  if (a.length <= head + tail + 2) return a;
  return `${a.slice(0, head)}…${a.slice(-tail)}`;
}

/** Raw integer amount (bigint or decimal string) → human string with up to `maxDecimals`. */
export function formatTokenAmount(raw: bigint | string | null | undefined, decimals: number, maxDecimals = 6): string {
  if (raw === null || raw === undefined) return "—";
  let value: bigint;
  try {
    value = typeof raw === "bigint" ? raw : BigInt(raw);
  } catch {
    return "—";
  }
  const s = formatUnits(value, decimals);
  const [int, frac = ""] = s.split(".");
  const intFmt = BigInt(int!.replace("-", "") || "0").toLocaleString("en-US");
  const sign = value < 0n ? "-" : "";
  const trimmed = frac.slice(0, maxDecimals).replace(/0+$/, "");
  if (!trimmed && value !== 0n && BigInt(int!.replace("-", "") || "0") === 0n) return `${sign}<0.${"0".repeat(Math.max(0, maxDecimals - 1))}1`;
  return trimmed ? `${sign}${intFmt}.${trimmed}` : `${sign}${intFmt}`;
}

export function timeAgo(iso: string | number | Date | null | undefined, now: number = Date.now()): string {
  if (iso === null || iso === undefined) return "—";
  const t = iso instanceof Date ? iso.getTime() : typeof iso === "number" ? (iso < 1e12 ? iso * 1000 : iso) : Date.parse(iso);
  if (!Number.isFinite(t)) return "—";
  const s = Math.max(0, Math.round((now - t) / 1000));
  if (s < 60) return `${s}s ago`;
  const m = Math.round(s / 60);
  if (m < 60) return `${m}m ago`;
  const h = Math.round(m / 60);
  if (h < 48) return `${h}h ago`;
  return `${Math.round(h / 24)}d ago`;
}

export function formatDateTime(v: string | number | null | undefined): string {
  if (v === null || v === undefined) return "—";
  const t = typeof v === "number" ? (v < 1e12 ? v * 1000 : v) : Date.parse(v);
  if (!Number.isFinite(t)) return "—";
  return new Date(t).toISOString().replace("T", " ").slice(0, 16) + " UTC";
}

/** Parse a user-typed decimal string into raw units; returns null on invalid input. */
export function parseAmount(input: string, decimals: number): bigint | null {
  const v = input.trim().replace(/,/g, "");
  if (!/^\d*\.?\d*$/.test(v) || v === "" || v === ".") return null;
  const [i = "0", f = ""] = v.split(".");
  if (f.length > decimals) return null;
  try {
    return BigInt(i || "0") * 10n ** BigInt(decimals) + BigInt((f + "0".repeat(decimals)).slice(0, decimals) || "0");
  } catch {
    return null;
  }
}
