// Aethra Fi public read API (Supabase Edge Function, no auth). Shapes match apps/web/src/lib/api.ts and
// packages/sdk/src/types.ts. Every response is `{ data }` except errors (`{ error }`).
import { createClient } from "npm:@supabase/supabase-js@2.49.4";
import { createPublicClient, http, parseAbi, type Hex } from "npm:viem@2.57.7";
import { chunked } from "../_shared/chunking.ts";
import { toHuman } from "../_shared/math.ts";
import { dashboardStats, pickFeatured, rankDashboard } from "../_shared/ranking.ts";

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET, OPTIONS",
  "access-control-allow-headers": "authorization, apikey, content-type, x-client-info",
};

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

type Row = Record<string, any>;

/** Modules that are built but hidden. Set the function secret FEATURES=launchpad,credit,buyback to switch them back on. */
const FEATURES = new Set((Deno.env.get("FEATURES") ?? "").split(",").map((s) => s.trim()).filter(Boolean));
const HIDDEN_EVENT_TYPES = [
  ...(FEATURES.has("launchpad") ? [] : ["launch"]),
  ...(FEATURES.has("credit") ? [] : ["loan", "vault"]),
  ...(FEATURES.has("buyback") ? [] : ["buyback"]),
];

const ok = (data: unknown, maxAge = 10) =>
  new Response(JSON.stringify({ data }), {
    headers: { ...CORS, "content-type": "application/json", "cache-control": `public, max-age=${maxAge}, stale-while-revalidate=30` },
  });
const fail = (status: number, error: string) => new Response(JSON.stringify({ error }), { status, headers: { ...CORS, "content-type": "application/json" } });

async function q<T = Row[]>(p: PromiseLike<{ data: unknown; error: { message: string } | null }>): Promise<T> {
  const { data, error } = await p;
  if (error) throw new Error(error.message);
  return data as T;
}

const token = (t: Row) => ({ address: t.address, symbol: t.symbol, name: t.name, decimals: t.decimals, kind: t.kind, logo_url: t.logo_url ?? null });

function pool(r: Row): Row {
  return {
    ...r,
    token0: token(r.token0),
    token1: token(r.token1),
    sparkline: r.sparkline ?? [],
    volume_sparkline: r.volume_sparkline ?? [],
  };
}

async function tokenMap(chain: number) {
  const rows = await q(db.from("tokens").select("*").eq("chain_id", chain));
  return new Map<string, Row>(rows.map((t) => [t.address, t]));
}

async function chainClient(chain: number) {
  const c = await q<Row>(db.from("chains").select("rpc_url").eq("chain_id", chain).single());
  return createPublicClient({ transport: http(Deno.env.get(`RPC_URL_${chain}`) ?? c.rpc_url, { batch: true }) });
}

// ------------------------------------------------------------------ handlers

async function health() {
  const rows = await q(db.from("indexer_state").select("chain_id,last_block,head_block,status,updated_at"));
  const live = rows.filter((r) => r.status !== "disabled" && r.last_block !== null);
  const stale = live.some((r) => Date.now() - Date.parse(r.updated_at) > 5 * 60_000 || r.status === "error");
  const lag = live.some((r) => r.head_block && r.last_block && r.head_block - r.last_block > 500);
  return {
    status: live.length === 0 ? "down" : stale ? "degraded" : lag ? "degraded" : "ok",
    service: "aethra-api",
    chains: live.map((r) => r.chain_id),
    indexing: live.map((r) => ({ chain_id: r.chain_id, last_block: r.last_block, head_block: r.head_block, updated_at: r.updated_at })),
    timestamp: new Date().toISOString(),
  };
}

async function overview(chain: number) {
  const rows = (await q(db.from("pool_overview").select("*").eq("chain_id", chain))).map(pool);
  return FEATURES.has("launchpad") ? rows : rows.filter((p) => p.venue !== "LAUNCH");
}

