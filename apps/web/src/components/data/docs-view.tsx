import Link from "next/link";
import { PageHeader } from "@/components/kit";

interface Block {
  id: string;
  title: string;
  body: React.ReactNode;
}

const A = ({ href, children }: { href: string; children: React.ReactNode }) => (
  <Link href={href} className="text-primary-text underline-offset-4 hover:underline">
    {children}
  </Link>
);

const Mono = ({ children }: { children: React.ReactNode }) => <span className="font-mono text-[0.92em] text-fg">{children}</span>;

function Dl({ rows }: { rows: [string, React.ReactNode][] }) {
  return (
    <dl className="divide-y border">
      {rows.map(([k, v]) => (
        <div key={k} className="grid gap-1 px-4 py-3 sm:grid-cols-[11rem_1fr] sm:gap-4">
          <dt className="eyebrow pt-0.5">{k}</dt>
          <dd className="text-sm text-fg-2">{v}</dd>
        </div>
      ))}
    </dl>
  );
}

const BLOCKS: Block[] = [
  {
    id: "overview",
    title: "Overview",
    body: (
      <>
        <p>
          Aethra Fi is an experimental liquidity layer on Robinhood Chain. It puts three kinds of pool behind one router, prices fees from volatility,
          and lets stock-token pools follow an oracle. Everything runs on chain; the website only reads from an indexer and sends your transactions.
        </p>
        <Dl
          rows={[
            ["Venues", "Uniswap v4 hook pools, DLMM bin pools and DAMM range pools."],
            ["Router", "One quote across every venue, direct or two hops, settled in one transaction."],
            ["Fees", "Base fee plus a volatility component that widens in fast markets and decays in calm ones."],
            ["Stock pools", "Pools for stock tokens read a reference price and charge more for trades away from it."],
            ["Availability", "Testnet runs every venue. Mainnet opens in stages: v4 hook pools first, then DLMM, DAMM and limit orders, then stock pools. A venue appears in the app as soon as it opens on chain."],
          ]}
        />
      </>
    ),
  },
  {
    id: "getting-started",
    title: "Getting started",
    body: (
      <>
        <ol className="list-decimal space-y-2 pl-5">
          <li>
            Click <Mono>Connect wallet</Mono> in the header and pick a wallet. Aethra asks to switch to Robinhood Chain (or its testnet).
          </li>
          <li>
            On testnet, get ETH for gas from the{" "}
            <a className="text-primary-text underline-offset-4 hover:underline" href="https://faucet.testnet.chain.robinhood.com" target="_blank" rel="noreferrer">
              Robinhood Chain faucet
            </a>
            . Test tokens such as aUSD come from their own faucet functions.
          </li>
          <li>
            Open <A href="/swap">Swap</A> to trade, or <A href="/pools">Pools</A> to find a pool and add liquidity.
          </li>
        </ol>
        <Dl
          rows={[
            ["Testnet", "Robinhood Chain Testnet · chain ID 46630"],
            ["Mainnet", "Robinhood Chain · chain ID 4663"],
            ["Gas token", "ETH"],
          ]}
        />
      </>
    ),
  },
  {
    id: "swap",
    title: "Swap and smart router",
    body: (
      <>
        <p>
          The router quotes every pool that holds your pair, plus two-hop paths through a shared token, using <Mono>eth_call</Mono>. It picks the path
          with the best output and executes it in one transaction. ETH is wrapped and unwrapped for you.
        </p>
        <Dl
          rows={[
            ["Slippage", "Set a tolerance on the swap card. The transaction reverts if the output falls below it."],
            ["Deadline", "Every swap carries a deadline so a stuck transaction cannot fill at a stale price."],
            ["Route", "The card shows each hop, its venue and its fee before you confirm."],
          ]}
        />
      </>
    ),
  },
  {
    id: "pools",
    title: "Pools and venues",
    body: (
      <>
        <p>
          <A href="/pools">Pools</A> lists every pool with TVL, volume, fee and a 24 hour price chart. Filter by trending, most traded, highest volume,
          fresh or stock pools, or by venue.
        </p>
        <Dl
          rows={[
            ["v4 hook pools", "Uniswap v4 pools that share the Aethra hook. The hook sets the fee on every swap and runs the oracle guard."],
            ["DLMM", "Liquidity sits in discrete price bins. Trades inside one bin have zero slippage. Pick a bin step from 1 to 100 bps."],
            ["DAMM", "One price range per pool with fungible shares. An optional launch fee starts high and decays to the base fee."],
          ]}
        />
        <p>
          To open a new pool, use <A href="/pools/create">Create pool</A>, choose a venue, a token pair and a starting price, then seed it with liquidity.
        </p>
      </>
    ),
  },
  {
    id: "liquidity",
    title: "Liquidity and positions",
    body: (
      <>
        <p>
          Add liquidity from a pool page. v4 positions are ERC-721 tokens, so they show up in your wallet and can be locked or vested. DLMM positions
          spread across bins using a shape: <Mono>spot</Mono>, <Mono>curve</Mono> or <Mono>bid-ask</Mono>. DAMM positions are fungible shares.
        </p>
        <p>
          <A href="/positions">Positions</A> shows what you hold on every venue, the amounts inside it, and the fees you can collect.
        </p>
      </>
    ),
  },
  {
    id: "orders",
    title: "Limit orders",
    body: (
      <p>
        <A href="/orders">Limit orders</A> park liquidity in a single DLMM bin. The order fills as the active bin crosses it. You can claim the proceeds
        yourself, or a keeper can claim for you. Cancel any time before it fills.
      </p>
    ),
  },
  {
    id: "fees",
    title: "Dynamic fees",
    body: (
      <>
        <p>
          Each pool pays a base fee plus a variable part that grows with recent price movement. A volatility accumulator rises as the price moves
          and decays back over time, so the fee returns to the base fee once the market settles.
        </p>
        <Dl
          rows={[
            ["Base fee", "0.05% on default dynamic v4 pools, 0.30% on stock pools"],
            ["Fee ceiling", "2% on default dynamic pools, 3% on stock pools; 10% hard protocol cap"],
            ["Decay", "600 s window back toward the base fee"],
            ["Where", "v4 hook pools, DLMM and DAMM share the same fee model"],
          ]}
        />
      </>
    ),
  },
  {
    id: "oracle",
    title: "Oracle guard and stock pools",
    body: (
      <>
        <p>
          Pools that hold a stock token read a reference price. A trade that moves the pool toward the oracle price pays the base fee. A trade that moves
          it away pays more. A circuit breaker reverts any swap that would push the pool too far from the oracle, and swaps revert while the feed is unavailable.
        </p>
        <p>
          Open any stock pool to see the oracle price, the gap to the pool price and the breaker state. Use the <Mono>Stocks</Mono> filter on{" "}
          <A href="/pools?filter=stock">Pools</A> to list them. On mainnet the reference prices are Chainlink feeds. Stock feeds update only while US markets trade, so a pool halts after a day without an update (over a weekend) and trades again once the feed resumes; liquidity can always be withdrawn. Testnet stock tokens use mock oracles.
        </p>
      </>
    ),
  },
  {
    id: "data",
    title: "Analytics and events",
    body: (
      <p>
        <A href="/analytics">Analytics</A> charts TVL, volume and fees with a breakdown by venue. The <A href="/events">Event feed</A> lists every swap,
        deposit and order as it lands on chain. An indexer reads the chain every minute, so numbers can trail a block by up to a minute.
      </p>
    ),
  },
  {
    id: "developers",
    title: "Developers",
    body: (
      <>
        <p>
          <Mono>@aethrafi/sdk</Mono> ships addresses, ABIs and route helpers for each network. The REST API is public and read only, and every response is
          shaped as <Mono>{"{ data }"}</Mono>. See <A href="/developers">Developers</A> for endpoints and examples, and <A href="/contracts">Contracts</A> for
          every deployed address.
        </p>
        <p>All Aethra contracts are UUPS proxies. The address you read in the SDK stays the same when logic is upgraded.</p>
      </>
    ),
  },
  {
    id: "faq",
    title: "FAQ",
    body: (
      <Dl
        rows={[
          ["Is Aethra on mainnet?", "Not yet. Aethra runs on Robinhood Chain Testnet, where tokens carry no value. Mainnet launch will be announced here."],
          ["Why did my swap revert?", "The output fell below your slippage tolerance, or a stock pool circuit breaker blocked a swap that would push it too far from the oracle."],
          ["Why is a pool chart flat?", "Charts move when trades move the price. A pool with no trades in the last 24 hours shows a steady line."],
          ["Where is my position?", "Connect the wallet that opened it. Positions load by owner address across every venue."],
        ]}
      />
    ),
  },
];

