import { PageHeader, Panel } from "@/components/kit";
import { API_URL } from "@/lib/api";
import { CHAIN_ID } from "@/lib/network";

function Code({ children }: { children: string }) {
  return (
    <pre className="overflow-x-auto border bg-bg-elevated p-4 font-mono text-[12.5px] leading-relaxed text-fg-2">
      <code>{children.trim()}</code>
    </pre>
  );
}

const ENDPOINTS: [string, string][] = [
  ["GET /health", "Indexer status and head block per chain"],
  [`GET /chains/${CHAIN_ID}/dashboard`, "Stats plus trending, most traded, highest volume and fresh pool lists"],
  [`GET /chains/${CHAIN_ID}/pools`, "Every pool across v4, DLMM and DAMM"],
  [`GET /chains/${CHAIN_ID}/pools/{poolId}`, "One pool with price series and oracle state"],
  [`GET /chains/${CHAIN_ID}/events?type=&pool=&limit=`, "Event feed (swap, liquidity, order)"],
  [`GET /chains/${CHAIN_ID}/tokens`, "Known tokens with kind (canonical, stock, test)"],
  [`GET /chains/${CHAIN_ID}/analytics?range=7d`, "TVL, volume and fee series plus venue breakdown"],
  [`GET /chains/${CHAIN_ID}/positions/{owner}`, "An account's v4, DLMM and DAMM positions"],
  [`GET /chains/${CHAIN_ID}/orders/{owner}`, "An account's DLMM limit orders"],
];

export function DevelopersView() {
  return (
    <>
      <PageHeader
        eyebrow="Developers"
        title="Build on Aethra"
        description="A typed TypeScript SDK with ABIs and addresses for every network, and a public read-only REST API served by the indexer."
      />
      <div className="mt-8 grid grid-cols-[minmax(0,1fr)] gap-6 lg:grid-cols-2">
        <Panel title="SDK · addresses and ABIs">
          <div className="space-y-3">
            <p className="text-sm text-fg-2">
              <span className="font-mono">@aethra/sdk</span> ships chain definitions, proxy addresses per network, full ABIs generated from the contracts, and
              price and route helpers.
            </p>
            <Code>{`
import { createPublicClient, http } from "viem";
import { chainsByNetwork, getDeployment, aethraRouterAbi } from "@aethra/sdk";

const chain = chainsByNetwork.testnet;
const d = getDeployment("testnet");
const client = createPublicClient({ chain, transport: http() });
`}</Code>
          </div>
        </Panel>
        <Panel title="SDK · quote a route">
          <div className="space-y-3">
            <p className="text-sm text-fg-2">
              Quotes run through <span className="font-mono">router.quote</span> over <span className="font-mono">eth_call</span>. Each hop names a venue
              (1 v4, 2 DLMM, 3 DAMM), a pool and venue-specific data.
            </p>
            <Code>{`
const { result: [amountOut] } = await client.simulateContract({
  address: d.router!,
  abi: aethraRouterAbi,
  functionName: "quote",
  args: [hops, 10n ** 18n],
});
`}</Code>
          </div>
        </Panel>
        <Panel title="REST API" className="lg:col-span-2">
          <div className="space-y-4">
            <p className="text-sm text-fg-2">
              Base URL <span className="break-all font-mono text-fg">{API_URL}</span>. Responses are JSON shaped as{" "}
              <span className="font-mono">{"{ data }"}</span>. No key needed.
            </p>
            <div className="hairline-grid grid border">
              {ENDPOINTS.map(([path, desc]) => (
                <div key={path} className="grid gap-1 bg-surface px-4 py-2.5 md:grid-cols-[minmax(0,1.2fr)_1fr]">
                  <span className="break-all font-mono text-[12.5px] text-primary-text">{path}</span>
                  <span className="text-sm text-muted">{desc}</span>
                </div>
              ))}
            </div>
            <Code>{`curl ${API_URL}/chains/${CHAIN_ID}/dashboard`}</Code>
          </div>
        </Panel>
      </div>
    </>
  );
}
