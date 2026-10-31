"use client";

import * as React from "react";
import dynamic from "next/dynamic";
import Link from "next/link";
import { ArrowDown, ArrowRight, ArrowUp, ArrowUpRight, Check, Copy } from "lucide-react";
import { useBlockNumber } from "wagmi";
import { Button } from "@/components/ui/button";
import { StatusDot } from "@/components/kit";
import { useDashboard } from "@/hooks/use-api";
import { FEATURES } from "@/lib/features";
import { useOpenVenues } from "@/hooks/use-venues";
import { AETH_TOKEN } from "@/lib/token";
import { formatNumber, formatUsd } from "@/lib/format";
import { CHAIN, CHAIN_ID } from "@/lib/network";
import { cn } from "@/lib/utils";
import { APP_VERSION } from "@/lib/version";
import type { RibbonFrame } from "./glyph-ribbon";
import { BinsSchematic, BurnSchematic, CodeSchematic, CurveSchematic, FeeSchematic, HealthSchematic, RouterSchematic } from "./schematics";

const GlyphRibbon = dynamic(() => import("./glyph-ribbon").then((m) => m.GlyphRibbon), { ssr: false });

interface Section {
  key: string;
  label: string;
  title: string;
  body: string;
  specs: [string, string][];
  /** floating data tags around the ribbon: [text, left %, top %] within the right half */
  tags: [string, number, number][];
  cta?: { href: string; label: string };
  schematic?: React.ReactNode;
  form: string;
  /** ribbon shape index this section morphs into (see ribbon-shaders) */
  shape: number;
  /** section is dropped while this feature is hidden */
  feature?: keyof typeof FEATURES;
  /** the CTA needs a venue that may still be closed on the active network; `closedCta` replaces it then */
  needs?: "dlmm" | "stock";
  closedCta?: { href: string; label: string } | { soon: string };
}