/** Oracle state for stock pools: reference price (hub oracle) vs the pool's implied price. */
function oracleState(p: Row, tokens: Map<string, Row>) {
  if (p.mode !== "oracle") return null;
  const t0 = tokens.get(p.token0.address);
  const t1 = tokens.get(p.token1.address);
  const stockIs0 = t0?.asset_class === "STOCK" || t0?.asset_class === "RWA";
  const stock = stockIs0 ? t0 : t1;
  const quote = stockIs0 ? t1 : t0;
  const ref = stock?.price_source === "oracle" ? stock.price_usd : null;
  const quoteUsd = quote?.price_usd ?? null;
  const poolUsd = p.price && quoteUsd ? (stockIs0 ? p.price * quoteUsd : quoteUsd / p.price) : null;
  const dev = ref && poolUsd ? Math.round((Math.abs(poolUsd - ref) / ref) * 10_000) : null;
  const stale = stock?.price_updated_at && stock.max_staleness ? Date.now() - Date.parse(stock.price_updated_at) > stock.max_staleness * 1000 : false;
  return {
    reference_price_usd: ref,
    pool_price_usd: poolUsd,
    deviation_bps: dev,
    market_open: null,
    updated_at: stock?.price_updated_at ?? null,
    fee_multiplier: null,
    risk: !ref || stale ? "HALTED" : dev !== null && dev > 300 ? "ELEVATED" : "NORMAL",
  };
}

async function pools(chain: number) {
  const [rows, tokens] = await Promise.all([overview(chain), tokenMap(chain)]);
  return rows.map((p) => ({ ...p, oracle: oracleState(p, tokens) }));
}

async function poolDetail(chain: number, id: string) {
  const [rows, tokens] = await Promise.all([q(db.from("pool_overview").select("*").eq("chain_id", chain).eq("pool_id", id.toLowerCase())), tokenMap(chain)]);
  if (!rows.length) return null;
  const p = pool(rows[0]);
  const hours = await q(
    db.from("pool_stats_hourly").select("hour,open_price,high_price,low_price,close_price,volume_usd").eq("chain_id", chain).eq("pool_id", p.pool_id)
      .gte("hour", new Date(Date.now() - 30 * 86_400_000).toISOString()).order("hour"),
  );
  const candles = hours.filter((h) => h.close_price !== null).map((h) => ({
    t: h.hour, open: h.open_price ?? h.close_price, high: h.high_price ?? h.close_price, low: h.low_price ?? h.close_price, close: h.close_price, volume_usd: h.volume_usd ?? 0,
  }));
  return { ...p, oracle: oracleState(p, tokens), candles, price_series: candles.map((c) => ({ t: c.t, price: c.close })) };
}

async function dashboard(chain: number) {
  const [rows, assets] = await Promise.all([
    overview(chain),
    q<Row[]>(db.from("tokens").select("address").eq("chain_id", chain).not("asset_class", "is", null)),
  ]);
  const lists = rankDashboard(rows as any[]);
  return { chain_id: chain, timestamp: new Date().toISOString(), ...lists, featured: pickFeatured(rows as any[]), stats: dashboardStats(rows as any[], assets.length) };
}

const EVENT_TYPES: Record<string, string[]> = {
  swap: ["swap"],
  liquidity: ["liquidity"],
  launch: ["launch"],
  order: ["order"],
  loan: ["loan", "vault"],
  buyback: ["buyback"],
};

function fmt(raw: string | null | undefined, dec: number) {
  if (raw === null || raw === undefined) return "?";
  const v = Math.abs(toHuman(BigInt(raw), dec));
  return v >= 1000 ? v.toLocaleString("en-US", { maximumFractionDigits: 0 }) : v.toPrecision(4).replace(/\.?0+$/, "");
}

function eventName(type: string, action: string) {
  const names: Record<string, string> = {
    "swap.swap": "Swap", "liquidity.add": "Add liquidity", "liquidity.remove": "Remove liquidity", "liquidity.collect": "Collect fees",
    "liquidity.claim": "Claim fees", "launch.created": "Launch", "launch.graduated": "Graduated", "order.placed": "Order placed",
    "order.cancelled": "Order cancelled", "order.claimed": "Order filled", "buyback.revenue": "Revenue", "buyback.buyback": "Buyback & burn",
  };
  return names[`${type}.${action}`] ?? action.charAt(0).toUpperCase() + action.slice(1);
}

