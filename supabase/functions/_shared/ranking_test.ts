import { dashboardStats, type OverviewRow, pickFeatured, rankDashboard } from "./ranking.ts";

const row = (o: Partial<OverviewRow>): OverviewRow => ({
  pool_id: "p", venue: "V4", enabled: true, tvl_usd: 0, volume_24h_usd: 0, trades_24h: 0, volume_1h_usd: 0, trades_1h: 0,
  is_fresh: false, launch_token: null, created_at: "2026-10-01T00:00:00Z", ...o,
});

function assert(cond: boolean, msg: string) {
  if (!cond) throw new Error(msg);
}

const own = row({ pool_id: "own", tvl_usd: 5, volume_24h_usd: 1, trades_24h: 1 });
const ext = row({ pool_id: "ext", tvl_usd: 900_000, volume_24h_usd: 400_000, trades_24h: 900, external: true });

Deno.test("featured market and headline stats ignore external pools", () => {
  assert(pickFeatured([ext, own])?.pool_id === "own", "featured should be the Aethra pool");
  const s = dashboardStats([ext, own], 3);
  assert(s.pools === 1 && s.tvl_usd === 5 && s.trades_24h === 1, `stats ${JSON.stringify(s)}`);
});

Deno.test("external pools still appear in the lists", () => {
  const lists = rankDashboard([own, ext]);
  assert(lists.all.map((r) => r.pool_id).join() === "ext,own", "all");
  assert(lists.most_traded[0].pool_id === "ext", "most traded");
  assert(lists.highest_volume[0].pool_id === "ext", "highest volume");
});

Deno.test("with only external pools there is no featured market", () => {
  assert(pickFeatured([ext]) === null, "expected null");
});
