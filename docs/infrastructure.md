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
- Status 2026-10-22: testnet has migrations, seed, both functions, Vault secrets and a live cron (indexing every minute). Mainnet has migrations, seed and functions only; with no Vault secrets its cron does nothing. Update 2026-10-31: mainnet is current (all migrations, functions redeployed, Vault secrets and `INDEXER_TOKEN` set, cron calls the indexer with HTTP 200 and it skips until the deployment is synced).
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
| Testnet | branch `testnet` → preview, alias `aethra-fi-testnet.vercel.app`, custom domain `testnet.aethra.finance` |
| Mainnet | production branch `mainnet` → `aethra.finance` (`www.aethra.finance` redirects 308 to apex) |
| Git | `Aethra-Fi/Aethra-Fi`, connected 2026-10-22 |
| Deployment protection | off (`ssoProtection: null`) so the testnet site is public; env vars are all public `NEXT_PUBLIC_*` values |

Network toggle: both builds ship the Testnet / Mainnet toggle in the header. The choice is saved in the browser (`aethra-network`). The API of each network is built in (`NEXT_PUBLIC_API_URL_TESTNET`, `NEXT_PUBLIC_API_URL_MAINNET` override it; RPC overrides are `NEXT_PUBLIC_RPC_URL_TESTNET` and `NEXT_PUBLIC_RPC_URL_MAINNET`). A network becomes selectable when `hub` is set in `packages/sdk/src/addresses/<network>.json`, so the mainnet button unlocks by itself when the mainnet addresses are published.

Environment variables:

| Key | Production (mainnet) | Preview (testnet) |
|---|---|---|
| `NEXT_PUBLIC_NETWORK` (network a new visitor sees first) | `mainnet` | `testnet` |
| `NEXT_PUBLIC_API_URL` (optional, overrides the API of that default network only) | mainnet API URL | testnet API URL |
| `NEXT_PUBLIC_SITE_URL` | `https://aethra.finance` | `https://testnet.aethra.finance` |

## Domain

`aethra.finance` is registered at Hostinger; DNS stays at Hostinger (nameservers `nebula.dns-parking.com`, `aurora.dns-parking.com`). Vercel domains added 2026-10-28 via API.

| Host | DNS record at Hostinger | Vercel target |
|---|---|---|
| `aethra.finance` | `A` `216.198.79.1` (replace parking A `2.57.91.91`) | production (`mainnet`) |
| `www.aethra.finance` | `CNAME` `21ffe789fcdae145.vercel-dns-017.com.` (replace existing CNAME to apex) | 308 redirect to apex |
| `testnet.aethra.finance` | `CNAME` `21ffe789fcdae145.vercel-dns-017.com.` | branch `testnet` |

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

## Testnet redeploy (2026-10-30, B16)

Fresh testnet compiled with the CBOR metadata hash, so the explorer gives exact verification matches. DLMMPool is deployed from the bytecode of its explorer source package (`verifiable/DLMMPool.bin`). It has the same shape as the mainnet release: core, DLMM and DAMM live; launchpad, AETH, buyback and credit deployed but locked (`hidden` in the address file). Script: `bash scripts/testnet-redeploy.sh --broadcast` (117 transactions, start block 145435281). B15 deployed an earlier set the same way; it is abandoned because its DLMM pool implementation cannot be verified. The indexer rows of older deployments were deleted and the new addresses synced.

| Contract | Proxy |
| --- | --- |
| AethraHub | `0xf60b5eB48794960E506DfEF3b4b827429C473Cc3` |
| AethraHook | `0xc29EF3cd019E7b2Fc52491B6EA2ebAFD097bBAcC` |
| AethraRouter | `0x400502775f33afd20860003c7eA7f236bAa57731` |
| AethraPositions | `0x8C0D930c38792EbEF029128F148c72EB6F23CF0D` |
| DLMM factory | `0x3c8183537aA81182063a000Ddb7adDCc573A1Ba9` |
| DLMM limit orders | `0x2c5bA6ab799C24cd45132F003c0bE14A3A5ABe4b` |
| DAMM factory | `0xeE1596883BE11a6dEaD6A4D72c4B30959946C2b3` |

Full list with explorer links: `docs/verification/testnet.md` (written by `scripts/verify-contracts.sh testnet`). The upgrade reference `upgrades/v0-testnet` describes the old deployment; snapshot the current commit before the next testnet upgrade.

## Testnet implementation upgrade (2026-10-30, old deployment, superseded)

Proxy addresses did not change. The ERC-1967 implementation slot of each proxy was read back after the upgrade.

| Contract | Proxy | New implementation |
| --- | --- | --- |
| AethraHub | `0x71Bb058106b1a226a6f66e2152719a6B827c783a` | `0x992B967149da444dA1bFE041006e01Fb17533579` |
| AethraHook | `0xE1eD1ECC79dc893A3A0D8ac9EF90f00819587ACC` | `0x1b9ca349484B920F456498d460EA016448350eE3` |
| AethraRouter | `0xEE8AE4155C653B664727CA5EF0757914aA4769CE` | `0x3470eF43FF1945F213A285E78695902D999A0236` |

Includes the router (R-1 to R-3), hook (H-1) and hub (H-2) fixes. Rollout: `bash scripts/testnet-upgrade.sh --broadcast`, built from the working tree on top of `3be51c6` (the fixes were not committed at that point; commit them so the deployed code is traceable). Broadcast record: `packages/contracts/broadcast/Upgrade.s.sol/46630/run-latest.json`.

Upgrade runbook for any later change:
1. `bash scripts/snapshot-build.sh <git-ref-of-deployed-code> <name>` (once per deployed version).
2. `bash scripts/upgrade.sh <network> <contract(s)> <name>` simulates and validates; add `--broadcast` to send.
3. Mainnet: the script deploys the implementation only; the Safe sends the printed `upgradeToAndCall` calldata.
