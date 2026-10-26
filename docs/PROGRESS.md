# PROGRESS: Aethra Fi

Legend: ✅ done · 🔄 in progress · ⏳ waiting (see BLOCKERS.md) · ⬜ todo

## Phase status

| # | Phase | Status | Notes |
|---|---|---|---|
| 1 | Setup (tools, logins, repo, hooks) | 🔄 | Supabase login, keystore and faucet are ⏳ B1–B3 |
| 2 | REA research | ✅ | `docs/research/notes.md` |
| 3 | Monorepo foundation & environments | 🔄 | |
| 4 | Landing + wallet + swap | ✅ | Smart-route swap via router.quote |
| 5 | Core contracts (hub, hook, router, positions) | ✅ | 181 forge tests green (all modules) |
| 6 | Indexer & data pages | ✅ | `indexer` + `api` Edge Functions verified on testnet and on a local fork with real activity |
| 7 | Launchpad & stock pools | ✅ | Contracts + UI (launch list/create/trade, oracle panel) |
| 8 | DAMM/DLMM, limit orders, credit, buyback | ✅ | Contracts + UI |
| 9 | UI modification (style guide → tokens, 2 themes) | ✅ | Tokens + 2 themes; Playwright dark/light screenshots in `docs/ui-style/screens/` |
| 10 | Testnet deploy | ✅ | https://aethra-fi-testnet.vercel.app live: contracts on 46630, hosted indexer + API, Vercel Git deploys from `testnet` |
| 11 | Mainnet dry run (no broadcast) | ⬜ | optional per the user (2026-10-22) |

## Setup checklist

- ✅ `.claude/settings.json` written
- ✅ Node 24.16, pnpm 11.9, Foundry 1.8.3, Vercel CLI 59.19, gh 2.97, Docker 29.9 (running), Chrome 156
- ✅ Supabase CLI 2.121.0 installed to `~/.local/bin`
- ✅ `gh` logged in (`rubengitdev`, ADMIN on `Aethra-Fi/Aethra-Fi`)
- ✅ `vercel whoami` = `rubencahyadi504-9120`
- ✅ git identity `rubengitdev <rubencahyadi504@gmail.com>`
- ⏳ Supabase login (B1)
- ⏳ `deployer` keystore (B2)
- ⏳ testnet ETH (B3)
- ✅ Chain IDs verified with `cast chain-id`: testnet 46630, mainnet 4663
- ✅ Uniswap v4 PoolManager `0x8366…0951` has code on **both** testnet and mainnet
- ✅ CREATE2 deployer, Multicall3 and Permit2 exist on both chains
- ✅ Git: `git init -b main`, remote `origin` added, remote `main` (LICENSE only) pulled in without force
- ✅ Hooks `.githooks/commit-msg` + `pre-push`, `core.hooksPath` set, commit-msg tested

## Decisions log (one line each)

