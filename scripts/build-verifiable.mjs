// Jalankan di: ROOT  ->  node scripts/build-verifiable.mjs
// Compiles the contracts listed below from exactly the source package an explorer receives (forge's minimal standard
// JSON input) and writes their creation code to packages/contracts/verifiable/<Name>.bin, which the deploy scripts use.
//
// Why: with via-IR, solc 0.8.26 output for some contracts depends on every file compiled in the same job (AST ids).
// `forge build` compiles the whole project, scripts and tests included, so the deployed DLMMPool could only be
// reproduced with a ~160-file package that takes over a minute to compile, and the explorer gives up. Deploying the
// bytecode of the small package makes the deployed code and the verified code the same by construction.
// The deploy wrappers (testnet-redeploy.sh, mainnet-deploy.sh) run this first, so the files always match the source.
import { execFileSync, spawnSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

const CONTRACTS = resolve("packages/contracts");
const SOLC = join(homedir(), ".local/share/svm/0.8.26/solc-0.8.26");
const OUT = join(CONTRACTS, "verifiable");
const TARGETS = ["src/dlmm/DLMMPool.sol:DLMMPool"];

mkdirSync(OUT, { recursive: true });
for (const target of TARGETS) {
  const [path, name] = target.split(":");
  const raw = execFileSync(
    "forge",
    ["verify-contract", "0x0000000000000000000000000000000000000001", target, "--chain", "46630", "--compiler-version", "0.8.26",
      "--compilation-profile", "default", "--show-standard-json-input", "--verifier", "blockscout", "--verifier-url", "https://localhost/api/"],
    { cwd: CONTRACTS, stdio: ["ignore", "pipe", "ignore"], maxBuffer: 1 << 30 },
  ).toString();
  const input = JSON.parse(raw.split(`${CONTRACTS}/`).join(""));
  const job = structuredClone(input);
  job.settings.outputSelection = { [path]: { [name]: ["evm.bytecode.object", "evm.bytecode.linkReferences"] } };
  const out = JSON.parse(spawnSync(SOLC, ["--standard-json"], { input: JSON.stringify(job), maxBuffer: 1 << 30 }).stdout.toString());
  const c = out.contracts?.[path]?.[name]?.evm?.bytecode;
  if (!c?.object) {
    console.error(`compile failed for ${target}: ${JSON.stringify(out.errors ?? []).slice(0, 300)}`);
    process.exit(1);
  }
  if (Object.keys(c.linkReferences ?? {}).length) {
    console.error(`${target} needs linked libraries; not supported`);
    process.exit(1);
  }
  writeFileSync(join(OUT, `${name}.bin`), `0x${c.object}\n`);
  console.log(`${name}: ${c.object.length / 2} bytes from ${Object.keys(input.sources).length} files`);
}
