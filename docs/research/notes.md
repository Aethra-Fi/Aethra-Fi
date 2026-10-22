# Research notes: the reference liquidity layer on Robinhood Chain

How these notes were made: REA (`rea-agents@6.7.0`) ran `inspect-web-page` against a headless Chrome over local CDP on the landing page and on `/app` (accessibility tree, network requests, JSON body *shapes* only, storage key names). Contract interfaces came from two places: verified ABIs on Blockscout where they exist, and REA `inspect-evm-interface` (evmole) run on on-chain bytecode, with selectors resolved through the openchain signature DB.
Source code and bundles were **not** read or copied. Everything below describes behavior, in my own words. Raw captures live in the session scratchpad and are not committed.

Captured 2026-10-22, Robinhood Chain mainnet (4663), block ≈ 26.0M.

---

## 1. Product surface

**Landing page:** a single long scroll with these sections, in order:
1. Hero ("liquidity layer for Robinhood Chain")
2. Ecosystem (four numbered value props)
3. Markets (launchpad tokens, stock tokens, RWAs, DeFi integrators)
4. A routing diagram: a quote request that checks the registry, reads the launchpad lifecycle, compares venues and returns route metadata
5. An architecture section ("one router, many liquidity primitives")
6. A searchable contracts table
7. A closing CTA

**App (`/app`):** a single page with a left sidebar of tabs (Overview, DAMM, Pools Discovery, DLMM, Positions, launchpad Markets, Stock Tokens, Contracts, Buyback & Burn, Analytics, Developers) and a top bar with the chain badge and a Connect Wallet button. The Overview tab shows:
- Hero stats: active pools, registered assets, target network, indexer state.
- A scrolling **asset ticker**. Each asset is tagged CANONICAL (WETH, USDG), ORACLE GUARDED (AAPL, AMZN, GOOGL, MSFT, NVDA, TSLA, META, AMD, PLTR, INTC, COIN, NFLX, CRM, SHOP, SNAP, BA) or DYNAMIC (launchpad tokens).
- A **swap / deposit card**:
  - Token in and out selectors, with 25/50/75/MAX quick-fill buttons.
  - Route type (DIRECT or multi-hop), fee tier, minimum received, slippage presets (0.1, 0.5, 1.0%) and network cost.
- **Pools discovery** with filter chips: All, Trending, Established, Most Traded, Highest Volume, Fresh/New, Launchpad memes. Search covers symbol, name, contract and pool ID. Each pool row links to `/app/pools/{poolIdOrAddress}?action=swap|position`.
- **Featured market** card: pair, fee, ID, 24h swaps.
- **Stock token & oracle pools** table with these columns: reference price, pool price, deviation, liquidity, 24h volume, current fee, market session, oracle updated, multiplier, risk state.
- **Event feed** of live route and market events (swaps, with timestamps).
- **Positions:** ERC-721 LP positions plus a locker, and an empty state when there are none.
- **Contracts:** 64 entries in categories (Core & Config, v4 Hooks & Fees, Smart Router, Positions & Vaults, Venue Adapters, External), each with a copy button and an explorer link.
- **Footer:** links to landing, contracts, SDK, API and pools, plus an explicit "not affiliated with Robinhood" line.

**Wallet stack:** WalletConnect AppKit on top of wagmi. localStorage keys were `wagmi.store` and `@appkit/*`.

## 2. Backend API (observed shapes)

| Endpoint | Purpose | Shape (fields) |
|---|---|---|
| `GET /v1/health` | indexer liveness | `status, service, database, timestamp, supportedChains[], indexing{status,last_indexed_block,last_indexed_hash,updated_at}` |
| `GET /v1/chains/{id}/pools` | registry of pools | `data[]`. See the pool record below. |
| `GET /v1/chains/{id}/dashboard` | precomputed lists for the filter chips | `data{chainId,timestamp,featured,all[],trending[],established[],mostTraded[],highestVolume[],fresh[]}`. Each item is a pool record plus `token0/1{address,symbol,name,decimals,logo_url}, volume24h, tradeCount24h, priceChange24h, sparkline[], isFresh` |
| `GET /v1/chains/{id}/events?limit=N` | swap feed | `data[]{pool_id,tx_hash,log_index,block_number,sender,recipient,token_in,token_out,amount_in,amount_out,fee_amount,created_at}` |
| `POST /api/rpc` | same-origin JSON-RPC proxy | used for `eth_getLogs` and similar calls, which keeps RPC keys off the client |

