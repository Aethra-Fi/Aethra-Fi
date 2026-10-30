# PROGRESS: Aethra Fi

Legend: ✅ done · 🔄 in progress · ⏳ waiting (see BLOCKERS.md) · ⬜ todo

## Phase status

| # | Phase | Status | Notes |
|---|---|---|---|
| 1 | Setup (tools, logins, repo, hooks) | ✅ | B1–B3 done |
| 2 | REA research | ✅ | `docs/research/notes.md` |
| 3 | Monorepo foundation & environments | ✅ | local, testnet live; mainnet prepared |
| 4 | Landing + wallet + swap | ✅ | Smart-route swap via router.quote |
| 5 | Core contracts (hub, hook, router, positions) | ✅ | 181 forge tests green (all modules) |
| 6 | Indexer & data pages | ✅ | `indexer` + `api` Edge Functions verified on testnet and on a local fork with real activity |
| 7 | Launchpad & stock pools | ✅ | Contracts + UI (launch list/create/trade, oracle panel) |
| 8 | DAMM/DLMM, limit orders, credit, buyback | ✅ | Contracts + UI |
| 9 | UI modification (style guide → tokens, 2 themes) | ✅ | Tokens + 2 themes; Playwright dark/light screenshots in `docs/ui-style/screens/` |
| 10 | Testnet deploy | ✅ | https://aethra-fi-testnet.vercel.app live: contracts on 46630, hosted indexer + API, Vercel Git deploys from `testnet` |
| 11 | Mainnet dry run (no broadcast) | ✅ | 2026-10-30: full release (all modules) 42.1M gas ≈ $1.89, within $7. Broadcast by the user (B13) |

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