export function DocsView() {
  return (
    <>
      <PageHeader
        eyebrow="Docs"
        title="Aethra Docs"
        description="How trading, pools, fees and stock pools work on Aethra Fi, and where to find the SDK and API."
      />
      <div className="mt-10 grid gap-10 lg:grid-cols-[14rem_1fr]">
        <nav aria-label="On this page" className="lg:sticky lg:top-[calc(var(--header-h)+1.5rem)] lg:self-start">
          <p className="eyebrow mb-3">On this page</p>
          <ul className="flex flex-wrap gap-x-4 gap-y-2 lg:block lg:space-y-2">
            {BLOCKS.map((b) => (
              <li key={b.id}>
                <a href={`#${b.id}`} className="text-sm text-fg-2 transition-ui hover:text-primary-text">
                  {b.title}
                </a>
              </li>
            ))}
          </ul>
        </nav>
        <div className="max-w-3xl space-y-12">
          {BLOCKS.map((b, i) => (
            <section key={b.id} id={b.id} className="scroll-mt-[calc(var(--header-h)+1.5rem)] space-y-4 text-[15px] leading-relaxed text-fg-2">
              <p className="eyebrow">{String(i).padStart(2, "0")}</p>
              <h2 className="text-2xl font-medium tracking-tight text-fg">{b.title}</h2>
              {b.body}
            </section>
          ))}
        </div>
      </div>
    </>
  );
}