- 2026-10-22: Moved `ui-reference/` → `docs/ui-reference/` and the user-provided logo → `docs/brand/aethra-logo.svg` (CLAUDE.md expects `docs/ui-reference`).
- 2026-10-22: Use the user-supplied Aethra logo (lime→teal mark) as the brand mark; teal from the logo becomes the secondary accent.
- 2026-10-22: Fonts Geist + Geist Mono (OFL) as open-source equivalents of the reference grotesk/mono pairing.
- 2026-10-22: Build our own thin v4 periphery (router, positions) on the canonical PoolManager. Testnet has many third-party v4 peripheries and none is clearly canonical.
- 2026-10-22: v4 pools use ERC-20 WETH, never native ETH. The router wraps and unwraps, which keeps every venue ERC-20 only.
- 2026-10-22: Registries and config merged into one `AethraHub` proxy to save deploy gas. Lenses live off-chain (SDK/indexer).
- 2026-10-22: One combined v4 hook (dynamic fee + oracle guard, chosen per pool), so CREATE2 mining happens once.
- 2026-10-22: Fees use pips (1e-6) everywhere, matching v4.
- 2026-10-22: Router is exact-input only, across all venues. Best-route search happens in the SDK via `router.quote` over eth_call.
- 2026-10-22: Testnet stock pools use the existing testnet stock tokens (AMZN/TSLA/AMD/PLTR/NFLX) plus Aethra mock price feeds. We also deploy faucet test tokens so anyone can try the app.
- 2026-10-22: AethraHook `beforeInitialize` only lets the launchpad initialize pools containing a launch token (blocks graduation front-running at a skewed price).
- 2026-10-23: Landing switched to vertical full-page sections with native continuous scrolling. Snapping is a settle-after-stop in JS, not CSS `scroll-snap`: CSS proximity snapping pulled the page back after each mouse-wheel notch near an edge.
- 2026-10-23: Landing redesigned as one horizontal page (8 sections) with a single WebGL glyph ribbon (three.js 0.171.0, ~5.3k instanced glyphs) that morphs per section; footer hidden on `/`.
- 2026-10-22: Supabase testnet project already existed in ap-northeast-1 (created by the user); kept as is, noted as B5.
- 2026-10-22: Vercel preview env (all branches) points at testnet; production (`mainnet` branch) points at the prepared mainnet API.
- 2026-10-22: Credit (vault + manager) deploys in `DeployCredit.s.sol` after `SetupMarkets`, because the default vault asset `aUSD` is created there; `VAULT_ASSET` overrides it (required on mainnet).
- 2026-10-22: Web ABIs now come from the SDK (generated from forge artifacts); hand-written partial ABIs removed.
- 2026-10-22: `@x402/*` optional deps of `@coinbase/cdp-sdk` (via RainbowKit Base Account) aliased to an inert stub so Next/Turbopack builds.
- 2026-10-22: Worked sequentially in session 2 (no subagents) per the user; worktree branches merged into `main` and removed.
- 2026-10-22: Foundry `via_ir`, optimizer 800 runs, `bytecode_hash=none`, solc 0.8.26, evm cancun.

## Mainnet cost estimate (updated as contracts are added)

Reference: mainnet gas price 0.02 gwei (2026-10-22), ETH ≈ $2,410. Budget $6–7 ≈ 0.0025–0.0029 ETH ≈ 125–145M gas at that price.

| Contract | Est. gas | Est. USD | Status |
|---|---|---|---|
| Core: hub, positions, router, hook (impl + proxies, CREATE2 hook) | ≈ 14.8M | ≈ $0.71 | measured on fork |
| DLMM: pool impl + beacon, factory, limit orders | ≈ 7.4M | ≈ $0.36 | measured on fork |
| DAMM: pool impl + beacon, factory | ≈ 5.1M | ≈ $0.25 | measured on fork |
| Launchpad + LaunchToken impl | ≈ 5.0M | ≈ $0.24 | measured on fork |
| AETH + buyback | ≈ 2.7M | ≈ $0.13 | measured on fork |
| Credit: lending vault + credit manager | ≈ 7.0M | ≈ $0.34 | measured on fork |
| Wiring (registrars, fee config, setCreditManager) | ≈ 0.4M | ≈ $0.02 | measured on fork |
| **Total protocol (L2 execution only)** | **41.6M** | **≈ $2.00** | within $6–7 before L1 data; re-measure with L1 component in final dry run |

Test-market seeding (`SetupMarkets`, faucet tokens, mock feeds, seed pools) is 10.5M gas and is local/testnet only; it is not part of the mainnet deploy.

## Session 2 (2026-10-22): resume here

- ✅ All contract modules merged and tested on `main`: DLMM (pool, factory, limit orders), DAMM, launchpad + LaunchToken + AETH, LendingVault + CreditManager, Buyback. **181 forge tests green.**
- ✅ Frontend foundation committed (tokens, UI kit, wallet/RainbowKit, data layer, ABIs); typecheck and 26 vitest tests green.
- ✅ Supabase schema committed (migrations, shared indexer helpers).
- ✅ All 18 app routes built (landing, swap, pools, pool detail, create pool, positions, launch, launch token, credit, orders, analytics, events, buyback, contracts, developers). `next build`, lint, typecheck, 26 vitest + 10 Playwright tests green.
- ✅ `Deploy.s.sol` deploys every module; `DeployCredit.s.sol` adds credit; full local deploy (`scripts/local-deploy.sh`) verified on the Anvil fork.
- ✅ Testnet contracts deployed by the user via `scripts/testnet-deploy.sh` (77/77 tx ok, 0.00052 ETH gas); verified owners, registrars, wiring and a live router quote.
- ✅ Edge Functions `indexer` + `api` written; local Supabase run against real testnet (4 pools, TVL $26.4k, matches seeds) and against the Anvil fork with real activity from `scripts/local-activity.sh` (7 pools, swaps on every venue, filled limit order, launch at 28%, loans). Live-data screenshots checked.
- ✅ Fixed during integration: L1-vs-L2 `startBlock`, v4 liquidity amounts, launch threshold meta overwrite, analytics response shape, per-network indexer badge.
- ✅ Vercel project `aethra-fi` created with env vars; PR #1 merged `main` → `testnet`.
- ✅ Hosted Supabase testnet live: migrations, Edge Functions, Vault + pg_cron indexing every minute; public API returns TVL $26,424 and correct modes. Mainnet project prepared (idle).
- ✅ Vercel Git connected (production branch `mainnet`), `aethra-fi-testnet.vercel.app` → `testnet`, preview protection off; live site verified in a headless browser (4 pools from the hosted API, no errors). PR #3 promoted `main` → `testnet`.
- ⏳ Next: in-app faucet + deeper WETH/aUSD liquidity (testnet usability), then mainnet dry run.

