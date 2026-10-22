# PROGRESS: Aethra Fi

Legend: ✅ done · 🔄 in progress · ⏳ waiting (see BLOCKERS.md) · ⬜ todo

## Phase status

| # | Phase | Status | Notes |
|---|---|---|---|
| 1 | Setup (tools, logins, repo, hooks) | 🔄 | Supabase login, keystore and faucet are ⏳ B1–B3 |
| 2 | REA research | ✅ | `docs/research/notes.md` |
| 3 | Monorepo foundation & environments | 🔄 | |
| 4 | Landing + wallet + swap | ⬜ | |
| 5 | Core contracts (hub, hook, router, positions) | 🔄 | Hub + VolatilityFee done with tests |
| 6 | Indexer & data pages | ⬜ | |
| 7 | Launchpad & stock pools | ⬜ | |
| 8 | DAMM/DLMM, limit orders, credit, buyback | ⬜ | |
| 9 | UI modification (style guide → tokens, 2 themes) | 🔄 | `docs/ui-style/style-guide.md` written |
| 10 | Testnet deploy | ⬜ | |
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
- 2026-10-22: Foundry `via_ir`, optimizer 800 runs, `bytecode_hash=none`, solc 0.8.26, evm cancun.

## Mainnet cost estimate (updated as contracts are added)

Reference: mainnet gas price 0.02 gwei (2026-10-22), ETH ≈ $2,410. Budget $6–7 ≈ 0.0025–0.0029 ETH ≈ 125–145M gas at that price.

| Contract | Est. gas | Est. USD | Status |
|---|---|---|---|
| (to be filled from `forge script` dry runs) | | | |
