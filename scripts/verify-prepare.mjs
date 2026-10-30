// Jalankan di: ROOT  ->  node scripts/verify-prepare.mjs <testnet|mainnet>
// Prepares the source package (Solidity standard JSON input) that verify-contracts.sh submits for each contract,
// and proves it before anything is sent: the package is compiled locally with solc 0.8.26 and its creation code must
// equal the creation code that was broadcast on-chain, byte for byte.
//
// The package is forge's minimal standard JSON input (the contract and its imports). With via-IR, a contract compiled
// inside the whole project can differ from the same contract compiled from that small package; such contracts are
// deployed from the small package's bytecode (scripts/build-verifiable.mjs). A contract that still does not match
// stops the run: a whole-project package would take the explorer minutes to compile and it gives up.
//
// Packages are scrubbed of local absolute paths (they would be published on the explorer) and written to
// packages/contracts/verification/<network>/ (git-ignored) with a manifest.json.
import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

const network = process.argv[2];
if (!["testnet", "mainnet"].includes(network)) {
  console.error("usage: node scripts/verify-prepare.mjs <testnet|mainnet>");
  process.exit(1);
}
const ROOT = resolve(".");
const CONTRACTS = join(ROOT, "packages/contracts");
const SOLC = join(homedir(), ".local/share/svm/0.8.26/solc-0.8.26");
const COMPILER = "v0.8.26+commit.8a97fa7a";
const CHAIN = { testnet: 46630, mainnet: 4663 }[network];
const OUT = join(CONTRACTS, "verification", process.env.VERIFY_DRY_RUN ? `${network}-dry-run` : network);
const quiet = process.argv.includes("--quiet");
const log = (...a) => quiet || console.log(...a);

if (!existsSync(SOLC)) {
  console.error(`solc 0.8.26 not found at ${SOLC} (run forge build once)`);
  process.exit(1);
}

// rows: label, address, source, constructor args (from verify-list.mjs)
const rows = JSON.parse(execFileSync("node", ["scripts/verify-list.mjs", network, "--json"], { cwd: ROOT, stdio: ["ignore", "pipe", "ignore"] }));

// creation code actually broadcast for each address
const deployed = new Map();
for (const dir of readdirSync(join(CONTRACTS, "broadcast"))) {
  const chainDir = join(CONTRACTS, "broadcast", dir, String(CHAIN));
  if (!existsSync(chainDir)) continue;
  const files = readdirSync(chainDir).filter((f) => f.endsWith(".json")).map((f) => join(chainDir, f));
  // VERIFY_DRY_RUN=1 proves the packages against the dry run before a real broadcast (see verify-list.mjs)
  if (process.env.VERIFY_DRY_RUN && existsSync(join(chainDir, "dry-run"))) {
    for (const f of readdirSync(join(chainDir, "dry-run"))) if (f.endsWith(".json")) files.push(join(chainDir, "dry-run", f));
  }
  for (const file of files) {
    const { transactions = [] } = JSON.parse(readFileSync(file, "utf8"));
    for (const tx of transactions) {
      if (!tx.contractAddress || !tx.transactionType.startsWith("CREATE")) continue;
      let input = tx.transaction.input.replace(/^0x/, "");
      if (tx.transactionType === "CREATE2") input = input.slice(64);
      deployed.set(tx.contractAddress.toLowerCase(), input);
    }
  }
}

// ------------------------------------------------------------------ candidates

/** Replace absolute local paths with project-relative ones; the explorer publishes the whole input. */
function scrub(input) {
  let text = JSON.stringify(input);
  for (const prefix of [`${CONTRACTS}/`, `${ROOT}/`, `${homedir()}/`]) text = text.split(prefix).join("");
  return JSON.parse(text);
}

const leaks = (input) => {
  const text = JSON.stringify(input);
  return text.includes(homedir()) || /\/home\/|\/Users\/|[A-Z]:\\\\/.test(text);
};

function minimalInput(source) {
  // forge prints the standard JSON input it would submit; address and verifier are placeholders here
  const out = execFileSync(
    "forge",
    ["verify-contract", "0x0000000000000000000000000000000000000001", source, "--chain", String(CHAIN), "--compiler-version", "0.8.26",
      "--compilation-profile", "default", "--show-standard-json-input", "--verifier", "blockscout", "--verifier-url", "https://localhost/api/"],
    { cwd: CONTRACTS, stdio: ["ignore", "pipe", "ignore"], maxBuffer: 1 << 30 },
  );
  return JSON.parse(out);
}

/** Creation code of `path:name` compiled from `input`, or null on a compile error. */
function compile(input, path, name) {
  const job = structuredClone(input);
  job.settings.outputSelection = { [path]: { [name]: ["evm.bytecode.object"] } };
  const r = spawnSync(SOLC, ["--standard-json"], { input: JSON.stringify(job), maxBuffer: 1 << 30 });
  const out = JSON.parse(r.stdout.toString());
  return out.contracts?.[path]?.[name]?.evm?.bytecode?.object ?? null;
}

// ------------------------------------------------------------------ prepare

rmSync(OUT, { recursive: true, force: true });
mkdirSync(OUT, { recursive: true });
const manifest = [];
const cache = new Map(); // source -> [{ tag, input, code }]
let failed = 0;

for (const [i, row] of rows.entries()) {
  const [path, name] = row.source.split(":");
  const want = deployed.get(row.address);
  const args = (row.args ?? "").replace(/^0x/, "");
  if (!want) {
    console.error(`no broadcast record for ${row.address}`);
    process.exit(1);
  }
  if (!cache.has(row.source)) {
    const input = scrub(minimalInput(row.source));
    cache.set(row.source, { tag: "forge", input, code: compile(input, path, name) });
  }
  const c = cache.get(row.source);
  const hit = c.code !== null && want === c.code + args ? c : null;
  if (!hit) {
    failed++;
    console.error(`✗ ${row.label} ${row.address}: its source package does not reproduce the deployed bytecode (deploy it through scripts/build-verifiable.mjs)`);
    continue;
  }
  if (leaks(hit.input)) {
    console.error(`✗ ${row.label}: source package still contains a local path`);
    process.exit(1);
  }
  const file = `${String(i + 1).padStart(2, "0")}-${row.address}.json`;
  writeFileSync(join(OUT, file), JSON.stringify(hit.input));
  manifest.push({ label: row.label, address: row.address, contractName: row.source, args, compiler: COMPILER, file });
  log(`✓ ${row.label.padEnd(36)} ${row.address}  (${hit.tag})`);
}

writeFileSync(join(OUT, "manifest.json"), JSON.stringify(manifest, null, 2));
log(`${manifest.length} of ${rows.length} contracts have a source package that reproduces the deployed bytecode`);
process.exit(failed ? 1 : 0);
