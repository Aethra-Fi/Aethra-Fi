import type { ApiDashboard, ApiHealth, ApiPool, ApiSwapEvent, ApiToken } from "@aethra/sdk";
import { API_URL, CHAIN_ID } from "./network";

export { API_URL };

export type { ApiDashboard, ApiHealth, ApiPool, ApiSwapEvent, ApiToken };

// API_URL (re-exported above) follows the active network; see lib/network.ts.

// ---------------------------------------------------------------------------
// Response types not (yet) in @aethra/sdk. The lead may move these into packages/sdk/src/types.ts.
// ---------------------------------------------------------------------------

export type EventType = "swap" | "liquidity" | "launch" | "order" | "loan" | "buyback";

/** Generic feed event. Swap rows from the indexer may arrive in ApiSwapEvent shape; see normalizeEvent. */
export interface ApiEvent {
  chain_id: number;
  type: EventType;
  name: string;
  pool_id: string | null;
  venue: string | null;
  tx_hash: string;
  log_index: number;
  block_number: number;
  actor: string | null;
  summary: string | null;
  amount_usd: number | null;
  data: Record<string, unknown>;
  timestamp: string;
}

export interface ApiLaunch {
  token: string;
  name: string;
  symbol: string;
  creator: string;
  metadata_uri: string | null;
  image_url: string | null;
  real_weth: string;
  real_token: string;
  virtual_weth: string;
  virtual_token: string;
  graduation_threshold: string;
  /** 0..1 */
  progress: number;
  graduated: boolean;
  v4_pool_id: string | null;
  price_weth: number | null;
  market_cap_usd: number | null;
  volume_24h_usd: number;
  trades_24h: number;
  holders: number | null;
  top_holders?: { address: string; balance: string; share: number }[];
  curve?: { t: string; price_weth: number }[];
  created_at: string;
}

export interface ApiAnalyticsPoint {
  t: string;
  tvl_usd: number;
  volume_usd: number;
  fees_usd: number;
}

export interface ApiAnalytics {
  range: AnalyticsRange;
  series: ApiAnalyticsPoint[];
  venues: { venue: ApiPool["venue"]; tvl_usd: number; volume_usd: number; fees_usd: number }[];
  top_pools: ApiPool[];
}

export type AnalyticsRange = "24h" | "7d" | "30d";

export interface ApiV4Position {
  token_id: string;
  owner: string;
  pool_id: string;
  pool: ApiPool | null;
  tick_lower: number;
  tick_upper: number;
  liquidity: string;
  locked: boolean;
  lock_cliff: number | null;
  lock_end: number | null;
  pledged: boolean;
  created_at: string;
}

export interface ApiDlmmPosition {
  pool_address: string;
  pool: ApiPool | null;
  bins: { id: number; shares: string }[];
}

export interface ApiDammPosition {
  pool_address: string;
  pool: ApiPool | null;
  shares: string;
}

export interface ApiPositions {
  v4: ApiV4Position[];
  dlmm: ApiDlmmPosition[];
  damm: ApiDammPosition[];
}

export type OrderStatus = "OPEN" | "PARTIAL" | "FILLED" | "CLOSED";

export interface ApiOrder {
  order_id: string;
  owner: string;
  pool_address: string;
  pool: ApiPool | null;
  bin_id: number;
  side: "SELL_TOKEN0" | "SELL_TOKEN1";
  amount_in: string;
  status: OrderStatus;
  tx_hash: string | null;
  created_at: string;
}

export interface ApiLoan {
  token_id: string;
  owner: string;
  debt: string;
  collateral_usd: number | null;
  health_factor: number | null;
  status: "ACTIVE" | "CLOSED" | "LIQUIDATED";
  opened_at: string;
}

export interface ApiBuybacks {
  aeth: string | null;
  total_burned: string;
  total_burned_usd: number | null;
  buyback_bps: number;
  treasury_bps: number;
  revenue: { token: ApiToken; amount: string; amount_usd: number | null }[];
  executions: {
    tx_hash: string;
    token_in: ApiToken | null;
    amount_in: string;
    aeth_bought: string;
    aeth_burned: string;
    to_treasury: string;
    timestamp: string;
  }[];
}

/** Optional oracle block on stock-token pools (mode === "oracle"). */
export interface ApiOracleState {
  reference_price_usd: number | null;
  pool_price_usd: number | null;
  deviation_bps: number | null;
  market_open: boolean | null;
  updated_at: string | null;
  fee_multiplier: number | null;
  risk: "NORMAL" | "ELEVATED" | "HALTED" | null;
}

