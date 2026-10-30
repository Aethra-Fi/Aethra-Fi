// Jalankan di: ROOT  ->  node scripts/verify-list.mjs <testnet|mainnet> [--json]
// Lists every Aethra contract deployed on a network for explorer verification, built from the forge broadcast
// records: label, address, source (path:Contract) and ABI-encoded constructor arguments.
// The contract behind each creation is found by matching the creation code against the local build (out/),
// because broadcast records do not always carry the contract name.
// Run `forge build` in packages/contracts first. Prints tab-separated rows (or JSON with --json).
import { readdirSync, readFileSync, existsSync } from "node:fs";
import { join } from "node:path";

const network = process.argv[2];
const asJson = process.argv.includes("--json");
const CONTRACTS = "packages/contracts";

// Broadcast runs per network, in deployment order. `skip` drops implementations that a later upgrade replaced.
const RUNS = {
  testnet: [
    { file: "Deploy.s.sol/46630/run-latest.json" },
    { file: "SetupMarkets.s.sol/46630/run-latest.json", only: ["FaucetToken"] },
    { file: "DeployGated.s.sol/46630/run-latest.json" },
  ],
  mainnet: [{ file: "DeployMainnet.s.sol/4663/deployAll-latest.json" }],
};

const LABEL = {
  AethraHub: "AethraHub",
  AethraPositions: "AethraPositions",
  AethraRouter: "AethraRouter",
  AethraHook: "AethraHook",
  DLMMPool: "DLMM pool",
  DLMMFactory: "DLMM factory",
  DLMMLimitOrders: "DLMM limit orders",
  DAMMPool: "DAMM pool",
  DAMMFactory: "DAMM factory",
  AethraLaunchpad: "Launchpad",
  LaunchToken: "Launch token",
  AethraToken: "AETH token",
  AethraBuyback: "Buyback",
  LendingVault: "Lending vault",
  CreditManager: "Credit manager",
  FaucetToken: "Test token",
};

if (!RUNS[network]) {
  console.error("usage: node scripts/verify-list.mjs <testnet|mainnet> [--json]");
  process.exit(1);
}

// ------------------------------------------------------------------ local build index

function artifacts() {
  const out = join(CONTRACTS, "out");
  const list = [];
  for (const dir of readdirSync(out)) {
    if (!dir.endsWith(".sol")) continue;
    for (const f of readdirSync(join(out, dir))) {
      if (!f.endsWith(".json")) continue;
      const a = JSON.parse(readFileSync(join(out, dir, f), "utf8"));
      const code = a.bytecode?.object?.replace(/^0x/, "");
      const target = a.metadata?.settings?.compilationTarget;
      if (!code || code.length < 4 || !target) continue;
      const [path, name] = Object.entries(target)[0];
      // the PoolManager profile writes a second artifact (Name.v4core.json); verification uses the default profile
      if (f.endsWith(".v4core.json")) continue;
      list.push({ code, source: `${path}:${name}`, name });
    }
  }
  // longest first, so a contract never matches a shorter one that happens to be its prefix
  return list.sort((a, b) => b.code.length - a.code.length);
}

const BUILD = artifacts();

function identify(initCode) {
  for (const a of BUILD) if (initCode.startsWith(a.code)) return { ...a, args: initCode.slice(a.code.length) };
  return null;
}

// ------------------------------------------------------------------ rows

const rows = [];
const byAddress = new Map();
for (const run of RUNS[network]) {
  const path = join(CONTRACTS, "broadcast", run.file);
  if (!existsSync(path)) {
    console.error(`missing broadcast record: ${run.file}`);
    process.exit(1);
  }
  const { transactions } = JSON.parse(readFileSync(path, "utf8"));
  for (const tx of transactions) {
    if (!tx.transactionType.startsWith("CREATE") || !tx.contractAddress) continue;
    let input = tx.transaction.input.replace(/^0x/, "");
    if (tx.transactionType === "CREATE2") input = input.slice(64); // CREATE2 deployer input = salt ++ init code
    const hit = identify(input);
    if (!hit) {
      // an implementation replaced by a later upgrade no longer matches the current source; it is not in use
      console.error(`skipped ${tx.contractAddress}: no local build matches (superseded code)`);
      continue;
    }
    if (run.only && !run.only.includes(hit.name)) continue;
    if (run.skip?.includes(hit.name)) continue;
    const address = tx.contractAddress.toLowerCase();
    rows.push({ address, source: hit.source, name: hit.name, args: hit.args });
    byAddress.set(address, rows.at(-1));
  }
}

// Proxies are named after their entry in the SDK address file, beacons after the implementation they point at.
const PROXY_LABEL = {
  hub: "AethraHub",
  positions: "AethraPositions",
  router: "AethraRouter",
  hook: "AethraHook",
  dlmmFactory: "DLMM factory",
  dlmmLimitOrders: "DLMM limit orders",
  dammFactory: "DAMM factory",
  launchpad: "Launchpad",
  buyback: "Buyback",
  lendingVault: "Lending vault",
  creditManager: "Credit manager",
};
const deployment = JSON.parse(readFileSync(`packages/sdk/src/addresses/${network}.json`, "utf8"));
const proxyNames = new Map();
for (const src of [deployment, deployment.hidden ?? {}]) {
  for (const [k, v] of Object.entries(src)) if (PROXY_LABEL[k] && typeof v === "string") proxyNames.set(v.toLowerCase(), PROXY_LABEL[k]);
}

function implLabel(args) {
  const impl = `0x${args.slice(24, 64)}`.toLowerCase();
  const r = byAddress.get(impl);
  return r ? (LABEL[r.name] ?? r.name) : null;
}

const proxied = new Set();
for (const r of rows) {
  if (r.name === "ERC1967Proxy") {
    const l = proxyNames.get(r.address) ?? implLabel(r.args);
    r.label = l ? `${l} (proxy)` : "Proxy";
    proxied.add(`0x${r.args.slice(24, 64)}`.toLowerCase());
  } else if (r.name === "UpgradeableBeacon") {
    const l = implLabel(r.args);
    r.label = l ? `${l} beacon` : "Beacon";
  }
}
for (const r of rows) {
  if (r.label) continue;
  const base = LABEL[r.name] ?? r.name;
  r.label = proxied.has(r.address) || /Pool$|Factory|Orders|Positions|Launchpad|Buyback|Vault|Manager/.test(r.name) ? `${base} (implementation)` : base;
}
// test tokens are named by their symbol
for (const [sym, t] of Object.entries(deployment.tokens ?? {})) {
  const r = byAddress.get(t.address.toLowerCase());
  if (r && r.name === "FaucetToken") r.label = `${sym} test token`;
}

// recording order: core, venues, then tokens and the gated modules; proxy before its implementation
const ORDER = ["AethraHub", "AethraPositions", "AethraRouter", "AethraHook", "DLMM", "DAMM", "Launch", "AETH", "Buyback", "Lending", "Credit", "aUSD", "aTSLA", "aNVDA", "aAAPL"];
const rank = (r) => {
  const i = ORDER.findIndex((o) => r.label.startsWith(o));
  return (i < 0 ? ORDER.length : i) * 10 + (r.label.includes("(proxy)") ? 0 : r.label.includes("beacon") ? 2 : 1);
};
rows.sort((a, b) => rank(a) - rank(b));

if (asJson) {
  console.log(JSON.stringify(rows.map(({ label, address, source, args }) => ({ label, address, source, args })), null, 2));
} else {
  for (const r of rows) console.log([r.label, r.address, r.source, r.args ? `0x${r.args}` : ""].join("\t"));
}
