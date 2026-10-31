import type { Address, Hex } from "viem";

/** Mirrors `Venue` in packages/contracts/src/interfaces/IAethraHub.sol. */
export enum Venue {
  NONE = 0,
  V4 = 1,
  DLMM = 2,
  DAMM = 3,
  LAUNCH = 4,
}

/** Mirrors `AssetClass` in IAethraHub.sol. */
export enum AssetClass {
  NONE = 0,
  CANONICAL = 1,
  STOCK = 2,
  LAUNCH = 3,
  RWA = 4,
}

export interface PoolKey {
  currency0: Address;
  currency1: Address;
  fee: number;
  tickSpacing: number;
  hooks: Address;
}

/** Mirrors IAethraRouter.Hop. */
export interface Hop {
  venue: Venue;
  pool: Address;
  tokenIn: Address;
  tokenOut: Address;
  data: Hex;
}

/** Normalized pool record served by the indexer API (`/chains/:id/pools`). */
export interface ApiPool {
  pool_id: string;
  chain_id: number;
  venue: "V4" | "DLMM" | "DAMM" | "LAUNCH";
  pool_address: string | null;
  hooks: string | null;
  token0: ApiToken;
  token1: ApiToken;
  fee_pips: number;
  tick_spacing: number | null;
  bin_step_bps: number | null;
  active_index: number | null;
  sqrt_price_x96: string | null;
  mode: "dynamic" | "oracle" | "plain";
  creator: string | null;
  tvl_usd: number;
  volume_24h_usd: number;
  trades_24h: number;
  price_change_24h: number;
  /** 24 hourly closing prices, quiet hours carried forward */
  sparkline: number[];
  /** 24 hourly volumes in USD, aligned with `sparkline` */
  volume_sparkline?: number[];
  is_fresh: boolean;
  enabled: boolean;
  /** a Uniswap v4 pool outside Aethra's hook: listed read-only, not routable through the Aethra router */
  external?: boolean;
  created_at: string;
}

export interface ApiToken {
  address: string;
  symbol: string;
  name: string;
  decimals: number;
  kind: string;
  logo_url: string | null;
}

export interface ApiSwapEvent {
  chain_id: number;
  pool_id: string;
  venue: string;
  tx_hash: string;
  log_index: number;
  block_number: number;
  sender: string;
  recipient: string;
  token_in: string;
  token_out: string;
  amount_in: string;
  amount_out: string;
  fee_amount: string;
  amount_usd: number | null;
  timestamp: string;
}

export interface ApiDashboard {
  chain_id: number;
  timestamp: string;
  featured: ApiPool | null;
  all: ApiPool[];
  trending: ApiPool[];
  established: ApiPool[];
  most_traded: ApiPool[];
  highest_volume: ApiPool[];
  fresh: ApiPool[];
  launch: ApiPool[];
  stats: { tvl_usd: number; volume_24h_usd: number; trades_24h: number; pools: number; assets: number };
}

export interface ApiHealth {
  status: "ok" | "degraded" | "down";
  service: string;
  chains: number[];
  indexing: { chain_id: number; last_block: number; head_block: number | null; updated_at: string }[];
  timestamp: string;
}
