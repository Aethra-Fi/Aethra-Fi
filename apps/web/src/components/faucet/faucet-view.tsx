"use client";

import * as React from "react";
import { ArrowUpRight } from "lucide-react";
import { parseAbi, type Address } from "viem";
import { useAccount, useReadContracts } from "wagmi";
import { AddressLink, AmountField, ConnectGate, EmptyState, KV, PageHeader, Panel, TokenIcon, TxNotice } from "@/components/kit";
import { Button } from "@/components/ui/button";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { NATIVE, useTokenBalance } from "@/hooks/use-token";
import { useTx } from "@/hooks/use-tx";
import { ABIS } from "@/lib/contracts";
import { formatTokenAmount, parseAmount } from "@/lib/format";
import { CHAIN_ID, DEPLOYMENT, NETWORK_LABEL, SELECTABLE_NETWORKS, setNetwork, useNetwork } from "@/lib/network";

const CHAIN_FAUCET = "https://faucet.testnet.chain.robinhood.com";
const wethAbi = parseAbi(["function deposit() payable", "function withdraw(uint256)"]);

interface FaucetToken {
  address: Address;
  symbol: string;
  name: string;
  decimals: number;
}

function formatWait(seconds: number): string {
  const h = Math.floor(seconds / 3600);
  const m = Math.ceil((seconds % 3600) / 60);
  return h > 0 ? `${h}h ${m}m` : `${m}m`;
}

function ClaimRow({ token, amount, lastClaim, cooldown, now }: { token: FaucetToken; amount: bigint; lastClaim: bigint | undefined; cooldown: bigint; now: number }) {
  const tx = useTx();
  const balance = useTokenBalance(token.address);
  const next = lastClaim && lastClaim > 0n ? Number(lastClaim + cooldown) : 0;
  const wait = next > now ? next - now : 0;
  return (
    <TableRow>
      <TableCell>
        <span className="flex items-center gap-2">
          <TokenIcon symbol={token.symbol} />
          <span>
            <span className="block font-medium">{token.symbol}</span>
            <span className="block text-xs text-muted">{token.name}</span>
          </span>
        </span>
      </TableCell>
      <TableCell className="num text-right">{formatTokenAmount(amount, token.decimals)}</TableCell>
      <TableCell className="num text-right">{balance.value === undefined ? "—" : formatTokenAmount(balance.value, token.decimals, 4)}</TableCell>
      <TableCell>
        <AddressLink address={token.address} />
      </TableCell>
      <TableCell className="w-48 text-right">
        <ConnectGate label="Connect">
          <Button
            size="sm"
            className="w-full"
            disabled={tx.busy || wait > 0}
            onClick={() => tx.send({ address: token.address, abi: ABIS.faucetToken, functionName: "faucet", args: [] })}
          >
            {tx.busy ? "Claiming…" : wait > 0 ? `Next in ${formatWait(wait)}` : `Claim ${token.symbol}`}
          </Button>
        </ConnectGate>
        {tx.status !== "idle" && (
          <div className="mt-2 text-left">
            <TxNotice tx={tx} />
          </div>
        )}
      </TableCell>
    </TableRow>
  );
}

function WrapPanel() {
  const [mode, setMode] = React.useState<"wrap" | "unwrap">("wrap");
  const [amount, setAmount] = React.useState("");
  const tx = useTx();
  const weth = DEPLOYMENT.weth as Address;
  const from = mode === "wrap" ? { address: NATIVE, symbol: "ETH", name: "Ether", decimals: 18, kind: "canonical", logo_url: null, native: true } : { address: weth, symbol: "WETH", name: "Wrapped Ether", decimals: 18, kind: "canonical", logo_url: null };
  const raw = parseAmount(amount, 18);
  return (
    <Panel title="Wrap ETH" brackets>
      <div className="space-y-4">
        <div className="grid grid-cols-2 border">
          {(["wrap", "unwrap"] as const).map((m) => (
            <button
              key={m}
              onClick={() => setMode(m)}
              className={`py-2 font-mono text-[12px] uppercase tracking-button ${mode === m ? "bg-surface-2 text-primary-text" : "text-fg-2"}`}
            >
              {m === "wrap" ? "ETH to WETH" : "WETH to ETH"}
            </button>
          ))}
        </div>
        <AmountField label={mode === "wrap" ? "Wrap" : "Unwrap"} value={amount} onChange={setAmount} token={from} right={<span className="font-mono text-sm">{from.symbol}</span>} />
        <ConnectGate>
          <Button
            className="w-full"
            size="lg"
            disabled={!raw || tx.busy}
            onClick={() =>
              mode === "wrap"
                ? tx.send({ address: weth, abi: wethAbi, functionName: "deposit", args: [], value: raw! })
                : tx.send({ address: weth, abi: wethAbi, functionName: "withdraw", args: [raw!] })
            }
          >
            {tx.busy ? "Confirming…" : mode === "wrap" ? "Wrap ETH" : "Unwrap WETH"}
          </Button>
        </ConnectGate>
        <TxNotice tx={tx} />
        <p className="text-sm text-muted">Every Aethra pool trades WETH. The swap page wraps ETH for you, so wrapping here is only needed to add liquidity.</p>
      </div>
    </Panel>
  );
}