export type ApiPoolWithOracle = ApiPool & { oracle?: ApiOracleState | null };

export interface ApiPoolDetail extends ApiPoolWithOracle {
  candles?: { t: string; open: number; high: number; low: number; close: number; volume_usd: number }[];
  price_series?: { t: string; price: number }[];
}

// ---------------------------------------------------------------------------

export class ApiError extends Error {
  constructor(
    message: string,
    public status: number | null,
    public offline: boolean,
  ) {
    super(message);
    this.name = "ApiError";
  }
}

export async function apiGet<T>(path: string, init?: { signal?: AbortSignal }): Promise<T> {
  let res: Response;
  try {
    res = await fetch(`${API_URL}${path}`, { signal: init?.signal, headers: { accept: "application/json" } });
  } catch (e) {
    if ((e as Error).name === "AbortError") throw e;
    throw new ApiError("Indexer unreachable", null, true);
  }
  if (!res.ok) throw new ApiError(`Indexer responded ${res.status}`, res.status, res.status >= 500);
  const body = (await res.json()) as { data?: T } & Record<string, unknown>;
  // Endpoints wrap payloads as { data }. /health may be served bare.
  return (body && "data" in body ? body.data : body) as T;
}

function qs(params: Record<string, string | number | undefined | null>): string {
  const e = Object.entries(params).filter(([, v]) => v !== undefined && v !== null && v !== "");
  return e.length ? `?${new URLSearchParams(e.map(([k, v]) => [k, String(v)])).toString()}` : "";
}

const chain = (id: number = CHAIN_ID) => `/chains/${id}`;

export const api = {
  health: (s?: AbortSignal) => apiGet<ApiHealth>("/health", { signal: s }),
  pools: (s?: AbortSignal) => apiGet<ApiPoolWithOracle[]>(`${chain()}/pools`, { signal: s }),
  pool: (poolId: string, s?: AbortSignal) => apiGet<ApiPoolDetail>(`${chain()}/pools/${encodeURIComponent(poolId)}`, { signal: s }),
  dashboard: (s?: AbortSignal) => apiGet<ApiDashboard>(`${chain()}/dashboard`, { signal: s }),
  events: (p: { limit?: number; type?: EventType | ""; pool?: string } = {}, s?: AbortSignal) =>
    apiGet<(ApiEvent | ApiSwapEvent)[]>(`${chain()}/events${qs(p)}`, { signal: s }).then((rows) => rows.map(normalizeEvent)),
  tokens: (s?: AbortSignal) => apiGet<ApiToken[]>(`${chain()}/tokens`, { signal: s }),
  launches: (s?: AbortSignal) => apiGet<ApiLaunch[]>(`${chain()}/launches`, { signal: s }),
  analytics: (range: AnalyticsRange, s?: AbortSignal) => apiGet<ApiAnalytics>(`${chain()}/analytics${qs({ range })}`, { signal: s }),
  positions: (owner: string, s?: AbortSignal) => apiGet<ApiPositions>(`${chain()}/positions/${owner}`, { signal: s }),
  orders: (owner: string, s?: AbortSignal) => apiGet<ApiOrder[]>(`${chain()}/orders/${owner}`, { signal: s }),
  loans: (owner: string, s?: AbortSignal) => apiGet<ApiLoan[]>(`${chain()}/loans/${owner}`, { signal: s }),
  buybacks: (s?: AbortSignal) => apiGet<ApiBuybacks>(`${chain()}/buybacks`, { signal: s }),
};

export function isSwapEvent(e: ApiEvent | ApiSwapEvent): e is ApiSwapEvent {
  return !("type" in e) && "token_in" in e;
}

export function normalizeEvent(e: ApiEvent | ApiSwapEvent): ApiEvent {
  if (!isSwapEvent(e)) return e;
  return {
    chain_id: e.chain_id,
    type: "swap",
    name: "Swap",
    pool_id: e.pool_id,
    venue: e.venue,
    tx_hash: e.tx_hash,
    log_index: e.log_index,
    block_number: e.block_number,
    actor: e.sender,
    summary: null,
    amount_usd: e.amount_usd,
    data: {
      token_in: e.token_in,
      token_out: e.token_out,
      amount_in: e.amount_in,
      amount_out: e.amount_out,
      fee_amount: e.fee_amount,
      recipient: e.recipient,
    },
    timestamp: e.timestamp,
  };
}
