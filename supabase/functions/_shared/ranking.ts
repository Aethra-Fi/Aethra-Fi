// Dashboard ranking. Mirrors the dashboard_* views in migrations/20261022000004_views_functions.sql so the
// API can build every list from a single pool_overview read. Keep both in sync.

export interface OverviewRow {
  pool_id: string;
  venue: string;
  enabled: boolean;
  tvl_usd: number;
  volume_24h_usd: number;
  trades_24h: number;
  volume_1h_usd: number;
  trades_1h: number;
  is_fresh: boolean;
  launch_token: string | null;
  created_at: string;
  /** a non-Aethra v4 pool, listed read-only */
  external?: boolean;
}

const DAY = 86_400_000;

export const trendingScore = (r: OverviewRow) => r.trades_1h * (1 + Math.log10(1 + Math.max(0, r.volume_1h_usd)));
export const launchScore = (r: OverviewRow) => r.volume_24h_usd * 1e6 + r.trades_24h;

function ts(r: OverviewRow) {
  return Date.parse(r.created_at) || 0;
}

/** Desc by score, ties: newer first, then pool id for determinism. */
function sortBy<T extends OverviewRow>(rows: T[], score: (r: T) => number): T[] {
  return [...rows].sort((a, b) => score(b) - score(a) || ts(b) - ts(a) || a.pool_id.localeCompare(b.pool_id));
}

export interface RankedLists<T> {
  featured: T | null;
  all: T[];
  trending: T[];
  established: T[];
  most_traded: T[];
  highest_volume: T[];
  fresh: T[];
  launch: T[];
}

export function rankDashboard<T extends OverviewRow>(rows: T[], now = Date.now(), limit = 20, allLimit = 200): RankedLists<T> {
  const live = rows.filter((r) => r.enabled);
  const take = (xs: T[], n = limit) => xs.slice(0, n);
  const all = sortBy(live, (r) => r.tvl_usd * 1e3 + r.volume_24h_usd);
  return {
    featured: pickFeatured(live),
    all: take(all, allLimit),
    trending: take(sortBy(live.filter((r) => r.trades_1h > 0), trendingScore)),
    established: take(sortBy(live.filter((r) => now - ts(r) > 7 * DAY && r.tvl_usd > 0), (r) => r.tvl_usd)),
    most_traded: take(sortBy(live.filter((r) => r.trades_24h > 0), (r) => r.trades_24h)),
    highest_volume: take(sortBy(live.filter((r) => r.volume_24h_usd > 0), (r) => r.volume_24h_usd)),
    fresh: take(sortBy(live.filter((r) => r.is_fresh), ts)),
    launch: take(sortBy(live.filter((r) => r.venue === "LAUNCH" || r.launch_token !== null), launchScore)),
  };
}

/** Featured market: highest 24h volume, else deepest TVL, else most trades, else the newest pool. */
export function pickFeatured<T extends OverviewRow>(rows: T[]): T | null {
  // Aethra's own markets only: the featured card links into the swap flow
  const live = rows.filter((r) => r.enabled && !r.external);
  if (live.length === 0) return null;
  const byVolume = sortBy(live.filter((r) => r.volume_24h_usd > 0), (r) => r.volume_24h_usd);
  if (byVolume.length) return byVolume[0];
  const byTvl = sortBy(live.filter((r) => r.tvl_usd > 0), (r) => r.tvl_usd);
  if (byTvl.length) return byTvl[0];
  const byTrades = sortBy(live.filter((r) => r.trades_24h > 0), (r) => r.trades_24h);
  if (byTrades.length) return byTrades[0];
  return sortBy(live, ts)[0];
}

export function dashboardStats(rows: OverviewRow[], assets: number) {
  // headline numbers are Aethra's; external pools are listed but not counted
  const live = rows.filter((r) => r.enabled && !r.external);
  return {
    tvl_usd: live.reduce((s, r) => s + (r.tvl_usd || 0), 0),
    volume_24h_usd: live.reduce((s, r) => s + (r.volume_24h_usd || 0), 0),
    trades_24h: live.reduce((s, r) => s + (r.trades_24h || 0), 0),
    pools: live.length,
    assets,
  };
}