async function events(chain: number, params: URLSearchParams) {
  const limit = Math.min(200, Math.max(1, Number(params.get("limit") ?? 50)));
  const poolId = params.get("pool");
  // route rows duplicate their swaps; vault Borrowed/Repaid/InterestAccrued mirror credit Borrow/Repay.
  // The global feed is Aethra activity only; a pool page reads event_feed_all so external pools show their trades.
  let query = db.from(poolId ? "event_feed_all" : "event_feed").select("*").eq("chain_id", chain).neq("type", "route")
    .not("action", "in", "(borrowed,repaid,interestaccrued)").order("block_number", { ascending: false }).order("log_index", { ascending: false }).limit(limit);
  if (HIDDEN_EVENT_TYPES.length) query = query.not("type", "in", `(${HIDDEN_EVENT_TYPES.join(",")})`);
  const type = params.get("type");
  if (type && EVENT_TYPES[type]) {
    if (EVENT_TYPES[type].every((t) => HIDDEN_EVENT_TYPES.includes(t))) return [];
    query = query.in("type", EVENT_TYPES[type]);
  }
  if (poolId) query = query.eq("pool_id", poolId.toLowerCase());
  const [rows, tokens, poolRows] = await Promise.all([q(query), tokenMap(chain), q(db.from("pools").select("pool_id,token0,token1").eq("chain_id", chain))]);
  const poolTokens = new Map(poolRows.map((p) => [p.pool_id, p]));
  const sym = (a: string | undefined) => (a && tokens.get(a)?.symbol) || "?";
  const dec = (a: string | undefined) => (a && tokens.get(a)?.decimals) ?? 18;
  return rows.map((e) => {
    const d = e.data ?? {};
    let summary: string | null = null;
    if (e.type === "swap") summary = `${fmt(d.amount_in, dec(d.token_in))} ${sym(d.token_in)} → ${fmt(d.amount_out, dec(d.token_out))} ${sym(d.token_out)}`;
    else if (e.type === "liquidity" && e.pool_id && poolTokens.has(e.pool_id) && (d.amount0 !== "0" || d.amount1 !== "0")) {
      const p = poolTokens.get(e.pool_id)!;
      summary = `${fmt(d.amount0, dec(p.token0))} ${sym(p.token0)} + ${fmt(d.amount1, dec(p.token1))} ${sym(p.token1)}`;
    } else if (e.type === "launch") summary = `${d.symbol ? `$${d.symbol}` : ""} ${d.name ?? ""}`.trim();
    else if (e.type === "buyback" && d.token) summary = `${fmt(d.amount, dec(d.token))} ${sym(d.token)}${d.aeth_burned ? ` · ${fmt(d.aeth_burned, 18)} AETH burned` : ""}`;
    else if (e.type === "loan" || e.type === "vault") summary = d.token_id ? `Position #${d.token_id}` : null;
    else if (e.type === "order") summary = `Order #${d.order_id} · bin ${d.bin_id}`;
    return {
      chain_id: e.chain_id,
      type: e.type === "vault" ? "loan" : e.type,
      name: eventName(e.type, e.action),
      pool_id: e.pool_id,
      venue: d.venue ?? (e.type === "launch" ? "LAUNCH" : null),
      tx_hash: e.tx_hash,
      log_index: e.log_index,
      block_number: e.block_number,
      actor: e.account,
      summary,
      amount_usd: d.amount_usd ?? null,
      data: d,
      timestamp: e.ts,
    };
  });
}

async function tokens(chain: number) {
  return (await q(db.from("tokens").select("*").eq("chain_id", chain).order("symbol"))).map(token);
}