export function FaucetView() {
  const network = useNetwork();
  const { address } = useAccount();
  const [now, setNow] = React.useState(() => Math.floor(Date.now() / 1000));
  React.useEffect(() => {
    const id = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 30_000);
    return () => clearInterval(id);
  }, []);

  const candidates: FaucetToken[] = Object.values(DEPLOYMENT.tokens ?? {}).map((t) => ({ address: t.address as Address, symbol: t.symbol, name: t.name, decimals: t.decimals }));
  // only Aethra test tokens expose faucet(); reading faucetAmount tells them apart from other tokens
  const info = useReadContracts({
    contracts: candidates.flatMap((t) => [
      { address: t.address, abi: ABIS.faucetToken, functionName: "faucetAmount", chainId: CHAIN_ID } as const,
      { address: t.address, abi: ABIS.faucetToken, functionName: "FAUCET_COOLDOWN", chainId: CHAIN_ID } as const,
      { address: t.address, abi: ABIS.faucetToken, functionName: "lastClaim", args: [address ?? "0x0000000000000000000000000000000000000000"], chainId: CHAIN_ID } as const,
    ]),
    query: { enabled: network !== "mainnet" && candidates.length > 0, refetchInterval: 30_000 },
  });
  const rows = candidates
    .map((token, i) => ({
      token,
      amount: info.data?.[i * 3]?.result as bigint | undefined,
      cooldown: (info.data?.[i * 3 + 1]?.result as bigint | undefined) ?? 86_400n,
      lastClaim: address ? (info.data?.[i * 3 + 2]?.result as bigint | undefined) : undefined,
    }))
    .filter((r) => r.amount !== undefined)
    // the test dollar first, then the test stocks
    .sort((a, b) => Number(b.token.decimals < 18) - Number(a.token.decimals < 18) || a.token.symbol.localeCompare(b.token.symbol));

  const header = (
    <PageHeader
      eyebrow="Faucet"
      title="Test tokens for Aethra testnet"
      description="Claim test dollars and test stocks once a day per token, wrap testnet ETH, then trade or add liquidity anywhere in the app."
      actions={
        <Button asChild variant="secondary">
          <a href={CHAIN_FAUCET} target="_blank" rel="noreferrer">
            Get testnet ETH <ArrowUpRight className="size-3.5" />
          </a>
        </Button>
      }
    />
  );

  if (network === "mainnet") {
    const testnet = SELECTABLE_NETWORKS.find((n) => n !== "mainnet");
    return (
      <>
        {header}
        <div className="mt-8">
          <EmptyState
            title="The faucet is testnet only"
            action={testnet ? <Button onClick={() => setNetwork(testnet)}>Switch to {NETWORK_LABEL[testnet]}</Button> : undefined}
          >
            Mainnet has no test tokens. Switch the network in the header to try Aethra with free tokens.
          </EmptyState>
        </div>
      </>
    );
  }

  return (
    <>
      {header}
      <div className="mt-8 grid gap-6 lg:grid-cols-[1fr_380px]">
        <Panel className="self-start" title="Test tokens" aside={<span className="font-mono text-[11px] uppercase tracking-eyebrow text-muted">One claim per token per day</span>}>
          {info.isLoading ? (
            <p className="py-10 text-center text-sm text-muted">Loading tokens…</p>
          ) : rows.length === 0 ? (
            <EmptyState title="No faucet tokens on this network" />
          ) : (
            <div className="-m-4 overflow-x-auto">
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>Token</TableHead>
                    <TableHead className="text-right">Per claim</TableHead>
                    <TableHead className="text-right">Your balance</TableHead>
                    <TableHead>Contract</TableHead>
                    <TableHead />
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {rows.map((r) => (
                    <ClaimRow key={r.token.address} token={r.token} amount={r.amount!} lastClaim={r.lastClaim} cooldown={r.cooldown} now={now} />
                  ))}
                </TableBody>
              </Table>
            </div>
          )}
        </Panel>
        <div className="space-y-6">
          <WrapPanel />
          <Panel title="How to start">
            <ol className="list-decimal space-y-2 pl-5 text-sm text-fg-2">
              <li>Get testnet ETH from the Robinhood Chain faucet. It pays for gas.</li>
              <li>Claim aUSD and the test stocks here.</li>
              <li>Swap, add liquidity or place a limit order with them.</li>
            </ol>
            <div className="mt-4 border-t pt-2">
              <KV label="Network" value={NETWORK_LABEL[network]} />
              <KV label="Chain ID" value={CHAIN_ID} />
            </div>
          </Panel>
        </div>
      </div>
    </>
  );
}
