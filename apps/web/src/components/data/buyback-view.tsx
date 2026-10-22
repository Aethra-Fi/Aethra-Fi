"use client";

import { useReadContracts } from "wagmi";
import { AddressLink, EmptyState, KV, NotDeployed, PageHeader, Panel, QueryState, Stat, StatGrid, TxLink } from "@/components/kit";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { useBuybacks } from "@/hooks/use-api";
import { ABIS, addressOf } from "@/lib/contracts";
import { formatBps, formatPct, formatTokenAmount, formatUsd, timeAgo } from "@/lib/format";
import { CHAIN_ID } from "@/lib/network";

const SUPPLY = 1_000_000_000n * 10n ** 18n;

export function BuybackView() {
  const buyback = addressOf("buyback");
  const aeth = addressOf("aeth");
  const q = useBuybacks();
  const r = useReadContracts({
    contracts: [
      { address: buyback ?? undefined, abi: ABIS.buyback, functionName: "totalBurned", chainId: CHAIN_ID },
      { address: buyback ?? undefined, abi: ABIS.buyback, functionName: "config", chainId: CHAIN_ID },
      { address: aeth ?? undefined, abi: ABIS.aeth, functionName: "totalSupply", chainId: CHAIN_ID },
    ],
    query: { enabled: !!buyback && !!aeth, refetchInterval: 30_000 },
  });
  const burned = r.data?.[0]?.result as bigint | undefined;
  const cfg = r.data?.[1]?.result as readonly [string, string, bigint, number] | undefined;
  const supply = r.data?.[2]?.result as bigint | undefined;

  return (
    <>
      <PageHeader
        eyebrow="Buyback & burn"
        title="Revenue into AETH, then burned"
        description="Swap fees, launch fees and graduation fees collect in the buyback contract. A keeper sends the treasury share out, swaps the rest into AETH through the router and burns it."
      />
      {!buyback || !aeth ? (
        <div className="mt-8">
          <NotDeployed name="Buyback" />
        </div>
      ) : (
        <>
          <StatGrid className="mt-8">
            <Stat label="AETH burned" value={burned !== undefined ? formatTokenAmount(burned, 18, 0) : "—"} hint={q.data?.total_burned_usd ? formatUsd(q.data.total_burned_usd) : undefined} />
            <Stat label="Supply burned" value={burned !== undefined ? formatPct((Number(burned) / Number(SUPPLY)) * 100, 4) : "—"} />
            <Stat label="Circulating max" value={supply !== undefined ? formatTokenAmount(supply, 18, 0) : "—"} />
            <Stat label="Treasury share" value={cfg ? formatBps(cfg[3]) : "—"} hint={cfg ? `Cooldown ${Number(cfg[2]) / 60} min per token` : undefined} />
          </StatGrid>
          <div className="mt-8 grid gap-6 lg:grid-cols-[1fr_1.6fr]">
            <div className="space-y-6">
              <Panel title="Contracts">
                <KV label="Buyback" value={<AddressLink address={buyback} />} />
                <KV label="AETH" value={<AddressLink address={aeth} />} />
              </Panel>
              <Panel title="Pending revenue">
                <QueryState query={q} isEmpty={(d) => !d.revenue.length} empty={<p className="text-sm text-muted">Nothing waiting.</p>}>
                  {(d) =>
                    d.revenue.map((x) => (
                      <KV key={x.token.address} label={x.token.symbol} value={`${formatTokenAmount(x.amount, x.token.decimals)}${x.amount_usd ? ` · ${formatUsd(x.amount_usd)}` : ""}`} />
                    ))
                  }
                </QueryState>
              </Panel>
            </div>
            <div className="space-y-3">
              <p className="eyebrow">Executions</p>
              <QueryState query={q} isEmpty={(d) => !d.executions.length} empty={<EmptyState title="No buybacks yet" />}>
                {(d) => (
                  <div className="overflow-x-auto border">
                    <Table>
                      <TableHeader>
                        <TableRow>
                          <TableHead>Spent</TableHead>
                          <TableHead className="text-right">AETH burned</TableHead>
                          <TableHead className="text-right">To treasury</TableHead>
                          <TableHead>Tx</TableHead>
                          <TableHead className="text-right">Age</TableHead>
                        </TableRow>
                      </TableHeader>
                      <TableBody>
                        {d.executions.map((e) => (
                          <TableRow key={e.tx_hash}>
                            <TableCell className="num">
                              {e.token_in ? `${formatTokenAmount(e.amount_in, e.token_in.decimals)} ${e.token_in.symbol}` : e.amount_in}
                            </TableCell>
                            <TableCell className="num text-right">{formatTokenAmount(e.aeth_burned, 18, 2)}</TableCell>
                            <TableCell className="num text-right">{e.token_in ? formatTokenAmount(e.to_treasury, e.token_in.decimals) : e.to_treasury}</TableCell>
                            <TableCell>
                              <TxLink hash={e.tx_hash} />
                            </TableCell>
                            <TableCell className="num text-right text-muted">{timeAgo(e.timestamp)}</TableCell>
                          </TableRow>
                        ))}
                      </TableBody>
                    </Table>
                  </div>
                )}
              </QueryState>
            </div>
          </div>
        </>
      )}
    </>
  );
}