async function launches(chain: number) {
  const since = new Date(Date.now() - 86_400_000).toISOString();
  const [rows, poolRows, trades, state, tokensBy, dep] = await Promise.all([
    q(db.from("launches").select("*").eq("chain_id", chain).order("created_at", { ascending: false }).limit(200)),
    q(db.from("pools").select("pool_id,reserve0,reserve1,token0,price").eq("chain_id", chain).eq("venue", "LAUNCH")),
    q(db.from("launch_trades").select("token,amount_usd,weth_amount").eq("chain_id", chain).gte("ts", since)),
    q<Row>(db.from("indexer_state").select("meta").eq("chain_id", chain).single()),
    tokenMap(chain),
    q<Row>(db.from("deployments").select("addresses").eq("chain_id", chain).single()),
  ]);
  const weth = String(dep.addresses?.weth ?? "").toLowerCase();
  const wethUsd = tokensBy.get(weth)?.price_usd ?? null;
  const threshold = BigInt(state?.meta?.graduationThreshold ?? "0");
  const poolOf = new Map(poolRows.map((p) => [p.pool_id, p]));
  const vol = new Map<string, { usd: number; n: number }>();
  for (const t of trades) {
    const v = vol.get(t.token) ?? { usd: 0, n: 0 };
    v.usd += t.amount_usd ?? (wethUsd ? toHuman(BigInt(t.weth_amount), 18) * wethUsd : 0);
    v.n += 1;
    vol.set(t.token, v);
  }
  return rows.map((l) => {
    const p = poolOf.get(l.token);
    const wethIs0 = p?.token0 === weth;
    const realToken = p ? String(wethIs0 ? p.reserve1 : p.reserve0) : "0";
    // pool price is token1 per token0; express it as WETH per token
    const priceWeth = p?.price ? (wethIs0 ? 1 / p.price : p.price) : null;
    const realWeth = BigInt(l.real_weth ?? 0);
    return {
      token: l.token, name: l.name, symbol: l.symbol, creator: l.creator, metadata_uri: l.metadata_uri, image_url: null,
      real_weth: realWeth.toString(), real_token: realToken, virtual_weth: "0", virtual_token: "0",
      graduation_threshold: threshold.toString(),
      progress: l.graduated ? 1 : threshold > 0n ? Math.min(1, Number((realWeth * 10_000n) / threshold) / 10_000) : 0,
      graduated: l.graduated, v4_pool_id: l.v4_pool_id, price_weth: priceWeth,
      market_cap_usd: priceWeth && wethUsd ? priceWeth * wethUsd * 1e9 : null,
      volume_24h_usd: vol.get(l.token)?.usd ?? 0, trades_24h: vol.get(l.token)?.n ?? 0, holders: null, created_at: l.created_at,
    };
  });
}

async function analytics(chain: number, range: string) {
  const [data, ov] = await Promise.all([q<Row>(db.rpc("api_analytics", { p_chain: chain, p_range: range })), overview(chain)]);
  const byId = new Map(ov.map((p) => [p.pool_id, p]));
  const top: Row[] = data.top_pools ?? [];
  const feesByVenue = new Map<string, number>();
  for (const p of top) feesByVenue.set(p.venue, (feesByVenue.get(p.venue) ?? 0) + (p.fees_usd ?? 0));
  return {
    range: data.range,
    totals: data.totals,
    series: (data.series ?? []).map((s: Row) => ({ t: s.timestamp, tvl_usd: s.tvl_usd ?? 0, volume_usd: s.volume_usd ?? 0, fees_usd: s.fees_usd ?? 0, trades: s.trades ?? 0 })),
    venues: (data.venues ?? []).map((v: Row) => ({ venue: v.venue, tvl_usd: v.tvl_usd ?? 0, volume_usd: v.volume_usd ?? 0, fees_usd: feesByVenue.get(v.venue) ?? 0 })),
    top_pools: top.map((p) => byId.get(p.pool_id)).filter(Boolean),
  };
}

const dlmmAbi = parseAbi(["function sharesOf(int24 id, address account) view returns (uint256)"]);
const buybackAbi = parseAbi(["function config() view returns (address hub, address router, uint64 cooldown, uint16 treasuryBps)"]);