const ALL_SECTIONS: Section[] = [
  {
    key: "hero",
    label: "Liquidity layer",
    title: "Every venue.\nOne route.",
    body: "Aethra aggregates liquidity across Uniswap v4 hook pools, DLMM bins and DAMM ranges on Robinhood Chain, with volatility-adaptive fees and oracle-guarded stock markets.",
    specs: [],
    tags: [
      ["V4 · DLMM · DAMM", 30, 16],
      ["∞ PATHS → 1 ROUTE", 64, 80],
      ["ORBIT · ON-CHAIN QUOTES", 4, 74],
    ],
    form: "Liquidity ring",
    shape: 0,
  },
  {
    key: "router",
    label: "Smart order routing",
    title: "Three venues.\nOne best quote.",
    body: "The router simulates v4 hook pools, DLMM bins and DAMM ranges with on-chain quotes, compares direct and two-hop paths, and settles the best one atomically in a single transaction.",
    specs: [
      ["Venues", "3"],
      ["Path search", "direct + 2-hop"],
      ["Quotes", "on-chain · eth_call"],
      ["Native ETH", "auto wrap"],
    ],
    tags: [
      ["hop[0] V4 → aUSD", 20, 22],
      ["hop[1] DLMM → TSLA", 68, 64],
      ["Δout +0.42%", 28, 74],
    ],
    cta: { href: "/swap", label: "Open swap" },
    schematic: <RouterSchematic />,
    form: "Figure-eight route",
    shape: 1,
  },
  {
    key: "fees",
    label: "Adaptive fees · Oracle guard",
    title: "Volatility-aware fees.\nOracle-guarded markets.",
    body: "One v4 hook prices every pool. The fee rises with realized volatility and decays as the market settles, so LPs are paid for the risk they carry. Stock pools add an oracle guard: swaps toward the reference price pay the base fee, swaps away pay more, and a circuit breaker reverts swaps that push the pool too far from the oracle.",
    specs: [
      ["Base fee", "0.05% · 0.30% stock"],
      ["Fee ceiling", "2% · 3% stock"],
      ["Decay", "600 s"],
      ["Stock guard", "oracle + breaker"],
    ],
    tags: [
      ["σ 1h ↑ → fee 1.6%", 20, 20],
      ["oracle Δ 42 bps", 64, 68],
      ["breaker ARMED", 16, 80],
    ],
    cta: { href: "/pools?filter=stock", label: "Explore stock pools" },
    needs: "stock",
    closedCta: { href: "/pools", label: "Explore pools" },
    schematic: <FeeSchematic />,
    form: "Volatility wave",
    shape: 2,
  },
  {
    key: "bins",
    label: "DLMM · Limit orders",
    title: "Precision liquidity.\nBin by bin.",
    body: "Liquidity sits in discrete price bins with zero slippage inside each bin. Shape a deposit as spot, curve or bid-ask, or place a limit order in a single bin that fills as price crosses it. Filled orders can be claimed by you or by any keeper.",
    specs: [
      ["Bin steps", "1 · 5 · 10 · 25 · 50 · 100 bps"],
      ["Shapes", "spot · curve · bid-ask"],
      ["Orders", "single-bin limit"],
      ["Claims", "owner or any keeper"],
    ],
    tags: [
      ["active bin −7949", 26, 18],
      ["token1 ◀", 8, 70],
      ["▶ token0", 72, 70],
    ],
    cta: { href: "/orders", label: "Place a limit order" },
    needs: "dlmm",
    closedCta: { soon: "Opening soon on this network" },
    schematic: <BinsSchematic />,
    form: "Bin histogram",
    shape: 3,
  },
  {
    key: "launch",
    label: "Launch markets",
    title: "Fair curves.\nLocked liquidity.",
    body: "Launch a token on a bonding curve priced in ETH. When the curve sells out it graduates into a v4 hook pool with the raised ETH, and that liquidity is locked forever. Only the launchpad can open the pool, so nobody can front-run the price.",
    specs: [
      ["Supply", "1,000,000,000"],
      ["On curve", "800M"],
      ["Graduates", "≈ 4.4 ETH"],
      ["LP", "locked forever"],
    ],
    tags: [
      ["k = x · y", 20, 22],
      ["progress 28%", 68, 52],
      ["→ v4 pool", 32, 80],
    ],
    cta: { href: "/launch", label: "Launch a token" },
    schematic: <CurveSchematic />,
    form: "Bonding spiral",
    shape: 4,
    feature: "launchpad",
  },
  {
    key: "credit",
    label: "Credit",
    title: "Borrow against\nliquidity.",
    body: "Pledge a position NFT and borrow the vault stablecoin while the position keeps earning. Fees can repay the loan automatically. Lenders earn a utilization-based rate in an ERC-4626 vault.",
    specs: [
      ["Max LTV", "50%"],
      ["Liquidation", "70%"],
      ["Bonus", "5%"],
      ["Vault", "ERC-4626"],
    ],
    tags: [
      ["collateral strand", 16, 24],
      ["debt strand", 68, 66],
      ["HF 6.72", 28, 78],
    ],
    cta: { href: "/credit", label: "Open credit" },
    schematic: <HealthSchematic />,
    form: "Double helix",
    shape: 5,
    feature: "credit",
  },
  {
    key: "burn",
    label: "Buyback & burn",
    title: "Revenue in.\nAETH out.",
    body: "A share of every swap fee, curve fee and graduation fee flows to the buyback contract. A keeper sends the treasury share out, swaps the rest into AETH through the router and burns it on chain.",
    specs: [
      ["Protocol share", "20% of LP fees"],
      ["Treasury", "20%"],
      ["Burned", "80%"],
      ["Supply", "fixed, burn only"],
    ],
    tags: [
      ["revenue → core", 20, 20],
      ["AETH × burn", 60, 58],
      ["supply ↓", 24, 80],
    ],
    cta: { href: "/buyback", label: "See burns" },
    schematic: <BurnSchematic />,
    form: "Burn vortex",
    shape: 6,
    feature: "buyback",
  },
  {
    key: "build",
    label: "Developers",
    title: "Type-safe SDK.\nPublic REST API.",
    body: "Typed addresses and ABIs for every network, route and price helpers, and a public read-only REST API backed by the Aethra indexer. Everything the app does, you can build on.",
    specs: [
      ["Package", "@aethrafi/sdk"],
      ["API", "REST · JSON"],
      ["Indexer", "~1 min sync"],
      ["Contracts", "UUPS upgradeable"],
    ],
    tags: [
      ["knot(2,3)", 24, 20],
      ["GET /dashboard", 64, 64],
      ["200 OK", 20, 80],
    ],
    cta: { href: "/developers", label: "Developer docs" },
    schematic: <CodeSchematic />,
    form: "Torus knot",
    shape: 7,
  },
];