**Pool record fields:**
- Identity: `pool_id, market_id, pool_type, pool_address, venue, venue_id, venue_type, protocol, protocol_version, is_external, provenance_verified`
- Tokens and hook: `currency0/1, hooks`
- Fees: `fee, fee_tier, tick_spacing, fee_collection_mode`
- Fee schedule: `fee_schedule_kind, fee_schedule_start_bps, fee_schedule_end_bps, fee_schedule_start_time, fee_schedule_end_time`
- Dynamic fee: `max_fee_bps, variable_fee_control_bps, volatility_accumulator, max_volatility_accumulator, volatility_decay_period`
- DLMM state: `active_bin_id, bin_step_bps`
- Launch and lifecycle: `one_sided_launch, sqrt_price_initial/min/max_x96, quote_token, initialized_onchain, is_enabled, created_at, updated_at`

**Takeaways:**
- One normalized "pool" table covers every venue: v4 hook pools, DLMM, DAMM and external pools.
- Filter lists are computed on the server.
- The indexer exposes its own block cursor.

## 3. On-chain architecture (interfaces only)

All core contracts are ERC-1967 proxies; `cast implementation` returns an implementation for each. Solidity 0.8.26 / 0.8.x. One EOA deployer.

| Component | What it does (from its interface) |
|---|---|
| **ProtocolConfig** | Central config and roles. Every contract has `setProtocolConfig` / `protocolConfig()`. |
| **AssetRegistry** | Allow-list of tokens, each with an asset class (canonical / stock / launchpad / RWA): `getAssetConfig`, `getAssetClass`, `isAssetEnabled`, `getRegisteredTokens`. |
| **OracleRegistry** | Maps token → oracle: `setOracle`, `getOracle`, `getPrice`. |
| **PoolRegistry** | Allow-list of pools by `bytes32` id: `getPoolConfig`, `enablePool`/`disablePool`, `getAllPools`, `getPoolCount`. |
| **DynamicFeeHook** (v4 hook) | Implements initialize/add/remove/swap/donate callbacks. Writes fees in `afterSwap` and `afterInitialize`. Has a creator fee cap (`MAX_CREATOR_FEE_BPS`). The UI labels it "0.05%". |
| **DynamicFeeController** | Per-pool fee config: base fee, max fee, volatility decay period, default/hard max fee. Has observers that feed it volatility. |
| **OracleGuardHook** (v4 hook) | For stock-token pools. Base swap fee (UI: 0.30%), hard max fee, and a per-pool **circuit breaker** (`isCircuitBreakerTripped`, `resetCircuitBreaker`) that trips on pool vs oracle deviation and market session. |
| **PositionManager** | ERC-721 LP NFT: `increaseLiquidity`, `decreaseLiquidity`, `collectFees`, `burn`, `getPosition`, `setLockState`, and authorized updaters that push accrued fees. |
| **LiquidityLocker** | Locks an NFT position with optional **vesting schedules** (several per position): `getLockInfo`, `isLocked`, `unlockPosition`, `getVestingSchedule`. |
| **SmartRouter + Quoter + AdapterRegistry** | Router dispatches through venue **adapters**: UniswapV4, UniswapV3, WETH wrap, launchpad v2, DLMM, DAMM. The quoter compares venues with `quoteExactInput(tokenIn, tokenOut, amountIn)`. |
| **DLMM** (factory + pools) | Discrete-bin liquidity in the style of Liquidity Book: `binStepBps`, `activeBinId`, per-bin shares and fees. The variable fee comes from a volatility accumulator with a decay period. Has a TWAP observation ring (`observe`, `consult`) and a fee schedule (start/end bps over time, for launches). Swaps are bounded by `maxBins`. |
| **DLMM LimitOrderManager** | Single-bin limit orders: `place(pool, binId, side, amount, minShares, deadline)`, `reduce`, `cancel`, `claim`, `claimableOutput`, `status`. An order fills as the active bin crosses it. |
| **DAMM** (factory + pools) | Dynamic AMM pools with fungible shares: `addLiquidity`, `removeLiquidity`, `swapExactInput`/`swapExactOutput`, `quoteExactInput`/`quoteExactOutput`, `feeGrowthGlobal*`, `claimFees`. Two modes: *concentrated* (sqrtPrice range) and *one-sided* (single-token launch). Has a dynamic fee and a time-based fee schedule, and reports `oracleHealth()`. |
| **Launchpad adapter** | Reads the external launchpad (the "Pons" factories): `isReadyToGraduate`, `getGraduatedPool`, `quoteExactInput`, `executeSwap`, a factory allow-list (`PonsFactoryRegistry`) and pausing. |
| **Credit stack** | `UsdgLendingVault` is an ERC-4626 vault over USDG with borrow index, reserve factor and supply/borrow caps. `KinkIRM` is a kinked utilization rate model (`utilization`, `borrowRatePerSecond`). `CreditManager` lets you `pledge(tokenId)` an LP NFT, then `borrow`, `repay`, `release`, with `getLoanHealth`, max LTV, liquidation threshold and liquidation incentive. Supporting contracts: `LpCollateralCustody`, a DLMM collateral adapter, a fee auto-repayer (LP fees repay debt) and a CreditLens. |
| **Buyback & burn** | `BuybackRevenueManager` receives protocol revenue from approved sources and splits it between buyback and treasury (`BUYBACK_BPS`/`TREASURY_BPS`). `BuybackExecutor` swaps through SmartRouter with an oracle sanity check and a cooldown (`lastExecutionTimestamp`), then sends to a `BurnAdapter`. Read through `BuybackLens`. |
| **FeeDistributor / ProtocolFeeVault** | Per-pool fee split configuration and the vault that receives the protocol's share. |