async function positions(chain: number, owner: string) {
  const o = owner.toLowerCase();
  const pledged = await q(db.from("loans").select("token_id").eq("chain_id", chain).eq("owner", o).eq("status", "pledged"));
  const pledgedIds = new Set(pledged.map((l) => String(l.token_id)));
  const ids = [...pledgedIds];
  const [own, viaLoan, ov] = await Promise.all([
    q(db.from("positions").select("*").eq("chain_id", chain).eq("owner", o).eq("burned", false)),
    ids.length ? q(db.from("positions").select("*").eq("chain_id", chain).in("token_id", ids)) : Promise.resolve([] as Row[]),
    overview(chain),
  ]);
  const byId = new Map(ov.map((p) => [p.pool_id, p]));
  const v4 = [...own, ...viaLoan].map((p) => ({
    token_id: String(p.token_id), owner: o, pool_id: p.pool_id, pool: byId.get(p.pool_id) ?? null, tick_lower: p.tick_lower, tick_upper: p.tick_upper,
    liquidity: String(p.liquidity), locked: Boolean(p.lock_permanent || p.lock_end), lock_cliff: p.lock_cliff ? Date.parse(p.lock_cliff) / 1000 : null,
    lock_end: p.lock_permanent ? Number((1n << 64n) - 1n) : p.lock_end ? Date.parse(p.lock_end) / 1000 : null, pledged: pledgedIds.has(String(p.token_id)), created_at: p.minted_at,
  }));

  const balances = await q(db.from("lp_balances").select("*").eq("chain_id", chain).eq("account", o));
  const damm = balances.filter((b) => b.venue === "DAMM").map((b) => ({ pool_address: b.pool_id, pool: byId.get(b.pool_id) ?? null, shares: String(b.shares) }));

  // DLMM: bins the account ever received, with live per-bin shares read on chain
  const dlmmPools = balances.filter((b) => b.venue === "DLMM").map((b) => b.pool_id);
  const dlmm = [];
  if (dlmmPools.length) {
    const client = await chainClient(chain);
    const adds = await q(db.from("liquidity_events").select("pool_id,bin_ids").eq("chain_id", chain).eq("source", "dlmm").eq("kind", "add").eq("recipient", o).in("pool_id", dlmmPools));
    for (const poolId of dlmmPools) {
      const bins = [...new Set(adds.filter((a) => a.pool_id === poolId).flatMap((a) => a.bin_ids ?? []))].sort((a, b) => a - b).slice(0, 200);
      const shares: bigint[] = [];
      try {
        for (const part of chunked(bins, 50)) {
          shares.push(...await Promise.all(part.map((id) => client.readContract({ address: poolId as Hex, abi: dlmmAbi, functionName: "sharesOf", args: [id, o as Hex] }))));
        }
      } catch {
        continue; // RPC unavailable: skip this pool rather than failing the whole response
      }
      const live = bins.map((id, i) => ({ id, shares: String(shares[i] ?? 0n) })).filter((b) => b.shares !== "0");
      if (live.length) dlmm.push({ pool_address: poolId, pool: byId.get(poolId) ?? null, bins: live });
    }
  }
  return { v4, dlmm, damm };
}

async function orders(chain: number, owner: string) {
  const [rows, ov] = await Promise.all([
    q(db.from("limit_order_overview").select("*").eq("chain_id", chain).eq("owner", owner.toLowerCase()).order("placed_at", { ascending: false })),
    overview(chain),
  ]);
  const byAddr = new Map(ov.filter((p) => p.pool_address).map((p) => [p.pool_address, p]));
  const status = (s: string) => ({ open: "OPEN", partial: "PARTIAL", filled: "FILLED" } as Record<string, string>)[s] ?? "CLOSED";
  return rows.map((o) => ({
    order_id: String(o.order_id), owner: o.owner, pool_address: o.pool_address, pool: byAddr.get(o.pool_address) ?? null, bin_id: o.bin_id, side: o.side,
    amount_in: String(o.amount_in), status: status(o.effective_status), tx_hash: o.placed_tx, created_at: o.placed_at,
  }));
}

async function loans(chain: number, owner: string) {
  const rows = await q(db.from("loans").select("*").eq("chain_id", chain).eq("owner", owner.toLowerCase()).order("pledged_at", { ascending: false }));
  const status = (s: string) => (s === "pledged" ? "ACTIVE" : s === "liquidated" ? "LIQUIDATED" : "CLOSED");
  return rows.map((l) => ({
    token_id: String(l.token_id), owner: l.owner, debt: String(l.principal_outstanding), collateral_usd: l.liquidation_value_usd ?? null, health_factor: null,
    status: status(l.status), opened_at: l.pledged_at,
  }));
}

