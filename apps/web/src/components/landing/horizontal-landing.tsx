"use client";

import * as React from "react";
import dynamic from "next/dynamic";
import Link from "next/link";
import { ArrowLeft, ArrowRight } from "lucide-react";
import { useBlockNumber } from "wagmi";
import { Button } from "@/components/ui/button";
import { StatusDot } from "@/components/kit";
import { useDashboard } from "@/hooks/use-api";
import { formatNumber, formatUsd } from "@/lib/format";
import { CHAIN, CHAIN_ID } from "@/lib/network";
import { cn } from "@/lib/utils";
import type { RibbonFrame } from "./glyph-ribbon";
import { ScrambleText } from "./scramble-text";
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
}

const SECTIONS: Section[] = [
  {
    key: "hero",
    label: "Liquidity layer",
    title: "Every venue.\nOne route.",
    body: "Aethra routes each trade across hook pools, bins, ranges and launch curves on Robinhood Chain, with fees that follow volatility and stock pools that follow their oracle.",
    specs: [],
    tags: [
      ["MÖBIUS · 1 SURFACE", 24, 18],
      ["∞ PATHS", 72, 70],
      ["5,280 GLYPHS", 12, 78],
    ],
    form: "Möbius loop",
  },
  {
    key: "router",
    label: "Smart router",
    title: "Four venues.\nOne quote.",
    body: "The router quotes v4 hook pools, DLMM bins, DAMM ranges and launch curves over eth_call, compares direct and two-hop paths, and settles the winner in a single transaction.",
    specs: [
      ["Venues", "4"],
      ["Max hops", "3"],
      ["Quote", "eth_call"],
      ["ETH in/out", "auto wrap"],
    ],
    tags: [
      ["hop[0] V4 → aUSD", 20, 22],
      ["hop[1] DLMM → TSLA", 68, 64],
      ["Δout +0.42%", 28, 74],
    ],
    cta: { href: "/swap", label: "Open swap" },
    schematic: <RouterSchematic />,
    form: "Figure-eight route",
  },
  {
    key: "fees",
    label: "Dynamic fees · oracle guard",
    title: "Fees that\nbreathe.",
    body: "One v4 hook prices every pool. Fees widen as volatility rises and decay as it settles. Stock pools read a reference feed: trades toward the oracle pay the base fee, trades away pay more, and a breaker halts the pool if the gap or the feed goes wrong.",
    specs: [
      ["Base fee", "0.30%"],
      ["Ceiling", "10%"],
      ["Decay", "600 s"],
      ["Stock guard", "oracle + breaker"],
    ],
    tags: [
      ["σ 1h ↑ → fee 1.6%", 20, 20],
      ["oracle Δ 42 bps", 64, 68],
      ["breaker ARMED", 16, 80],
    ],
    cta: { href: "/pools?filter=stock", label: "Stock pools" },
    schematic: <FeeSchematic />,
    form: "Volatility wave",
  },
  {
    key: "bins",
    label: "DLMM · limit orders",
    title: "Liquidity,\nbin by bin.",
    body: "Discrete price bins with zero slippage inside each bin. Shape a deposit as spot, curve or bid-ask, or park a limit order in a single bin that fills as price crosses it. Keepers claim filled orders for you.",
    specs: [
      ["Bin steps", "1 · 5 · 10 · 25 · 50 · 100 bps"],
      ["Shapes", "spot · curve · bid-ask"],
      ["Orders", "single bin"],
      ["Claims", "owner or keeper"],
    ],
    tags: [
      ["active bin −7949", 26, 18],
      ["token1 ◀", 8, 70],
      ["▶ token0", 72, 70],
    ],
    cta: { href: "/orders", label: "Place an order" },
    schematic: <BinsSchematic />,
    form: "Bin histogram",
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
  },
  {
    key: "build",
    label: "Build",
    title: "Typed SDK.\nOpen API.",
    body: "Addresses and ABIs for every network, route and price helpers, and a public read-only REST API from the indexer. Everything the app does, you can do too.",
    specs: [
      ["Package", "@aethra/sdk"],
      ["API", "REST · { data }"],
      ["Indexer", "every minute"],
      ["Contracts", "UUPS proxies"],
    ],
    tags: [
      ["knot(2,3)", 24, 20],
      ["GET /dashboard", 64, 64],
      ["200 OK", 20, 80],
    ],
    cta: { href: "/developers", label: "Developer docs" },
    schematic: <CodeSchematic />,
    form: "Torus knot",
  },
];

