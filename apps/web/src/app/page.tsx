import Link from "next/link";
import { ArrowRight } from "lucide-react";
import { Button } from "@/components/ui/button";
import { HeroField } from "@/components/landing/hero-field";
import { Ticker } from "@/components/landing/ticker";

const VENUES = [
  {
    tag: "V4 HOOK",
    title: "Hook pools",
    body: "Uniswap v4 pools behind one Aethra hook. Fees widen when prices move fast and settle back when they calm down.",
  },
  {
    tag: "DLMM",
    title: "Discrete bins",
    body: "Liquidity in fixed price bins with zero slippage inside a bin. Shape it as spot, curve or bid-ask, or place a limit order in one bin.",
  },
  {
    tag: "DAMM",
    title: "Single range",
    body: "One concentrated range per pool with fungible shares. Optional launch fee that decays over the first hours of trading.",
  },
  {
    tag: "LAUNCH",
    title: "Launch markets",
    body: "Fair bonding curves priced in WETH. A sold-out curve graduates into a v4 hook pool with permanently locked liquidity.",
  },
];

const FEATURES = [
  {
    n: "02",
    eyebrow: "Stock tokens",
    title: "Oracle-guarded stock pools",
    body: "Pools with tokenized equities read a reference price feed. Trades that pull the pool toward the reference pay the base fee, trades that push it away pay more, and a circuit breaker halts swaps when the gap is too wide or the feed goes stale.",
    href: "/pools?filter=stock",
    cta: "Stock pools",
  },
  {
    n: "03",
    eyebrow: "Credit",
    title: "Borrow against your LP position",
    body: "Pledge a position NFT, borrow the vault stablecoin, and keep earning fees. Fees can pay the loan down automatically. Lenders earn a utilization-based rate in an ERC-4626 vault.",
    href: "/credit",
    cta: "Open credit",
  },
  {
    n: "04",
    eyebrow: "Revenue",
    title: "Buyback and burn",
    body: "A share of every swap fee, launch fee and graduation fee flows to the buyback contract. A keeper swaps it into AETH and burns it on chain.",
    href: "/buyback",
    cta: "See burns",
  },
];

export default function Home() {
  return (
    <>
      <section className="relative overflow-hidden">
        <HeroField className="absolute inset-0 size-full" />
        <div className="container relative flex min-h-[78vh] flex-col justify-center py-24">
          <p className="eyebrow mb-6 animate-rise">01 / Liquidity layer</p>
          <h1 className="max-w-4xl animate-rise text-display font-medium [animation-delay:60ms]">
            Every venue.
            <br />
            <span className="text-primary-text">One route.</span>
          </h1>
          <p className="mt-6 max-w-xl animate-rise text-lg text-fg-2 [animation-delay:120ms]">
            Aethra routes each trade across hook pools, bins, ranges and launch curves on Robinhood Chain, with fees
            that follow volatility and stock pools that follow their oracle.
          </p>
          <div className="mt-10 flex animate-rise flex-wrap gap-3 [animation-delay:180ms]">
            <Button asChild size="lg">
              <Link href="/swap">
                Launch app <ArrowRight />
              </Link>
            </Button>
            <Button asChild size="lg" variant="secondary">
              <Link href="/pools">Explore pools</Link>
            </Button>
          </div>
        </div>
      </section>

      <Ticker />

      <section className="container py-24 md:py-32">
        <div className="mb-12 max-w-2xl space-y-3">
          <p className="eyebrow">01 / Venues</p>
          <h2 className="text-3xl font-medium tracking-tight md:text-4xl">Four ways to hold liquidity. One router reads them all.</h2>
          <p className="text-fg-2">The smart router quotes every venue over eth_call and picks the best path, up to three hops.</p>
        </div>
        <div className="hairline-grid grid border md:grid-cols-2 lg:grid-cols-4">
          {VENUES.map((v) => (
            <div key={v.tag} className="flex flex-col gap-4 bg-surface p-6 transition-ui hover:bg-surface-2">
              <span className="font-mono text-[11px] uppercase tracking-eyebrow text-primary-text">{v.tag}</span>
              <h3 className="text-xl font-medium">{v.title}</h3>
              <p className="text-sm text-fg-2">{v.body}</p>
            </div>
          ))}
        </div>
      </section>

      {FEATURES.map((f) => (
        <section key={f.n} className="border-t border-primary/40">
          <div className="container grid gap-8 py-20 md:grid-cols-[1fr_1.4fr] md:py-28">
            <div className="space-y-3">
              <p className="eyebrow">
                {f.n} / {f.eyebrow}
              </p>
              <h2 className="text-3xl font-medium tracking-tight">{f.title}</h2>
            </div>
            <div className="space-y-6">
              <p className="text-lg text-fg-2">{f.body}</p>
              <Button asChild variant="secondary">
                <Link href={f.href}>
                  {f.cta} <ArrowRight />
                </Link>
              </Button>
            </div>
          </div>
        </section>
      ))}

      <section className="border-t border-primary/40">
        <div className="container flex flex-col items-start gap-6 py-20 md:flex-row md:items-center md:justify-between">
          <div className="space-y-3">
            <p className="eyebrow">05 / Build</p>
            <h2 className="text-3xl font-medium tracking-tight">Typed SDK and a public REST API.</h2>
          </div>
          <Button asChild variant="secondary">
            <Link href="/developers">
              Developer docs <ArrowRight />
            </Link>
          </Button>
        </div>
      </section>
    </>
  );
}