## Session 1 checkpoint (2026-10-22): resume here

**Done and committed on `main` (pushed through `5dca465`; later commits are local only):**
- Hub, VolatilityFee, AethraHook (dynamic fee, oracle guard, circuit breaker, protocol fee), AethraRouter, AethraPositions (lock + vesting). **41 forge tests green.**
- `script/Deploy.s.sol` (hook CREATE2 salt mining) and `script/SetupMarkets.s.sol` (faucet tokens, mock feeds, seeded v4 pools). Both verified on an Anvil fork.
- SDK: chains, addresses, ABI export (`pnpm --filter @aethra/sdk abis`), smart-route finder, price/bin math. 9 vitest tests green.
- Mainnet dry run of the core alone: 16.86M gas ≈ 0.00034 ETH ≈ $0.81 at 0.02 gwei and $2,410/ETH. **This does not include the Arbitrum L1 data component.** The final dry run must re-estimate it with `eth_estimateGas` / NodeInterface `0xC8`.

**Interrupted when the usage limit hit. Partial work, not merged:**
- DLMM (worktree branch `worktree-agent-aa246c9a9e7c8c004`): pool tests passing; factory and limit-order tests remain.
- DAMM + launchpad + AETH (branch `worktree-agent-a1dacfba25f294e94`): builds; tests remain.
- Credit + buyback (branch `worktree-agent-ae73c95a62f9dff7b`): barely started.
- Frontend `apps/web/` (uncommitted, on disk): scaffold underway.
- Supabase `supabase/` (uncommitted, on disk): migrations and indexer underway.

**Next steps:**
1. Review and finish each worktree branch, then merge it into `main`.
2. Review, build and commit `apps/web` and `supabase`.
3. Extend `Deploy.s.sol` with the modules.
4. Vercel / Supabase hosted setup (after B1).
5. Testnet deploy (after B2/B3).
6. Final mainnet dry run.

## 2026-10-26 · Bugfix batch 2

- Header: connect button label is "Connect wallet".
- Pools: `pool_overview.sparkline` now returns 24 hourly points with the last close carried forward, plus `volume_sparkline` (migration `20261026000001_pool_sparkline.sql`). The sparkline draws an area fill, volume bars and an end marker; a series that never moves draws a dashed mid line. Pool detail chart pads its y range so small moves show. Testnet pools have no trades yet, so their price is genuinely constant until swaps happen.
- Docs: `/docs` page, linked from a new "Resources" footer column.
- Hidden for a later release: launchpad, credit, buyback & burn.
  - Web: `NEXT_PUBLIC_FEATURES=launchpad,credit,buyback` turns them back on (`apps/web/src/lib/features.ts`). Routes return 404, nav, landing sections, filters, event types and contracts page entries are dropped.
  - API: function secret `FEATURES` does the same; launch pools, launch/loan/buyback events and the `launches`, `loans`, `buybacks` endpoints are off by default.
  - Contracts: sources and tests stay. `Deploy.s.sol` no longer deploys launchpad, AETH or buyback and sets the hub protocol fee share to 0 (buyback unset). `DeployCredit` moved to `script/deferred/`, with a new `DeployLaunchpadBuyback` there (see its README). `scripts/testnet-deploy.sh` is now 3 steps.
  - SDK addresses: the five hidden addresses moved from the top level of `local.json` and `testnet.json` to a `hidden` object, so every consumer sees `null`.
  - Mainnet dry run: cost estimate drops because three modules are no longer deployed (re-run to get the new number).