const pad = (n: number) => String(n).padStart(2, "0");

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
        <div key={k} className="border-r bg-bg/60 px-3 py-2 backdrop-blur-sm last:border-r-0">
          <dt className="font-mono text-[10px] uppercase tracking-eyebrow text-muted">{k}</dt>
          <dd className="num mt-0.5 text-sm">{v}</dd>
        </div>
      ))}
    </dl>
  );
}

function Panel({ s, i, active }: { s: Section; i: number; active: boolean }) {
  const Heading = i === 0 ? "h1" : "h2";
  return (
    <section
      aria-roledescription="slide"
      aria-label={`${i + 1} of ${SECTIONS.length}: ${s.label}`}
      className="relative h-full w-full shrink-0 snap-start snap-always overflow-y-auto overflow-x-hidden"
    >
      <div className="container grid h-full items-center gap-8 py-16 lg:grid-cols-[minmax(0,1fr)_minmax(0,1.15fr)] lg:py-10">
        <div className={cn("relative z-10 max-w-xl space-y-6 transition-[opacity,transform] duration-700 ease-out", active ? "opacity-100" : "opacity-0 lg:translate-y-3")}>
          <p className="eyebrow flex items-center gap-3">
            <span className="text-primary-text">{pad(i)}</span>
            <span className="h-px w-8 bg-border-strong" />
            {s.label}
          </p>
          <Heading className="whitespace-pre-line text-[clamp(2.4rem,5.2vw,4.4rem)] font-medium leading-[1.02] tracking-[-0.03em]">
            <ScrambleText text={s.title} active={active} />
          </Heading>
          <p className="max-w-lg text-base text-fg-2 md:text-lg">{s.body}</p>

          {i === 0 ? (
            <>
              <div className="flex flex-wrap gap-3">
                <Button asChild size="lg">
                  <Link href="/swap">
                    Launch app <ArrowRight />
                  </Link>
                </Button>
                <Button asChild size="lg" variant="secondary">
                  <Link href="/pools">Explore pools</Link>
                </Button>
              </div>
              <LiveStats />
            </>
          ) : (
            <>
              <dl className="grid max-w-lg grid-cols-2 border-l border-t">
                {s.specs.map(([k, v]) => (
                  <div key={k} className="border-b border-r bg-bg/50 px-3 py-2 backdrop-blur-sm">
                    <dt className="font-mono text-[10px] uppercase tracking-eyebrow text-muted">{k}</dt>
                    <dd className="num mt-0.5 text-sm">{v}</dd>
                  </div>
                ))}
              </dl>
              {s.cta && (
                <Button asChild variant="secondary">
                  <Link href={s.cta.href}>
                    {s.cta.label} <ArrowRight />
                  </Link>
                </Button>
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
      <span className="border border-border-strong bg-bg/70 px-2 py-0.5 font-mono text-[10px] uppercase tracking-button text-fg-2 backdrop-blur-sm">{text}</span>
    </div>
  );
}

export function HorizontalLanding() {
  const scrollerRef = React.useRef<HTMLDivElement>(null);
  const sectionRef = React.useRef(0);
  const [active, setActive] = React.useState(0);
  const coordRef = React.useRef<HTMLSpanElement>(null);
  const morphRef = React.useRef<HTMLSpanElement>(null);
  const crossRef = React.useRef<HTMLDivElement>(null);
  const progressRef = React.useRef<HTMLDivElement>(null);
  const lockRef = React.useRef(0);
  const n = SECTIONS.length;

  const goTo = React.useCallback((i: number) => {
    const el = scrollerRef.current;
    if (!el) return;
    const idx = Math.max(0, Math.min(n - 1, i));
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    el.scrollTo({ left: idx * el.clientWidth, behavior: reduce ? "auto" : "smooth" });
  }, [n]);

  // scroll position → section float (ribbon), active index (UI), progress bar
  React.useEffect(() => {
    const el = scrollerRef.current;
    if (!el) return;
    const onScroll = () => {
      const pos = el.scrollLeft / Math.max(1, el.clientWidth);
      sectionRef.current = pos;
      setActive((a) => (Math.round(pos) === a ? a : Math.round(pos)));
      if (progressRef.current) progressRef.current.style.transform = `scaleX(${pos / (n - 1)})`;
    };
    onScroll();
    el.addEventListener("scroll", onScroll, { passive: true });
    return () => el.removeEventListener("scroll", onScroll);
  }, [n]);

  // vertical wheel → one section per gesture; native horizontal trackpad scrolling still works
  React.useEffect(() => {
    const el = scrollerRef.current;
    if (!el) return;
    const onWheel = (e: WheelEvent) => {
      if (Math.abs(e.deltaY) <= Math.abs(e.deltaX)) return;
      const panel = (e.target as HTMLElement).closest("section");
      if (panel && panel.scrollHeight > panel.clientHeight + 4) {
        // let a tall panel (small screens) scroll vertically until its edge
        const atTop = panel.scrollTop <= 0 && e.deltaY < 0;
        const atBottom = panel.scrollTop + panel.clientHeight >= panel.scrollHeight - 2 && e.deltaY > 0;
        if (!atTop && !atBottom) return;
      }
      e.preventDefault();
      const now = performance.now();
      if (now < lockRef.current || Math.abs(e.deltaY) < 4) return;
      lockRef.current = now + 750;
      goTo(Math.round(el.scrollLeft / el.clientWidth) + (e.deltaY > 0 ? 1 : -1));
    };
    el.addEventListener("wheel", onWheel, { passive: false });
    return () => el.removeEventListener("wheel", onWheel);
  }, [goTo]);

  // keyboard
  React.useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.target as HTMLElement).closest("input, textarea, select, [contenteditable]")) return;
      const cur = Math.round(sectionRef.current);
      if (["ArrowRight", "PageDown"].includes(e.key) || (e.key === " " && !e.shiftKey)) goTo(cur + 1);
      else if (["ArrowLeft", "PageUp"].includes(e.key) || (e.key === " " && e.shiftKey)) goTo(cur - 1);
      else if (e.key === "Home") goTo(0);
      else if (e.key === "End") goTo(n - 1);
      else return;
      e.preventDefault();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [goTo, n]);

  // mouse drag to scrub sideways (touch uses native scrolling)
  React.useEffect(() => {
    const el = scrollerRef.current;
    if (!el) return;
    let startX = 0;
    let startLeft = 0;
    let dragging = false;
    let moved = false;
    const down = (e: PointerEvent) => {
      if (e.pointerType !== "mouse" || e.button !== 0 || (e.target as HTMLElement).closest("a, button, input, select, textarea")) return;
      dragging = true;
      moved = false;
      startX = e.clientX;
      startLeft = el.scrollLeft;
    };
    const move = (e: PointerEvent) => {
      if (!dragging) return;
      const dx = e.clientX - startX;
      if (!moved && Math.abs(dx) < 6) return;
      if (!moved) el.classList.add("is-dragging");
      moved = true;
      el.scrollLeft = startLeft - dx;
    };
    const up = () => {
      if (!dragging) return;
      dragging = false;
      if (!moved) return;
      el.classList.remove("is-dragging");
      const delta = (el.scrollLeft - startLeft) / el.clientWidth;
      const base = Math.round(startLeft / el.clientWidth);
      goTo(Math.abs(delta) > 0.12 ? base + Math.sign(delta) : base);
    };
    el.addEventListener("pointerdown", down);
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
    return () => {
      el.removeEventListener("pointerdown", down);
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
    };
  }, [goTo]);

  // crosshair follows the pointer
  React.useEffect(() => {
    const onMove = (e: PointerEvent) => {
      const c = crossRef.current;
      if (!c) return;
      const r = c.parentElement!.getBoundingClientRect();
      c.style.setProperty("--x", `${e.clientX - r.left}px`);
      c.style.setProperty("--y", `${e.clientY - r.top}px`);
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
    <div className="relative h-[calc(100dvh-3.5rem-1px)] overflow-hidden" role="region" aria-roledescription="carousel" aria-label="Aethra Fi overview">
      {/* backdrop: blueprint grid + ribbon */}
      <div className="pointer-events-none absolute inset-0 bg-[linear-gradient(rgb(var(--border)/0.35)_1px,transparent_1px),linear-gradient(90deg,rgb(var(--border)/0.35)_1px,transparent_1px)] bg-[size:48px_48px] [mask-image:radial-gradient(ellipse_at_70%_50%,black,transparent_75%)]" />
      <GlyphRibbon sectionRef={sectionRef} onFrame={onFrame} className="pointer-events-none absolute inset-0" />

      {/* panels */}
      <div
        ref={scrollerRef}
        tabIndex={-1}
        className="relative z-10 flex h-full snap-x snap-mandatory overflow-x-auto overflow-y-hidden overscroll-x-contain [scrollbar-width:none] [&.is-dragging]:cursor-grabbing [&.is-dragging]:snap-none [&.is-dragging]:select-none [&::-webkit-scrollbar]:hidden"
      >
        {SECTIONS.map((sec, i) => (
          <Panel key={sec.key} s={sec} i={i} active={i === active} />
        ))}
      </div>

      {/* HUD: crosshair, frame, rulers, readouts */}
      <div className="pointer-events-none absolute inset-0 z-20">
        <div ref={crossRef} className="absolute inset-0 opacity-0 transition-opacity duration-300 [--x:-100px] [--y:-100px]">
          <span className="absolute left-0 right-0 h-px bg-primary/15" style={{ top: "var(--y)" }} />
          <span className="absolute bottom-0 top-0 w-px bg-primary/15" style={{ left: "var(--x)" }} />
          <span className="absolute size-5 -translate-x-1/2 -translate-y-1/2 border border-primary/50" style={{ left: "var(--x)", top: "var(--y)" }} />
        </div>

        {/* corner brackets */}
        {["left-3 top-3 border-l border-t", "right-3 top-3 border-r border-t", "bottom-3 left-3 border-b border-l", "bottom-3 right-3 border-b border-r"].map((c) => (
          <span key={c} className={cn("absolute size-4 border-border-strong", c)} />
        ))}

        {/* top ruler */}
        <div className="absolute inset-x-8 top-3 hidden h-3 md:block">
          <div className="flex h-full items-start justify-between">
            {Array.from({ length: 81 }, (_, t) => (
              <span key={t} className={cn("w-px bg-border-strong", t % 10 === 0 ? "h-3" : t % 5 === 0 ? "h-2" : "h-1")} />
            ))}
          </div>
          <div ref={progressRef} className="absolute left-0 top-0 h-px w-full origin-left bg-primary" style={{ transform: "scaleX(0)" }} />
        </div>

        {/* side rail */}
        <p className="absolute right-4 top-1/2 hidden -translate-y-1/2 font-mono text-[10px] uppercase tracking-eyebrow text-muted [writing-mode:vertical-rl] xl:block">
          Aethra · glyph ribbon v1 · 5,280 glyphs · {CHAIN.name}
        </p>

        {/* bottom bar */}
        <div className="pointer-events-auto absolute inset-x-0 bottom-0 border-t bg-bg/75 backdrop-blur-md">
          <div className="container flex h-12 items-center gap-4 font-mono text-[11px] uppercase tracking-button">
            <span className="flex min-w-0 items-center gap-2 text-muted">
              <StatusDot state="live" />
              <span className="text-fg">{pad(active)}</span>/<span>{pad(n - 1)}</span>
              <span className="hidden truncate sm:inline">· {s.label}</span>
            </span>
            <span ref={morphRef} className="hidden text-muted lg:inline" />
            <span ref={coordRef} className="ml-auto hidden text-muted xl:inline" />
            <div className="ml-auto flex items-center gap-1 xl:ml-4">
              {SECTIONS.map((sec, i) => (
                <button
                  key={sec.key}
                  onClick={() => goTo(i)}
                  aria-label={`Go to ${sec.label}`}
                  aria-current={i === active ? "step" : undefined}
                  className="group flex h-8 items-center px-0.5"
                >
                  <span className={cn("h-0.5 transition-all duration-500", i === active ? "w-8 bg-primary" : "w-3 bg-border-strong group-hover:bg-fg-2")} />
                </button>
              ))}
            </div>
            <div className="flex gap-1">
              <Button variant="ghost" size="icon-sm" aria-label="Previous section" disabled={active === 0} onClick={() => goTo(active - 1)}>
                <ArrowLeft />
              </Button>
              <Button variant="ghost" size="icon-sm" aria-label="Next section" disabled={active === n - 1} onClick={() => goTo(active + 1)}>
                <ArrowRight />
              </Button>
            </div>
          </div>
        </div>

        {/* scroll hint on the first section */}
        <div className={cn("absolute bottom-16 right-8 hidden items-center gap-3 font-mono text-[10px] uppercase tracking-eyebrow text-muted transition-opacity duration-500 md:flex", active === 0 ? "opacity-100" : "opacity-0")}>
          <span className="h-px w-10 animate-pulse bg-primary" />
          scroll · drag · ← →
        </div>
      </div>
    </div>
  );
}
