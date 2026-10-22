// Jalankan di: ROOT  ->  node scripts/set-start-block.mjs <local|testnet|mainnet>
// Sets startBlock in packages/sdk/src/addresses/<network>.json to the first L2 block of the Deploy broadcast.
// (On Arbitrum-based chains `block.number` inside Solidity is the L1 block, so the script cannot write it.)
import { readFileSync, writeFileSync } from "node:fs";

const CHAIN_IDS = { local: 31337, testnet: 46630, mainnet: 4663 };
const network = process.argv[2];
if (!(network in CHAIN_IDS)) throw new Error("usage: set-start-block.mjs <local|testnet|mainnet>");
const run = JSON.parse(readFileSync(`packages/contracts/broadcast/Deploy.s.sol/${CHAIN_IDS[network]}/run-latest.json`, "utf8"));
const start = Math.min(...run.receipts.map((r) => Number(BigInt(r.blockNumber))));
const path = `packages/sdk/src/addresses/${network}.json`;
const json = JSON.parse(readFileSync(path, "utf8"));
json.startBlock = start;
writeFileSync(path, `${JSON.stringify(json, null, 2)}\n`);
console.log(`${network}: startBlock = ${start}`);