const SECTIONS = ALL_SECTIONS.filter((s) => !s.feature || FEATURES[s.feature]);
const SHAPES = SECTIONS.map((s) => s.shape);

const pad = (n: number) => String(n).padStart(2, "0");

/** Hero badge: where Aethra runs. */
function ChainBadge() {
  return (
    <span className="inline-flex items-center gap-2 border border-primary/40 bg-primary-soft px-2.5 py-1 text-primary-text [clip-path:polygon(0_0,calc(100%-7px)_0,100%_7px,100%_100%,7px_100%,0_calc(100%-7px))]">
      <StatusDot state="live" />
      On Robinhood Chain
    </span>
  );
}

/** Hero block for the launched AETH token: contract address with copy and an explorer link. Hidden until set. */
function TokenCA() {
  const [copied, setCopied] = React.useState(false);
  const ca = AETH_TOKEN.address;
  if (!ca) return null;
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(ca);
      setCopied(true);
      setTimeout(() => setCopied(false), 1600);
    } catch {
      /* clipboard blocked: the address is still selectable */
    }
  };
  const icon = "inline-flex size-7 shrink-0 items-center justify-center border text-fg-2 transition-ui hover:border-primary/60 hover:text-primary-text";
  return (
    <div className="flex max-w-xl items-center gap-3 border bg-bg/80 py-1.5 pl-3 pr-1.5">
      <span className="shrink-0 font-mono text-[11px] uppercase tracking-eyebrow text-primary-text">${AETH_TOKEN.symbol}</span>
      <span className="shrink-0 font-mono text-[10px] uppercase tracking-eyebrow text-muted">CA</span>
      <code className="min-w-0 flex-1 select-all truncate font-mono text-[12px] text-fg" title={ca}>
        {ca}
      </code>
      <button type="button" onClick={copy} aria-label={copied ? "Copied" : `Copy the ${AETH_TOKEN.symbol} contract address`} title={copied ? "Copied" : "Copy"} className={icon}>
        {copied ? <Check className="size-3.5 text-primary-text" /> : <Copy className="size-3.5" />}
      </button>
      <a href={`${AETH_TOKEN.explorer}/token/${ca}`} target="_blank" rel="noreferrer" aria-label={`${AETH_TOKEN.symbol} on the explorer`} title="Explorer" className={icon}>
        <ArrowUpRight className="size-3.5" />
      </a>
    </div>
  );
}

function LiveStats() {
  const d = useDashboard();
  const block = useBlockNumber({ chainId: CHAIN_ID, watch: true });
  const s = d.data?.stats;
  const cells: [string, string][] = [
    ["TVL", s ? formatUsd(s.tvl_usd, { compact: true }) : "—"],
    ["24h volume", s ? formatUsd(s.volume_24h_usd, { compact: true }) : "—"],
    ["Pools", s ? String(s.pools) : "—"],
    ["Block", block.data ? formatNumber(Number(block.data)) : "—"],
  ];
  return (
    <dl className="grid max-w-xl grid-cols-2 border sm:grid-cols-4">
      {cells.map(([k, v]) => (
        <div key={k} className="border-r bg-bg/80 px-3 py-2 last:border-r-0">
          <dt className="font-mono text-[10px] uppercase tracking-eyebrow text-muted">{k}</dt>
          <dd className="num mt-0.5 text-sm">{v}</dd>
        </div>
      ))}
    </dl>
  );
}

/** True once the element is meaningfully on screen; stays true so reveals play once per visit. */
function useInView<T extends Element>(threshold = 0.3) {
  const ref = React.useRef<T>(null);
  const [inView, setInView] = React.useState(false);
  React.useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const io = new IntersectionObserver(([e]) => setInView(Boolean(e?.isIntersecting)), { threshold });
    io.observe(el);
    return () => io.disconnect();
  }, [threshold]);
  return [ref, inView] as const;
}

/**
 * Soft entrance: rises, fades and sharpens in, staggered by `delay`. Leaving is quick and undelayed so the
 * next section never waits on the old one. Reduced motion shows everything at once.
 */
