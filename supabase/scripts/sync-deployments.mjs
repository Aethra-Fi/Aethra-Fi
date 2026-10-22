// Jalankan di: ROOT  ->  SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... node supabase/scripts/sync-deployments.mjs <local|testnet|mainnet>
// Loads packages/sdk/src/addresses/<network>.json into public.deployments (the indexer rewinds on change).
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const CHAIN_IDS = { local: 31337, testnet: 46630, mainnet: 4663 };
const network = process.argv[2];
if (!(network in CHAIN_IDS)) {
  console.error("usage: sync-deployments.mjs <local|testnet|mainnet>");
  process.exit(1);
}
const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!url || !key) {
  console.error("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required");
  process.exit(1);
}

const here = dirname(fileURLToPath(import.meta.url));
const addresses = JSON.parse(readFileSync(join(here, "../../packages/sdk/src/addresses", `${network}.json`), "utf8"));
const res = await fetch(`${url.replace(/\/$/, "")}/rest/v1/rpc/aethra_set_deployment`, {
  method: "POST",
  headers: { "content-type": "application/json", apikey: key, authorization: `Bearer ${key}` },
  body: JSON.stringify({ p_chain: CHAIN_IDS[network], p_addresses: addresses, p_start_block: addresses.startBlock ?? 0 }),
});
if (!res.ok) {
  console.error(`failed: ${res.status} ${await res.text()}`);
  process.exit(1);
}
console.log(`deployments[${CHAIN_IDS[network]}] <- ${network}.json (start block ${addresses.startBlock ?? 0})`);
