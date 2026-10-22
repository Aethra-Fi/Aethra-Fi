# Infrastructure

No secrets live in this file or in the repo. Supabase database passwords live in `~/.config/aethra-fi/supabase.env` (chmod 600) on the developer machine; the service role key lives only in Supabase.

## Chains

| | Chain ID | RPC | Explorer |
|---|---|---|---|
| Robinhood Chain Testnet | 46630 | https://rpc.testnet.chain.robinhood.com | https://explorer.testnet.chain.robinhood.com |
| Robinhood Chain (dry run only) | 4663 | https://rpc.mainnet.chain.robinhood.com | https://robinhoodchain.blockscout.com |
| Local Anvil fork of testnet | 31337 | http://127.0.0.1:8545 | — |

## Contracts

Proxy addresses per network are in `packages/sdk/src/addresses/{local,testnet,mainnet}.json` (the SDK, web app and indexer all read these). Owner and upgrade authority: deployer `0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C`.

- Testnet deployed 2026-10-22 with `scripts/testnet-deploy.sh` (broadcasts in `packages/contracts/broadcast/*/46630/`). Start block 140811858.
- `startBlock` is taken from the L2 broadcast receipts (`scripts/set-start-block.mjs`), because `block.number` inside Solidity on Arbitrum-based chains is the L1 block.

## Supabase

| Project | Ref | Region | Use |
|---|---|---|---|
| Aethra-Fi-testnet | `zqbnyshzgxhkfxoyrogq` | ap-northeast-1 (spec said ap-southeast-1, see BLOCKERS B5) | testnet indexer + API |
| Aethra-Fi-mainnet | `nczunmovephgtyrmsgvt` | ap-southeast-1 | prepared, unused |

- Schema: `supabase/migrations/*` (tables, views, `aethra_refresh`, `api_analytics`, pg_cron job every minute).
- Edge Functions: `indexer` (service-role only; called by pg_cron through pg_net with the URL and key from Supabase Vault) and `api` (public, read-only, `{ data }` responses).
- Load addresses: `SUPABASE_URL=… SUPABASE_SERVICE_ROLE_KEY=… node supabase/scripts/sync-deployments.mjs testnet`.
- Cron auth: Vault secrets `project_url` and `indexer_token`, plus the function secret `INDEXER_TOKEN` (same random value, never in the repo). A dedicated token is used because the runtime's service key format differs between projects (legacy JWT vs `sb_secret_`).
- Status 2026-10-22: testnet has migrations, seed, both functions, Vault secrets and a live cron (indexing every minute). Mainnet has migrations, seed and functions only; with no Vault secrets its cron does nothing.
- Optional function secret `RPC_URL_<chainId>` overrides the public RPC.

API base URLs:
- testnet: `https://zqbnyshzgxhkfxoyrogq.supabase.co/functions/v1/api`
- mainnet (prepared): `https://nczunmovephgtyrmsgvt.supabase.co/functions/v1/api`

## Vercel

| | |
|---|---|
| Project | `aethra-fi` (`prj_SLsSI8RlphxR7igGUT6AeytaH8KV`) |
| Root directory | `apps/web` |
| Build | `cd ../.. && pnpm turbo run build --filter=@aethra/web` (builds `@aethra/sdk` first) |
| Production branch | `mainnet` (prepared, not used yet) |
| Testnet | branch `testnet` → preview, alias `aethra-fi-testnet.vercel.app` |
| Git | `Aethra-Fi/Aethra-Fi`, waiting on BLOCKERS B7 |

Environment variables:

| Key | Production (mainnet) | Preview (testnet) |
|---|---|---|
| `NEXT_PUBLIC_NETWORK` | `mainnet` | `testnet` |
| `NEXT_PUBLIC_API_URL` | mainnet API URL | testnet API URL |
| `NEXT_PUBLIC_SITE_URL` | `https://aethra-fi.vercel.app` | `https://aethra-fi-testnet.vercel.app` |

## Local development

```bash
# Jalankan di: ROOT
bash scripts/local-chain.sh          # Anvil fork of testnet (chain 31337)
bash scripts/local-deploy.sh         # deploy everything by impersonating the deployer
bash scripts/local-activity.sh       # optional: real swaps, pools, a launch, an order and a loan
supabase start && supabase db reset  # local Postgres with migrations + seed
pnpm dev                             # web app
```

The Docker edge runtime cannot reach Anvil on 127.0.0.1, so to index the local chain run the indexer on the host:
`cd supabase/functions && SUPABASE_URL=… SUPABASE_SERVICE_ROLE_KEY=… RPC_URL_31337=http://127.0.0.1:8545 deno run --config deno.json -A indexer/index.ts`.