function Reveal({ active, delay = 0, blur = false, className, children }: { active: boolean; delay?: number; blur?: boolean; className?: string; children: React.ReactNode }) {
  return (
    <div
      className={cn(
        "transition-[opacity,transform,filter] motion-reduce:!transform-none motion-reduce:!opacity-100 motion-reduce:!blur-0 motion-reduce:transition-none",
        active ? "translate-y-0 opacity-100 blur-0" : cn("translate-y-8 opacity-0", blur && "blur-[10px]"),
        className,
      )}
      style={{
        transitionDuration: active ? "1300ms" : "300ms",
        transitionTimingFunction: "cubic-bezier(0.22, 1, 0.36, 1)",
        transitionDelay: active ? `${delay}ms` : "0ms",
      }}
    >
      {children}
    </div>
  );
}

function Panel({ s, i }: { s: Section; i: number }) {
  const venues = useOpenVenues();
  const cta = s.needs && !venues[s.needs] ? s.closedCta : s.cta;
  const Heading = i === 0 ? "h1" : "h2";
  const lines = s.title.split("\n");
  // long titles shrink so every line stays on one line in the text column (cqi = column width)
  const fit = 100 / (Math.max(...lines.map((l) => l.length)) * 0.5);
  // reveal as the section scrolls into view, so neighbours are never blank mid-scroll
  const [ref, active] = useInView<HTMLElement>(0.3);
  return (
    <section
      ref={ref}
      id={`section-${s.key}`}
      data-section={i}
      aria-label={`${i + 1} of ${SECTIONS.length}: ${s.label}`}
      className={cn("relative flex min-h-[calc(100dvh-var(--header-h))] scroll-mt-[var(--header-h)] items-center overflow-x-hidden lg:h-[calc(100dvh-var(--header-h))]", !active && "[&_*]:![animation-play-state:paused]")}
    >
      <div className="container grid h-full items-center gap-8 pb-20 pt-14 lg:grid-cols-[minmax(0,1fr)_minmax(0,1.15fr)] lg:pb-16 lg:pt-10">
        <div className="relative z-10 max-w-2xl space-y-6 [container-type:inline-size]">
          <Reveal active={active}>
            <p className="eyebrow flex flex-wrap items-center gap-x-3 gap-y-2">
              <span className="text-primary-text">{pad(i)}</span>
              <span className="h-px w-8 bg-border-strong" />
              {s.label}
              {i === 0 && <ChainBadge />}
            </p>
          </Reveal>
          <Heading className="font-semibold leading-[0.98] tracking-[-0.04em]" style={{ fontSize: `min(clamp(2.9rem, 6.6vw, 5.75rem), ${fit.toFixed(2)}cqi)` }}>
            {lines.map((line, n) => (
              <Reveal key={n} active={active} delay={90 + n * 110} blur>
                <span
                  className={cn(
                    "block",
                    n > 0 && "w-fit bg-gradient-to-r from-primary-text via-primary-text to-accent-text bg-clip-text pb-[0.08em] text-transparent dark:drop-shadow-[0_0_32px_rgb(var(--primary)/0.35)]",
                  )}
                >
                  {line}
                </span>
              </Reveal>
            ))}
          </Heading>
          <Reveal active={active} delay={330}>
            <p className="max-w-lg text-base text-fg-2 md:text-lg">{s.body}</p>
          </Reveal>

          {i === 0 ? (
            <>
              <Reveal active={active} delay={430}>
                <div className="flex flex-wrap gap-3">
                  <Button asChild size="lg" className="fx-cyber">
                    <Link href="/swap">
                      Launch app <ArrowRight />
                    </Link>
                  </Button>
                  <Button asChild size="lg" variant="secondary" className="fx-cyber">
                    <Link href="/pools">Explore pools</Link>
                  </Button>
                </div>
              </Reveal>
              {AETH_TOKEN.address && (
                <Reveal active={active} delay={480}>
                  <TokenCA />
                </Reveal>
              )}
              <Reveal active={active} delay={530}>
                <LiveStats />
              </Reveal>
            </>
          ) : (
            <>
              <Reveal active={active} delay={430}>
                <dl className="grid max-w-lg grid-cols-2 border-l border-t">
                  {s.specs.map(([k, v]) => (
                    <div key={k} className="border-b border-r bg-bg/75 px-3 py-2">
                      <dt className="font-mono text-[10px] uppercase tracking-eyebrow text-muted">{k}</dt>
                      <dd className="num mt-0.5 text-sm">{v}</dd>
                    </div>
                  ))}
                </dl>
              </Reveal>
              {cta && (
                <Reveal active={active} delay={530}>
                  {"soon" in cta ? (
                    <span className="inline-flex h-10 items-center border px-4 font-mono text-[12px] uppercase tracking-button text-muted">{cta.soon}</span>
                  ) : (
                    <Button asChild variant="secondary" className="fx-cyber">
                      <Link href={cta.href}>
                        {cta.label} <ArrowRight />
                      </Link>
                    </Button>
                  )}
                </Reveal>
              )}
            </>
          )}
        </div>

        {/* right half: the ribbon renders behind; these are its annotations */}
        <div className="pointer-events-none relative hidden h-full lg:block">
          {s.tags.map(([text, left, top], t) => (
            <DataTag key={text} text={text} left={left} top={top} delay={t * 120} active={active} />
          ))}
          {s.schematic && (
            <div className={cn("pointer-events-auto absolute bottom-6 right-0 transition-opacity duration-700", active ? "opacity-100" : "opacity-0")}>
              {s.schematic}
            </div>
          )}
          <span className="absolute left-0 top-6 font-mono text-[10px] uppercase tracking-eyebrow text-muted">
            FORM {pad(i)} · {s.form}
          </span>
        </div>
      </div>
    </section>
  );
}