async function buybacks(chain: number) {
  const [rows, tokens, dep] = await Promise.all([
    q(db.from("buybacks").select("*").eq("chain_id", chain).order("block_number", { ascending: false }).limit(500)),
    tokenMap(chain),
    q<Row>(db.from("deployments").select("addresses").eq("chain_id", chain).single()),
  ]);
  const aeth = (dep.addresses?.aeth as string | null)?.toLowerCase() ?? null;
  const execs = rows.filter((r) => r.kind === "buyback");
  const burned = execs.reduce((s, r) => s + BigInt(r.aeth_burned ?? 0), 0n);
  // pending revenue per token: received minus spent (treasury share included)
  const pending = new Map<string, bigint>();
  for (const r of rows) pending.set(r.token, (pending.get(r.token) ?? 0n) + (r.kind === "revenue" ? BigInt(r.amount) : -BigInt(r.amount)));
  const tok = (a: string) => (tokens.get(a) ? token(tokens.get(a)!) : null);
  const aethUsd = aeth ? tokens.get(aeth)?.price_usd ?? null : null;
  let treasuryBps = 2000; // contract default, used if the read fails
  const bb = dep.addresses?.buyback as Hex | null;
  if (bb) {
    try {
      const client = await chainClient(chain);
      const cfg = await client.readContract({ address: bb, abi: buybackAbi, functionName: "config" });
      treasuryBps = Number(cfg[3]);
    } catch {
      // keep default
    }
  }
  return {
    aeth,
    total_burned: burned.toString(),
    total_burned_usd: aethUsd ? toHuman(burned, 18) * aethUsd : null,
    buyback_bps: 10_000 - treasuryBps,
    treasury_bps: treasuryBps,
    revenue: [...pending.entries()].filter(([, v]) => v > 0n).flatMap(([a, v]) => {
      const t = tok(a);
      if (!t) return [];
      const px = tokens.get(a)?.price_usd;
      return [{ token: t, amount: v.toString(), amount_usd: px ? toHuman(v, t.decimals) * px : null }];
    }),
    executions: execs.slice(0, 50).map((r) => ({
      tx_hash: r.tx_hash, token_in: tok(r.token), amount_in: String(r.amount), aeth_bought: String(r.aeth_bought ?? 0), aeth_burned: String(r.aeth_burned ?? 0),
      to_treasury: String(r.to_treasury ?? 0), timestamp: r.ts,
    })),
  };
}

// ------------------------------------------------------------------ router

const ADDR = /^0x[0-9a-fA-F]{40}$/;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  if (req.method !== "GET") return fail(405, "method not allowed");
  const url = new URL(req.url);
  // path arrives as /api/... (function name prefix) or /functions/v1/api/...
  const parts = url.pathname.replace(/^.*?\/api(?=\/|$)/, "").split("/").filter(Boolean);
  try {
    if (parts.length === 0 || parts[0] === "health") return ok(await health(), 5);
    if (parts[0] !== "chains" || !parts[1] || !/^\d+$/.test(parts[1])) return fail(404, "not found");
    const chain = Number(parts[1]);
    const [res, arg] = [parts[2], parts[3] ? decodeURIComponent(parts[3]) : undefined];
    switch (res) {
      case "pools": {
        if (!arg) return ok(await pools(chain), 15);
        const d = await poolDetail(chain, arg);
        return d ? ok(d, 15) : fail(404, "pool not found");
      }
      case "dashboard":
        return ok(await dashboard(chain), 15);
      case "events":
        return ok(await events(chain, url.searchParams), 5);
      case "tokens":
        return ok(await tokens(chain), 60);
      case "launches":
        if (!FEATURES.has("launchpad")) return fail(404, "feature not enabled");
        return ok(await launches(chain), 10);
      case "analytics":
        return ok(await analytics(chain, url.searchParams.get("range") ?? "24h"), 60);
      case "buybacks":
        if (!FEATURES.has("buyback")) return fail(404, "feature not enabled");
        return ok(await buybacks(chain), 30);
      case "positions":
      case "orders":
      case "loans":
        if (res === "loans" && !FEATURES.has("credit")) return fail(404, "feature not enabled");
        if (!arg || !ADDR.test(arg)) return fail(400, "owner address required");
        return ok(res === "positions" ? await positions(chain, arg) : res === "orders" ? await orders(chain, arg) : await loans(chain, arg), 5);
      default:
        return fail(404, "not found");
    }
  } catch (e) {
    return fail(500, e instanceof Error ? e.message : String(e));
  }
});