- 2026-10-30: Compiler keeps the CBOR metadata hash (`bytecode_hash = "ipfs"`, `cbor_metadata = true`). Without it the explorer can only show "verified (partial match)" with a "Verify & publish" prompt. `auto_detect_remappings = false` (remappings.txt only) keeps absolute local paths out of the published metadata. Testnet is redeployed with it (user's choice, B15). Mainnet cost +$0.04.

- 2026-10-30: Mainnet owner = deployer `0xd09D…9a7C` (user's choice), no Safe for now. All modules deploy; launchpad, AETH + buyback and credit are locked on-chain.
- 2026-10-30: Mainnet stablecoin = USDG `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` (Global Dollar, 6 decimals, admin-verified on the explorer). Vault asset and CANONICAL asset.
- 2026-10-30: Mainnet stock tokens TSLA, NVDA, AAPL ("• Robinhood Token", checked with name()/symbol() on-chain) registered as STOCK, enabled=false. Other stock tokens are not registered yet: a pool with one of them would start in DYNAMIC mode.
- 2026-10-30: AETH holder = deployer. No mainnet seed liquidity until a top-up (user's choice).
- 2026-10-30: Testnet mock feeds (stocks included) use a 365 day staleness window. With 1 day, every stock pool halted a day after seeding because nobody updates the mock feeds.
- 2026-10-30: Explorer verification uses Blockscout (forge verify-contract). The mainnet explorer API is behind Cloudflare and refuses this machine's IP (HTTP 403): run with a VPN, or `VERIFIER=sourcify`.

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

## 2026-10-31 · Mainnet readiness: verification path, rehearsal, indexer

- The mainnet Blockscout API refuses every command-line client: HTTP 403 Cloudflare browser challenge, also with the user's VPN (Cloudflare WARP IP). The web pages load and the testnet explorer is open. Neither forge nor curl can verify there.
- Sourcify (chain 4663 supported) verifies the same package and forwards it to the explorer from its own servers. Proven on testnet:
  - three mock feeds verified through Sourcify only (`exact_match`) appear on the testnet Blockscout as verified (exact match);
  - the license shows as none on this path.
- `verify-contracts.sh` gained `VERIFIER=sourcify` (Sourcify v2 API: submit, poll, read back) and uses it by default on mainnet. The manifest now carries the creation transaction hash. End-to-end run on testnet: 2 new contracts verified, 1 already verified, all exact match.
- The forwarding to the **mainnet** explorer can only be shown on mainnet: `scripts/mainnet-verify-probe.sh` deploys a 377-byte `VerificationProbe` from its explorer package bytecode (rehearsed on a fork, 126k gas), verifies it through Sourcify and prints the explorer link (B17).
- Mainnet release rehearsed on a fork with chain id 4663: `deployAll` broadcast, `set-start-block`, SDK build, `verify-prepare mainnet` gives 28/28 small packages. Web unit tests and a production (mainnet) build pass with the addresses filled in.
  - Fixed an e2e test that assumed testnet as the default network.
  - All fork traces were removed and `mainnet.json` restored.
- Supabase mainnet brought up to date:
  - migration `20261026000001_pool_sparkline` applied;
  - `api` and `indexer` functions redeployed from the current code;
  - `INDEXER_TOKEN` function secret and Vault secrets `project_url` / `indexer_token` set; cron active.
  - Cron to indexer returns HTTP 200 `skipped: no deployment`. After B13 only `sync-deployments.mjs mainnet` is left.
- Vercel production env checked: `NEXT_PUBLIC_NETWORK`, `NEXT_PUBLIC_API_URL` and `NEXT_PUBLIC_SITE_URL` are set. The `mainnet` branch is promoted after B13.

## 2026-10-30 · DLMM/DAMM invariants and mainnet verification proof

- `test/damm/DAMM.invariant.t.sol` covers a concentrated-range pool with a launch fee and a 20% protocol share, through random add, remove, swap, fee claim, protocol fee collection and time steps. Invariants:
  - token balances ≥ reserves + fees owed to LPs + protocol fees;
  - shares + MIN_LIQUIDITY = liquidity;
  - price stays inside the range;
  - reserves can pay out the curve to either edge.
  Result: 256 runs × 500 calls, all pass. `afterInvariant` checks that swaps and removals really happened.
- `test/dlmm/DLMM.invariant.t.sol` covers random add (shaped bins), remove, share transfer, swap, limit order place, claim and cancel, protocol fee collection and time steps. Invariants:
  - token balances ≥ bin reserves + protocol fees;
  - bins below the active bin hold no token0 and bins above hold no token1;
  - bin shares add up (at most MIN_SHARES unowned);
  - the limit order contract owns exactly the shares of its open orders.
  Result: 128 runs × 200 calls, all pass, on the forge build and on `verifiable/DLMMPool.bin` (`DLMM_VERIFIABLE=1`), the bytecode that testnet and mainnet deploy. Default config is 64 × 100 to keep pre-push fast.
- Release plan gate 6 (DLMM/DAMM invariants) is done.
- Mainnet verification proven before broadcast: `VERIFY_DRY_RUN=1 node scripts/verify-prepare.mjs mainnet` gives 28/28 contracts with small source packages that reproduce the dry-run bytecode including the metadata hash, with no local paths. `mainnet-deploy.sh --broadcast` prepares the real packages right after the broadcast.
- Mainnet dry run 2026-10-30: 55.06M gas limit = 0.0011190 ETH = $2.49 (0.020324 gwei). Deployer balance 0.002964 ETH.

## 2026-10-30 · Faucet, testnet liquidity, mainnet release scripts and final dry run

- Web: `/faucet` page (testnet and local only; hidden from the nav on mainnet). Claims each Aethra test token once a day (`faucet()`, cooldown shown), wraps and unwraps ETH, links the Robinhood Chain ETH faucet. Dark and light screenshots in `docs/ui-style/screens/faucet-*.png`.
- Found: every testnet stock pool was halted. The mock stock feeds had a 1 day staleness window and were last updated 2026-10-22, so the hook failed closed (quotes returned 0).
- `script/testnet/DeepenLiquidity.s.sol` + `scripts/testnet-liquidity.sh`: refreshes all mock feeds with a 365 day window, adds full-range v4 liquidity (0.003 WETH on WETH/aUSD, 400 tokens on each stock pool ≈ $250k), opens DLMM aTSLA/aUSD (21 bins) and DAMM aNVDA/aUSD and aAAPL/aUSD. Rehearsed on a testnet fork: 1,000 aUSD to aTSLA quotes 3.95 aTSLA on v4, DLMM and DAMM quote correctly. Live run: 5.8M gas ≈ 0.00012 ETH. Broadcast by the user on 2026-10-30 (B11). Live: 7 pools, TVL ≈ $828k on the indexer, quotes on v4, DLMM and DAMM.
- Mainnet release: `script/DeployMainnet.s.sol` (`deployAll()`) = `Deploy` (core, DLMM, DAMM) + `GatedModules` (`script/DeployGated.s.sol`): assets, launchpad, AETH, buyback, lending vault (caps 0, no credit manager), credit manager. Writes `mainnet.json` only on a real broadcast. `scripts/mainnet-deploy.sh` runs the dry run and cost report, or with `--broadcast` checks the keystore first.
- Rehearsed on a mainnet fork: 38 transactions, 42,122,152 gas used. All 10 owned contracts are owned by the deployer. Launchpad `create` reverts `NotRegistrar`, a TSLA/USDG pool reverts at initialize, the vault has no credit manager, protocol fee share 0, and a WETH/USDG v4 pool initializes.
- **Final mainnet dry run (2026-10-30, no broadcast):** gas price 0.020046 gwei, ETH $2,233.62 (CoinGecko). L1 data component 0 (NodeInterface `gasEstimateL1Component`). Forge gas limits (estimate × 1.3) total 54.60M = 0.0010946 ETH = **$2.44**, an upper bound. Gas actually used on the fork: 42.12M ≈ 0.000844 ETH ≈ **$1.89**. **Within the $7 budget.** Deployer balance 0.00297 ETH. Forge needs about 0.00218 ETH up front (gas limit × 0.04 gwei max fee).

  | Module | Gas (forge limit) | ETH | USD |
  |---|---|---|---|
  | Core (hub, positions, router, CREATE2 hook, impl + proxy each) | 17.10M | 0.0003429 | $0.77 |
  | DLMM (pool impl + beacon, factory, limit orders) | 10.15M | 0.0002035 | $0.45 |
  | DAMM (pool impl + beacon, factory) | 7.02M | 0.0001407 | $0.31 |
  | Launchpad + LaunchToken impl | 7.04M | 0.0001411 | $0.32 |
  | AETH + buyback | 3.85M | 0.0000772 | $0.17 |
  | Credit (vault + credit manager) | 9.16M | 0.0001836 | $0.41 |
  | Wiring (registrars, fee config, 5 assets, caps) | 0.28M | 0.0000057 | $0.01 |
  | **Total** | **54.60M** | **0.0010946** | **$2.44** |

- Verification: `bash scripts/verify-contracts.sh <testnet|mainnet>` verifies every deployed contract on Blockscout from the broadcast records (`scripts/verify-list.mjs` matches each creation against the local build), checks the explorer API, and writes `docs/verification/<network>.md`. Output shows names, addresses and explorer links, never local paths. Testnet: 32 contracts (the 3 implementations replaced on 2026-10-30 are skipped). One verification was tested on testnet (aUSD mock feed `0xCD07…aEd2`, not in the list).
- 190 forge tests, 9 SDK and 32 web unit tests, 14 Playwright tests pass; lint and typecheck clean.
- Verification hardened before recording:
  - `forge verify-contract` would have failed for the testnet DLMM pool. With via-IR, its bytecode depends on which files are compiled together, and forge submits a minimal set.
  - The forge path also risked publishing absolute local paths (remappings in build-info).
  - `scripts/verify-prepare.mjs` now builds one source package per contract and proves it with solc 0.8.26: creation code must equal the broadcast bytes. It strips local paths and shrinks build-info packages: the explorer gave up on a 172-file package (164 s compile), while the DLMM package is now 138 files (13 s).
  - `verify-contracts.sh` submits those packages through the Blockscout API with a spinner, reads every contract back as proof, and opens explorer links on request.
  - Testnet: 32/32 packages proven. DLMM pool implementation verified for real as the end-to-end test (no local path in the published sources).
  - Mock feeds verified while testing the script: aUSD, WETH, aTSLA, AMZN, PLTR (old testnet, partial match).
- Exact match: every contract deployed so far lacked the metadata hash, so the explorer could only give "partial match" (screenshot check: DLMM pool page showed "verified (partial match)" + "Verify & publish"; WETH, which has metadata, shows "verified (exact match)").
  - Metadata hash is now on, and auto-detected remappings are off so no local path reaches the metadata.
  - `scripts/testnet-redeploy.sh` does a fresh testnet with one password prompt: Deploy, SetupMarkets, DeployGated (testnet now has the same gated modules as mainnet), DeepenLiquidity, start block, SDK build, verification packages.
  - Rehearsed on a fork (chain id 31337): 58.9M gas. All 32 verification packages reproduce the deployed bytes including the metadata hash.
  - The verify script now reads the match type back from the explorer ("exact match" / "partial match") and sends the MIT license.
  - Testnet redeployed by the user (B15): 117 transactions, all succeeded. Addresses equal the fork rehearsal. Indexer rows of the old deployment deleted, new deployment synced: 7 pools, TVL ≈ $828k. Exact match proven on the new aUSD mock feed `0x631b…a4c2` (not in the recording list). 32 verification packages ready.
  - First recording run on the redeployed testnet: 31/32 exact match. "Unknown UID" rows had succeeded: the explorer lost the status ticket. DLMM pool implementation failed: its deployed bytecode (compiled inside the whole project, via-IR) is only reproducible with a ~160-file package that compiles in 67 s, and the explorer gives up. Fix:
    - `scripts/build-verifiable.mjs` compiles DLMMPool from its small explorer package (17 files, 2 s) to `packages/contracts/verifiable/DLMMPool.bin`. `Deploy.s.sol` deploys that bytecode on testnet and mainnet, so the deployed code is the verified code by construction.
    - `verify-prepare.mjs` now only accepts the small package. A mismatch stops the run instead of falling back to a heavy package.
    - `verify-contracts.sh` treats the contract page as the source of truth when the status ticket is lost.
    - Fork rehearsal: 32/32 small packages match. Mainnet dry run: $2.51 upper bound. The user redeployed testnet once more (B16): 117 transactions, all succeeded, 32/32 small packages match. Indexer re-synced.
  - B12 recorded by the user: all 32 testnet contracts verified, exact match with the MIT license (checked through the explorer API). Links: `docs/verification/testnet.md`.
  - Mainnet dry run with metadata: 55.05M gas limit = 0.0011210 ETH = $2.48 at 0.020364 gwei and $2,212.93 (upper bound). Within budget.

## 2026-10-30 · Router + hook security review

- Baseline re-verified: 181 forge tests, 9 SDK and 26 web vitest tests pass.
- Findings were proven first with PoC tests, then fixed. Regression tests: `packages/contracts/test/security/RouterHookAudit.t.sol`. 190 forge tests pass.
- Router R-1 (High) fixed: non-v4 hops must name the contract the hub registered for that id and venue; `quote` checks the same.
- Router R-2 (Medium) fixed by R-1 (no fake `RouteExecuted`).
- Router R-3 (Low) fixed: allowance reset to 0 after each hop.
- Hook H-1 (Medium) fixed: `ORACLE` pools revert at initialize if the oracle is not fresh or the opening price is outside `maxDeviationBps`. STOCK assets that are not enabled cannot be pooled (`AssetNotEnabled`).
- Hub H-2 (Low) fixed: `setAsset` reverts `InvalidStaleness` when an oracle is set with `maxStaleness == 0`. `SetupMarkets` mock feeds now use 365 days.
- SDK ABIs regenerated (hub, hook). The testnet contracts were upgraded to the fixed implementations (see below).
- Mainnet dry run 2026-10-30 (VPN on): core + DLMM + DAMM = 26.23M gas, 0.000545 ETH, about $1.27 at 0.02076 gwei and $2,337.31/ETH. L1 component 0. Not broadcast.
- Release model: deploy everything, gate hidden modules on-chain, reveal in order. See `docs/RELEASE_PLAN.md`.
- Upgrade tooling added: `bash scripts/snapshot-build.sh <git-ref> <name>` saves the build of the deployed code, `bash scripts/upgrade.sh <network> <contract(s)> <name> [--broadcast]` validates storage layout and upgrade safety, deploys the new implementation, and upgrades (testnet, deployer owns the proxy) or prints Safe calldata (mainnet). Validated and simulated against live testnet state for all 13 targets. A field inserted into the hub storage struct is rejected.
- Testnet upgrade rehearsal (opt-in fork test `FORK_TESTNET=1 forge test --match-path test/fork/TestnetUpgrade.t.sol`): quotes of all registered pools are identical before and after, a real WETH swap works, hub state survives. Estimated cost 0.00022 ETH. Executed 2026-10-30 (B10 done): 6 transactions succeeded, 8.35M gas, implementation slots of hub, hook and router read back as the new addresses.
- Web: Testnet / Mainnet toggle in the header (saved in the browser, switches the wallet chain too). The mainnet button is disabled until `addresses/mainnet.json` has a hub; a banner warns when the active network has no deployment. API and RPC per network, overridable with `NEXT_PUBLIC_API_URL_{TESTNET,MAINNET}` and `NEXT_PUBLIC_RPC_URL_{TESTNET,MAINNET}`. 32 web unit tests and 2 e2e tests for the toggle.

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