/** A label pinned near the ribbon with a leader line and a node marker. */
function DataTag({ text, left, top, delay, active }: { text: string; left: number; top: number; delay: number; active: boolean }) {
  return (
    <div
      className={cn("absolute flex items-center gap-2 transition-all duration-700 ease-out", active ? "opacity-100" : "translate-x-2 opacity-0")}
      style={{ left: `${left}%`, top: `${top}%`, transitionDelay: `${delay}ms` }}
    >
      <span className="relative flex size-2.5 items-center justify-center">
        <span className="absolute size-2.5 animate-ping rounded-full bg-primary/40" />
        <span className="size-1.5 rounded-full bg-primary" />
      </span>
      <span className="h-px w-10 bg-gradient-to-r from-primary/70 to-transparent" />
      <span className="border border-border-strong bg-bg/85 px-2 py-0.5 font-mono text-[10px] uppercase tracking-button text-fg-2">{text}</span>
    </div>
  );
}

/** Header height (h-14 + 1px border); sections fill the viewport below the sticky header. */
const HEADER_H = 57;

const easeInOutCubic = (t: number) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);

export function LandingSections() {
  const rootRef = React.useRef<HTMLDivElement>(null);
  const sectionRef = React.useRef(0);
  const [active, setActive] = React.useState(0);
  const coordRef = React.useRef<HTMLSpanElement>(null);
  const morphRef = React.useRef<HTMLSpanElement>(null);
  const crossRef = React.useRef<HTMLDivElement>(null);
  const progressRef = React.useRef<HTMLDivElement>(null);
  const n = SECTIONS.length;

  // One gesture, one section. On desktop a wheel flick, a key press or a nav click flies to the neighbouring
  // section along an eased rAF tween (native `behavior: "smooth"` has no fixed duration or curve, so it can't be
  // tuned). While a flight runs, wheel events are swallowed; trackpad inertia keeps streaming after the flick, so
  // a new wheel gesture only counts after a pause or when it is clearly stronger than the tail before it.
  // Elsewhere (touch, narrow screens, scrollbar drags) scrolling stays native and a settle pulls a nearby edge in.
  const flightRef = React.useRef<{ raf: number; index: number } | null>(null);

  const cancelFlight = React.useCallback(() => {
    if (flightRef.current) cancelAnimationFrame(flightRef.current.raf);
    flightRef.current = null;
  }, []);

  const goTo = React.useCallback(
    (i: number) => {
      const index = Math.max(0, Math.min(n - 1, i));
      const el = rootRef.current?.querySelector<HTMLElement>(`[data-section="${index}"]`);
      if (!el) return;
      cancelFlight();
      const from = window.scrollY;
      const to = Math.round(el.getBoundingClientRect().top + from - HEADER_H);
      const dist = Math.abs(to - from);
      if (dist < 1) return;
      if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
        window.scrollTo({ top: to, behavior: "instant" });
        return;
      }
      const duration = Math.min(1300, 750 + (dist / window.innerHeight) * 140);
      const t0 = performance.now();
      const flight = { raf: 0, index };
      const tick = (now: number) => {
        const p = Math.max(0, Math.min(1, (now - t0) / duration));
        window.scrollTo({ top: from + (to - from) * easeInOutCubic(p), behavior: "instant" });
        if (p < 1) flight.raf = requestAnimationFrame(tick);
        else flightRef.current = null;
      };
      flightRef.current = flight;
      flight.raf = requestAnimationFrame(tick);
    },
    [n, cancelFlight],
  );

  React.useEffect(() => {
    const paged = window.matchMedia("(min-width: 1024px)");
    const nearest = () => {
      let idx = 0;
      let best = Infinity;
      rootRef.current?.querySelectorAll<HTMLElement>("[data-section]").forEach((el, i) => {
        const d = Math.abs(el.getBoundingClientRect().top - HEADER_H);
        if (d < best) {
          best = d;
          idx = i;
        }
      });
      return idx;
    };
    const current = () => flightRef.current?.index ?? nearest();

    let lastWheel = 0;
    let lastAbs = 0;
    const onWheel = (e: WheelEvent) => {
      if (!paged.matches || e.ctrlKey || e.metaKey) return; // ctrl + wheel is pinch zoom
      if (Math.abs(e.deltaX) > Math.abs(e.deltaY)) return;
      e.preventDefault();
      const now = performance.now();
      const abs = Math.abs(e.deltaY) * (e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? window.innerHeight : 1);
      const gap = now - lastWheel;
      const prev = lastAbs;
      lastWheel = now;
      lastAbs = abs;
      if (flightRef.current) return;
      if ((gap >= 90 && abs >= 3) || (abs >= 20 && abs > prev * 1.4)) goTo(current() + Math.sign(e.deltaY));
    };

    const onKey = (e: KeyboardEvent) => {
      if (!paged.matches || e.defaultPrevented || e.altKey || e.ctrlKey || e.metaKey) return;
      const t = e.target as HTMLElement | null;
      if (t?.closest("input, textarea, select, [contenteditable='true']")) return;
      let to: number | null = null;
      if (e.key === "ArrowDown" || e.key === "PageDown") to = current() + 1;
      else if (e.key === "ArrowUp" || e.key === "PageUp") to = current() - 1;
      else if (e.key === " " && !t?.closest("a, button, summary")) to = current() + (e.shiftKey ? -1 : 1);
      else if (e.key === "Home") to = 0;
      else if (e.key === "End") to = n - 1;
      if (to === null) return;
      e.preventDefault();
      if (!e.repeat) goTo(to);
    };

    // settle: once scrolling has fully stopped (scrollbar drag, touch momentum, narrow screens) a section edge
    // within a quarter of the viewport pulls the page onto it
    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    let timer = 0;
    let touching = false;
    let lastY = -1;
    const settle = () => {
      if (touching || flightRef.current) return;
      // only act once the position has stopped moving; on a janky frame scroll events can be >160ms apart
      if (window.scrollY !== lastY) {
        lastY = window.scrollY;
        timer = window.setTimeout(settle, 120);
        return;
      }
      const els = rootRef.current?.querySelectorAll<HTMLElement>("[data-section]");
      if (!els?.length) return;
      let best = Infinity;
      let idx = 0;
      els.forEach((el, i) => {
        const d = el.getBoundingClientRect().top - HEADER_H;
        if (Math.abs(d) < Math.abs(best)) {
          best = d;
          idx = i;
        }
      });
      const reach = (window.innerHeight - HEADER_H) * 0.25;
      if (Math.abs(best) > 2 && Math.abs(best) < reach) goTo(idx);
    };
    const schedule = () => {
      window.clearTimeout(timer);
      lastY = -1;
      if (!reduced) timer = window.setTimeout(settle, 160);
    };
    const down = () => {
      touching = true;
      cancelFlight(); // grabbing the scrollbar or the screen hands control back to the user
      window.clearTimeout(timer);
    };
    const up = () => {
      touching = false;
      schedule();
    };
    const inputs: [string, (e: never) => void, boolean][] = [
      ["wheel", onWheel, false],
      ["keydown", onKey, false],
      ["scroll", schedule, true],
      ["touchstart", down, true],
      ["touchend", up, true],
      ["pointerdown", down, true], // dragging the scrollbar
      ["pointerup", up, true],
    ];
    for (const [ev, fn, passive] of inputs) window.addEventListener(ev, fn as EventListener, { passive });
    return () => {
      window.clearTimeout(timer);
      cancelFlight();
      for (const [ev, fn] of inputs) window.removeEventListener(ev, fn as EventListener);
    };
  }, [n, goTo, cancelFlight]);

  // scroll position → continuous section index (ribbon morph), active section, progress rail
  React.useEffect(() => {
    let raf = 0;
    const measure = () => {
      raf = 0;
      const els = rootRef.current?.querySelectorAll<HTMLElement>("[data-section]");
      if (!els?.length) return;
      // a section counts as "reached" when its top meets the bottom edge of the sticky header
      let pos = 0;
      els.forEach((el, i) => {
        const r = el.getBoundingClientRect();
        const top = r.top - HEADER_H;
        if (top <= 0) pos = i + Math.min(1, -top / Math.max(1, r.height));
      });
      pos = Math.min(n - 1, pos);
      sectionRef.current = pos;
      setActive((a) => (Math.round(pos) === a ? a : Math.round(pos)));
      if (progressRef.current) progressRef.current.style.transform = `scaleY(${pos / (n - 1)})`;
    };
    const onScroll = () => {
      if (!raf) raf = requestAnimationFrame(measure);
    };
    measure();
    window.addEventListener("scroll", onScroll, { passive: true });
    window.addEventListener("resize", onScroll);
    return () => {
      cancelAnimationFrame(raf);
      window.removeEventListener("scroll", onScroll);
      window.removeEventListener("resize", onScroll);
    };
  }, [n]);

  // crosshair follows the pointer
  React.useEffect(() => {
    const onMove = (e: PointerEvent) => {
      const c = crossRef.current;
      if (!c) return;
      c.style.setProperty("--x", `${e.clientX}px`);
      c.style.setProperty("--y", `${e.clientY}px`);
      c.style.opacity = e.pointerType === "mouse" ? "1" : "0";
    };
    window.addEventListener("pointermove", onMove, { passive: true });
    return () => window.removeEventListener("pointermove", onMove);
  }, []);

  const onFrame = React.useCallback((f: RibbonFrame) => {
    if (coordRef.current) {
      coordRef.current.textContent = f.active ? `X ${f.x.toFixed(3)}  Y ${f.y.toFixed(3)}  Z ${(Math.sin(f.x + f.y) * 0.8).toFixed(3)}` : "X —  Y —  Z —";
    }
    if (morphRef.current) {
      const a = Math.floor(f.section);
      const k = f.section - a;
      morphRef.current.textContent = k < 0.01 ? `FORM ${pad(a)} · STABLE` : `MORPH ${pad(a)}→${pad(Math.min(n - 1, a + 1))} · ${Math.round(k * 100)}%`;
    }
  }, [n]);

  const s = SECTIONS[active]!;
  return (
    <div ref={rootRef} className="relative [--header-h:57px]" aria-label="Aethra Fi overview">
      {/* fixed backdrop: blueprint grid + ribbon, below the sticky header */}
      <div className="pointer-events-none fixed inset-x-0 bottom-0 top-[var(--header-h)] bg-[linear-gradient(rgb(var(--border)/0.35)_1px,transparent_1px),linear-gradient(90deg,rgb(var(--border)/0.35)_1px,transparent_1px)] bg-[size:48px_48px] [mask-image:radial-gradient(ellipse_at_70%_50%,black,transparent_75%)]" />
      <GlyphRibbon sectionRef={sectionRef} shapes={SHAPES} onFrame={onFrame} className="pointer-events-none fixed inset-x-0 bottom-0 top-[var(--header-h)]" />

      {/* sections */}
      <div className="relative z-10">
        {SECTIONS.map((sec, i) => (
          <Panel key={sec.key} s={sec} i={i} />
        ))}
      </div>

      {/* HUD: crosshair, frame, progress rail, readouts */}
      <div className="pointer-events-none fixed inset-x-0 bottom-0 top-[var(--header-h)] z-20">
        <div ref={crossRef} className="fixed inset-0 opacity-0 transition-opacity duration-300 [--x:-100px] [--y:-100px]">
          <span className="absolute left-0 right-0 h-px bg-primary/15" style={{ top: "var(--y)" }} />
          <span className="absolute bottom-0 top-0 w-px bg-primary/15" style={{ left: "var(--x)" }} />
          <span className="absolute size-5 -translate-x-1/2 -translate-y-1/2 border border-primary/50" style={{ left: "var(--x)", top: "var(--y)" }} />
        </div>

        {/* corner brackets */}
        {["left-3 top-3 border-l border-t", "right-3 top-3 border-r border-t", "bottom-14 left-3 border-b border-l", "bottom-14 right-3 border-b border-r"].map((c) => (
          <span key={c} className={cn("absolute size-4 border-border-strong", c)} />
        ))}

        {/* right rail: vertical ruler with progress, and section stops */}
        <div className="absolute bottom-16 right-3 top-10 hidden w-3 md:block">
          <div className="flex h-full flex-col items-end justify-between">
            {Array.from({ length: 57 }, (_, t) => (
              <span key={t} className={cn("h-px bg-border-strong", t % 8 === 0 ? "w-3" : t % 4 === 0 ? "w-2" : "w-1")} />
            ))}
          </div>
          <div ref={progressRef} className="absolute right-0 top-0 h-full w-px origin-top bg-primary" style={{ transform: "scaleY(0)" }} />
        </div>
        <nav aria-label="Sections" className="pointer-events-auto absolute right-8 top-1/2 hidden -translate-y-1/2 flex-col items-end gap-1 md:flex">
          {SECTIONS.map((sec, i) => (
            <button key={sec.key} onClick={() => goTo(i)} aria-label={`Go to ${sec.label}`} aria-current={i === active ? "step" : undefined} className="group flex items-center gap-2 py-1">
              <span className={cn("bg-bg/75 px-1 font-mono text-[10px] uppercase tracking-eyebrow transition-opacity duration-300", i === active ? "text-primary-text opacity-100" : "text-muted opacity-0 group-hover:opacity-100")}>
                {pad(i)} {sec.label}
              </span>
              <span className={cn("w-0.5 transition-all duration-500", i === active ? "h-6 bg-primary" : "h-2.5 bg-border-strong group-hover:bg-fg-2")} />
            </button>
          ))}
        </nav>

        {/* left rail */}
        <p className="absolute left-4 top-1/2 hidden -translate-y-1/2 rotate-180 font-mono text-[10px] uppercase tracking-eyebrow text-muted [writing-mode:vertical-rl] xl:block">
          Aethra · glyph ribbon v1 · 5,280 glyphs · {CHAIN.name}
        </p>

        {/* bottom bar */}
        <div className="pointer-events-auto absolute inset-x-0 bottom-0 border-t bg-bg/90">
          <div className="container flex h-12 items-center gap-4 font-mono text-[11px] uppercase tracking-button">
            <span className="flex min-w-0 items-center gap-2 text-muted">
              <StatusDot state="live" />
              <span className="text-fg">{pad(active)}</span>/<span>{pad(n - 1)}</span>
              <span className="hidden truncate sm:inline">· {s.label}</span>
            </span>
            <span ref={morphRef} className="hidden text-muted lg:inline" />
            <span ref={coordRef} className="ml-auto hidden text-muted xl:inline" />
            <div className="ml-auto flex items-center gap-1 xl:ml-4">
              <span className="mr-3 hidden normal-case text-muted sm:inline">{APP_VERSION}</span>
              <Button variant="ghost" size="icon-sm" className="fx-cyber" aria-label="Previous section" disabled={active === 0} onClick={() => goTo(active - 1)}>
                <ArrowUp />
              </Button>
              <Button variant="ghost" size="icon-sm" className="fx-cyber" aria-label="Next section" disabled={active === n - 1} onClick={() => goTo(active + 1)}>
                <ArrowDown />
              </Button>
            </div>
          </div>
        </div>

        {/* scroll hint on the first section */}
        <div className={cn("absolute bottom-16 left-1/2 hidden -translate-x-1/2 flex-col items-center gap-2 font-mono text-[10px] uppercase tracking-eyebrow text-muted transition-opacity duration-500 md:flex", active === 0 ? "opacity-100" : "opacity-0")}>
          scroll
          <span className="h-8 w-px animate-pulse bg-gradient-to-b from-primary to-transparent" />
        </div>
      </div>
    </div>
  );
}
