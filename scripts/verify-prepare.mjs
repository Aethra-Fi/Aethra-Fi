// Jalankan di: ROOT  ->  node scripts/verify-prepare.mjs <testnet|mainnet>
// Prepares the source package (Solidity standard JSON input) that verify-contracts.sh submits for each contract,
// and proves it before anything is sent: the package is compiled locally with solc 0.8.26 and its creation code must
// equal the creation code that was broadcast on-chain, byte for byte.
//
// Why: with via-IR, solc output can change with the set of files compiled together. forge verify-contract submits a
// minimal file set, which for some contracts (DLMMPool on testnet) gives different bytecode than the full build that
// was deployed. So each contract gets the first candidate that reproduces the deployed bytes: forge's minimal input,
// then every build-info input in out/build-info.
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
const OUT = join(CONTRACTS, "verification", network);
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
  for (const f of readdirSync(chainDir)) {
    if (!f.endsWith(".json")) continue;
    const { transactions = [] } = JSON.parse(readFileSync(join(chainDir, f), "utf8"));
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

let buildInfos = null;
function buildInfoInputs(path) {
  if (!buildInfos) {
    const dir = join(CONTRACTS, "out/build-info");
    buildInfos = readdirSync(dir)
      .filter((f) => f.endsWith(".json"))
      .map((f) => {
        const { input } = JSON.parse(readFileSync(join(dir, f), "utf8"));
        for (const k of ["version", "allowPaths", "basePath", "includePaths"]) delete input[k];
        return { id: f.replace(/\.json$/, ""), input };
      })
      .filter((b) => b.input.settings?.optimizer?.runs === 800);
  }
  return buildInfos.filter((b) => b.input.sources[path]);
}

/** Creation code of `path:name` compiled from `input`, or null on a compile error. */
function compile(input, path, name) {
  const job = structuredClone(input);
  job.settings.outputSelection = { [path]: { [name]: ["evm.bytecode.object"] } };
  const r = spawnSync(SOLC, ["--standard-json"], { input: JSON.stringify(job), maxBuffer: 1 << 30 });
  const out = JSON.parse(r.stdout.toString());
  return out.contracts?.[path]?.[name]?.evm?.bytecode?.object ?? null;
}

/**
 * A build-info input holds the whole project (tests and scripts too), and the explorer compiles every file in a package:
 * that took minutes and the explorer gave up. Drop files in shrinking chunks and keep each drop that still reproduces
 * the deployed bytes; the files forge needs for the contract are never dropped.
 */
function minimize(c, path, name, matches) {
  const needed = new Set(Object.keys(minimalInput(`${path}:${name}`).sources));
  let removable = Object.keys(c.input.sources).filter((k) => !needed.has(k));
  const without = (drop) => {
    const job = structuredClone(c.input);
    for (const k of drop) delete job.sources[k];
    return job;
  };
  for (let size = removable.length; size >= 1; size = Math.floor(size / 2)) {
    for (let i = 0; i < removable.length; ) {
      const chunk = removable.slice(i, i + size);
      const job = without(chunk);
      if (matches(compile(job, path, name))) {
        c.input = job;
        removable = removable.filter((k) => !chunk.includes(k));
      } else {
        i += size;
      }
    }
  }
  c.minimized = true;
  c.tag += `, ${Object.keys(c.input.sources).length} files`;
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
  if (!cache.has(row.source)) cache.set(row.source, []);
  const tried = cache.get(row.source);

  const check = (c) => c.code !== null && want === c.code + args;
  let hit = tried.find(check);
  if (!hit) {
    const candidates = [() => ({ tag: "forge", input: scrub(minimalInput(row.source)) })];
    for (const b of buildInfoInputs(path)) candidates.push(() => ({ tag: `build-info ${b.id}`, input: scrub(b.input) }));
    for (const make of candidates.slice(tried.length)) {
      const c = make();
      if (tried.some((t) => t.tag === c.tag)) continue;
      c.code = compile(c.input, path, name);
      tried.push(c);
      if (check(c)) {
        hit = c;
        break;
      }
    }
  }
  if (hit && hit.tag !== "forge" && !hit.minimized) minimize(hit, path, name, (code) => code !== null && want === code + args);
  if (!hit) {
    failed++;
    console.error(`✗ ${row.label} ${row.address}: no source package reproduces the deployed bytecode`);
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