Canonical external contracts it reuses:
- **Uniswap v4 PoolManager** `0x8366a39CC670B4001A1121B8F6A443A643e40951`. Same address on testnet; I confirmed with `cast code`.
- **Mainnet:** WETH `0x0Bd7…AD73`, USDG `0x5fc5…d168`.

## 4. Testnet facts (46630)

- PoolManager has code at the same address on testnet. Plenty of third-party v4 periphery is deployed there (several PositionManager, V4Quoter and UniversalRouter instances), so none of them is clearly canonical. Decision: **build our own thin periphery on top of PoolManager**.
- **Official-looking test tokens**, about 230–300k holders each:
  - AMZN `0x5884…9E02`, TSLA `0xC9f9…Bd4E`, AMD `0x7117…778d`, PLTR `0x1FBE…98d0`, NFLX `0x3b82…3C93`, all 18 decimals
  - WETH `0x33e4…0B94`
  - USDC `0xbf44…275F` (18 decimals)
- **Mock tokens** also exist (USDG mock at `0x8F92…23BC` with 6 decimals, plus mAAPL, mNVDA and others). There is no reliable stock oracle on testnet, so stock pools use **our own mock oracle**.
- There is no launchpad factory we can rely on, so we ship our **own minimal launchpad** (bonding curve, then graduation into a v4 pool).

## 5. What Aethra Fi will do differently (own design)

- **Leaner contract set to fit the $6–7 mainnet budget.** Fewer separate contracts. Registries and config merge into one `AethraHub`. DLMM and DAMM pools are **BeaconProxy** clones. Lenses are off-chain (SDK/indexer) instead of deployed contracts.
- **One combined v4 hook** with both behaviors, chosen per pool through the registry: dynamic volatility fee, plus oracle guard (deviation fee and circuit breaker). One hook address means one CREATE2 mining step and one set of permission flags fixed from the start.
- **Indexer** on Supabase: `pg_cron` calls an Edge Function that pulls logs through RPC into Postgres. The API is Supabase Edge Functions with the same resource layout (`/health`, `/chains/:id/pools|dashboard|events`).
