// Jalankan di: ROOT  ->  node scripts/mainnet-cost.mjs <gasPriceWei> [budgetUsd]
// Cost report for the last mainnet dry run of DeployMainnet.deployAll(), grouped by module.
// Gas per transaction is forge's gas limit (estimate x 1.3), so the total is an upper bound.
import { readFileSync } from "node:fs";

const [gasPriceWei, budget = "7"] = process.argv.slice(2);
const run = JSON.parse(readFileSync("packages/contracts/broadcast/DeployMainnet.s.sol/4663/dry-run/deployAll-latest.json", "utf8"));
const res = await fetch("https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd").catch(() => null);
const ethUsd = res?.ok ? (await res.json()).ethereum.usd : Number(process.env.ETH_USD ?? 0);

const GROUP = {
  AethraHub: "Core", AethraPositions: "Core", AethraRouter: "Core", AethraHook: "Core",
  DLMMPool: "DLMM", DLMMFactory: "DLMM", DLMMLimitOrders: "DLMM",
  DAMMPool: "DAMM", DAMMFactory: "DAMM",
  AethraLaunchpad: "Launchpad", LaunchToken: "Launchpad",
  AethraToken: "AETH + buyback", AethraBuyback: "AETH + buyback",
  LendingVault: "Credit", CreditManager: "Credit",
};
const totals = new Map();
let group = "Core";
let all = 0n;
for (const tx of run.transactions) {
  // a proxy or beacon belongs to the implementation deployed right before it; calls are wiring
  if (GROUP[tx.contractName]) group = GROUP[tx.contractName];
  const key = tx.transactionType === "CALL" ? "Wiring (registrars, fee config, assets, caps)" : group;
  const gas = BigInt(tx.transaction.gas);
  totals.set(key, (totals.get(key) ?? 0n) + gas);
  all += gas;
}
const price = BigInt(gasPriceWei);
const eth = (g) => Number(g * price) / 1e18;
const row = (k, g) => `${k.padEnd(48)} ${(Number(g) / 1e6).toFixed(2).padStart(7)}M gas  ${eth(g).toFixed(7)} ETH  $${(eth(g) * ethUsd).toFixed(2)}`;
console.log(`\nMainnet cost (gas price ${Number(price) / 1e9} gwei, ETH $${ethUsd}, ${run.transactions.length} transactions)`);
for (const [k, g] of totals) console.log(row(k, g));
console.log(row("TOTAL", all));
const usd = eth(all) * ethUsd;
console.log(usd <= Number(budget) ? `Within the $${budget} budget.` : `OVER the $${budget} budget.`);
