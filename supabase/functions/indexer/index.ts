// Aethra Fi indexer (Supabase Edge Function). Called every minute by pg_cron (see migrations/*_cron.sql).
// Per chain: read logs in adaptive chunks from the cursor to the safe head, store decoded events, discover
// pools and tokens, read chain state for venues that are not event-sourced, price tokens, then call
// aethra_refresh() for derived state (reserves, TVL, hourly stats, loans, positions).
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.49.4";
import { createPublicClient, http, type Hex, type PublicClient } from "npm:viem@2.57.7";
import {
  dammPoolAbi,
  dlmmPoolAbi,
  erc20Abi,
  hubAbi,
  launchpadAbi,
  ASSET_CLASSES,
  ORDER_SIDES,
  STATIC_ROLES,
  VENUES,
  type Role,
} from "../_shared/abis.ts";
import { backoffMs, ChunkSizer, chunked, DEFAULT_CHUNK, nextRange, planStart, safeHead } from "../_shared/chunking.ts";
import { amountsForLiquidity, big, isStableToken, priceFromBin, priceFromSqrtX96, swapUsd, toHuman } from "../_shared/math.ts";
import { decodeLog, dedupeRawLogs, type DecodedLog, type RawLog, sortLogs, TOPICS, UINT64_MAX, ZERO_ADDRESS } from "../_shared/normalize.ts";
import { derivePrices, scaleE18 } from "../_shared/pricing.ts";

const BUDGET_MS = 45_000;
const MAX_LOGS_PER_CALL = 10_000;

type Row = Record<string, unknown>;

interface PoolRow {
  pool_id: string;
  venue: string;
  pool_address: string | null;
  token0: string;
  token1: string;
}

interface TokenRow {
  address: string;
  symbol: string;
  decimals: number;
  kind: string;
  asset_class: string | null;
  price_usd: number | null;
}

/**
 * Rows collected while processing one chunk; flushed in dependency order.
 * `add` rows are complete enough to insert. `patch` changes an existing row: it merges into a row added in
 * the same batch, otherwise it becomes an UPDATE (an upsert would fail NOT NULL checks on insert).
 */
class Batch {
  tables: Record<string, Map<string, Row>> = {};
  patches: Record<string, Map<string, { match: Row; set: Row }>> = {};
  add(table: string, key: string, row: Row, merge = false) {
    const m = (this.tables[table] ??= new Map());
    m.set(key, merge && m.has(key) ? { ...m.get(key), ...row } : row);
  }
  patch(table: string, key: string, match: Row, set: Row) {
    const m = this.tables[table];
    if (m?.has(key)) {
      m.set(key, { ...m.get(key), ...set });
      return;
    }
    const p = (this.patches[table] ??= new Map());
    p.set(key, { match, set: { ...(p.get(key)?.set ?? {}), ...set } });
  }
}

// Tables whose rows are immutable events (insert, ignore duplicates on re-scan).
const EVENT_TABLES = new Set(["swaps", "liquidity_events", "launch_trades", "vault_events", "buybacks", "route_executions", "v4_pool_keys"]);
const CONFLICT: Record<string, string> = {
  tokens: "chain_id,address",
  pools: "chain_id,pool_id",
  v4_pool_keys: "chain_id,pool_id",
  positions: "chain_id,token_id",
  launches: "chain_id,token",
  limit_orders: "chain_id,order_id",
};
const FLUSH_ORDER = ["tokens", "pools", "v4_pool_keys", "positions", "launches", "limit_orders", "swaps", "liquidity_events", "launch_trades", "vault_events", "buybacks", "route_executions"];

/**
 * PostgREST upserts take the union of keys across a payload and write every listed column on conflict, so a
 * mixed batch would overwrite columns some rows did not set. Group rows by their exact key set first.
 */
async function upsertGrouped(db: SupabaseClient, table: string, rows: Row[]) {
  const groups = new Map<string, Row[]>();
  for (const r of rows) {
    const sig = Object.keys(r).sort().join(",");
    (groups.get(sig) ?? groups.set(sig, []).get(sig)!).push(r);
  }
  for (const group of groups.values()) {
    for (const part of chunked(group, 500)) {
      const { error } = await db.from(table).upsert(part, {
        onConflict: CONFLICT[table] ?? "chain_id,tx_hash,log_index",
        ignoreDuplicates: EVENT_TABLES.has(table),
        defaultToNull: false,
      });
      if (error) throw new Error(`${table}: ${error.message}`);
    }
  }
}

async function flush(db: SupabaseClient, b: Batch) {
  for (const table of FLUSH_ORDER) {
    await upsertGrouped(db, table, [...(b.tables[table]?.values() ?? [])]);
    for (const { match, set } of b.patches[table]?.values() ?? []) {
      const { error } = await db.from(table).update({ ...set, updated_at: new Date().toISOString() }).match(match);
      if (error) throw new Error(`${table} update: ${error.message}`);
    }
  }
}

const ts = (sec: number) => new Date(sec * 1000).toISOString();
const hexId = (v: bigint | string) => (typeof v === "string" ? v.toLowerCase() : `0x${v.toString(16).padStart(64, "0")}`);
const addrFromBytes32 = (id: string) => `0x${id.slice(-40)}`.toLowerCase();

async function withRetry<T>(fn: () => Promise<T>, tries = 4): Promise<T> {
  let last: unknown;
  for (let i = 0; i < tries; i++) {
    try {
      return await fn();
    } catch (e) {
      last = e;
      await new Promise((r) => setTimeout(r, backoffMs(i)));
    }
  }
  throw last;
}

async function getLogs(rpc: string, params: Record<string, unknown>): Promise<RawLog[]> {
  const res = await fetch(rpc, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_getLogs", params: [params] }),
  });
  const body = await res.json();
  if (body.error) throw new Error(`eth_getLogs: ${body.error.message ?? JSON.stringify(body.error)}`);
  const logs = body.result as RawLog[];
  if (logs.length >= MAX_LOGS_PER_CALL) throw new Error("eth_getLogs: too many results");
  return logs;
}

// ------------------------------------------------------------------ chain indexing

async function indexChain(db: SupabaseClient, chainId: number, deadline: number) {
  const started = Date.now();
  const [{ data: chain }, { data: dep }, { data: state }] = await Promise.all([
    db.from("chains").select("*").eq("chain_id", chainId).single(),
    db.from("deployments").select("*").eq("chain_id", chainId).single(),
    db.from("indexer_state").select("*").eq("chain_id", chainId).maybeSingle(),
  ]);
  if (!chain || !dep) return { chainId, skipped: "unknown chain" };
  const A = Object.fromEntries(Object.entries(dep.addresses ?? {}).map(([k, v]) => [k, typeof v === "string" ? v.toLowerCase() : v])) as Record<string, string | null>;
  if (!A.hub) {
    await db.from("indexer_state").upsert({ chain_id: chainId, status: "disabled", error: "no deployment", updated_at: new Date().toISOString() });
    return { chainId, skipped: "no deployment" };
  }

  const rpc = Deno.env.get(`RPC_URL_${chainId}`) ?? chain.rpc_url;
  const client = createPublicClient({ transport: http(rpc, { batch: true, retryCount: 2 }) }) as PublicClient;

  // a new deployment (different addresses) rewinds the cursor to its start block
  const depHash = JSON.stringify([A.hub, A.router, A.launchpad, dep.start_block]);
  const meta = (state?.meta ?? {}) as Record<string, unknown>;
  let lastBlock: number | null = state?.last_block ?? null;
  if (meta.deployment !== depHash) lastBlock = null;

  await db.from("indexer_state").upsert({ chain_id: chainId, status: "running", updated_at: new Date().toISOString() });

  // known pools and tokens
  const { data: poolRows } = await db.from("pools").select("pool_id,venue,pool_address,token0,token1,bin_step_bps,sqrt_price_x96").eq("chain_id", chainId);
  const binSteps = new Map<string, number>((poolRows ?? []).filter((p) => p.bin_step_bps).map((p) => [p.pool_id, p.bin_step_bps]));
  // current v4 sqrt prices, advanced by Initialize/Swap so ModifyLiquidity can be converted into token amounts
  const sqrtOf = new Map<string, bigint>((poolRows ?? []).filter((p) => p.venue === "V4" && p.sqrt_price_x96).map((p) => [p.pool_id, BigInt(p.sqrt_price_x96)]));
  const pools = new Map<string, PoolRow>((poolRows ?? []).map((p) => [p.pool_id, p]));
  const { data: tokenRows } = await db.from("tokens").select("address,symbol,decimals,kind,asset_class,price_usd").eq("chain_id", chainId);
  const tokens = new Map<string, TokenRow>((tokenRows ?? []).map((t) => [t.address, t]));
  const depTokens = new Map<string, { symbol: string; name: string; decimals: number; kind: string }>(
    Object.values((dep.addresses?.tokens ?? {}) as Record<string, { address: string; symbol: string; name: string; decimals: number; kind: string }>).map((t) => [t.address.toLowerCase(), t]),
  );

  const roleOf = new Map<string, Role>();
  for (const r of STATIC_ROLES) if (A[r]) roleOf.set(A[r]!, r);
  for (const p of pools.values()) if (p.pool_address && (p.venue === "DLMM" || p.venue === "DAMM")) roleOf.set(p.pool_address, p.venue === "DLMM" ? "dlmmPool" : "dammPool");
  const v4Ids = new Set([...pools.values()].filter((p) => p.venue === "V4").map((p) => p.pool_id));
  const poolManager = A.poolManager!;
  const hook = A.hook;

  const head = Number(await client.getBlockNumber());
  const safe = safeHead(head);
  let from = planStart(lastBlock, Number(dep.start_block ?? 0));
  const sizer = new ChunkSizer(state?.chunk_size ?? DEFAULT_CHUNK, DEFAULT_CHUNK);
  const touched = new Set<string>();
  const newTokens = new Set<string>();
  let since: number | null = null;
  let logsIndexed = 0;

  const blockTs = new Map<number, number>();
  async function timestampsFor(logs: RawLog[]) {
    const need = [...new Set(logs.filter((l) => !l.blockTimestamp).map((l) => Number(BigInt(l.blockNumber))))].filter((n) => !blockTs.has(n));
    for (const part of chunked(need, 50)) {
      const blocks = await Promise.all(part.map((n) => client.getBlock({ blockNumber: BigInt(n) })));
      blocks.forEach((b) => blockTs.set(Number(b.number), Number(b.timestamp)));
    }
  }
  const tOf = (l: DecodedLog) => l.blockTimestamp ?? blockTs.get(l.blockNumber) ?? Math.floor(Date.now() / 1000);

  const token = (addr: string) => {
    const a = addr.toLowerCase();
    if (!tokens.has(a)) newTokens.add(a);
    return a;
  };

  let range = nextRange(from, safe, sizer.size);
  while (range && Date.now() < deadline) {
    const r = range;
    let raw: RawLog[];
    try {
      const fb = `0x${r.from.toString(16)}`;
      const tb = `0x${r.to.toString(16)}`;
      raw = await withRetry(async () => {
        const staticLogs = await getLogs(rpc, { fromBlock: fb, toBlock: tb, address: [...roleOf.keys()] });
        const v4Logs = await getLogs(rpc, { fromBlock: fb, toBlock: tb, address: poolManager, topics: [[TOPICS.v4Initialize, TOPICS.v4Swap, TOPICS.v4ModifyLiquidity]] });
        // pools created inside this range: fetch their logs too, before processing in order
        const created = staticLogs
          .map((l) => roleOf.get(l.address.toLowerCase()) === "dlmmFactory" || roleOf.get(l.address.toLowerCase()) === "dammFactory" ? l : null)
          .filter((l): l is RawLog => !!l && l.topics.length > 1)
          .map((l) => ({ addr: addrFromBytes32(l.topics[1]!), role: (roleOf.get(l.address.toLowerCase()) === "dlmmFactory" ? "dlmmPool" : "dammPool") as Role }));
        const fresh = created.filter((c) => !roleOf.has(c.addr));
        fresh.forEach((c) => roleOf.set(c.addr, c.role));
        const poolLogs = fresh.length ? await getLogs(rpc, { fromBlock: fb, toBlock: tb, address: fresh.map((c) => c.addr) }) : [];
        return dedupeRawLogs([...staticLogs, ...v4Logs, ...poolLogs]);
      });
      sizer.success();
    } catch (e) {
      if (!sizer.fail()) throw e;
      range = nextRange(from, safe, sizer.size);
      continue;
    }

    await timestampsFor(raw);
    const decoded = sortLogs(
      raw
        .map((l) => {
          const a = l.address.toLowerCase();
          const role = a === poolManager ? "poolManager" : roleOf.get(a);
          return role ? decodeLog(l, role) : null;
        })
        .filter((l): l is DecodedLog => !!l),
    );

    const b = new Batch();
    for (const l of decoded) {
      const t = tOf(l);
      since = since === null ? t : Math.min(since, t);
      handle(l, t, b);
    }
    // metadata for new tokens before rows that reference them
    await loadTokens(b);
    await flush(db, b);
    logsIndexed += decoded.length;
    from = r.to + 1;
    await db.from("indexer_state").upsert({
      chain_id: chainId,
      last_block: r.to,
      head_block: head,
      chunk_size: sizer.size,
      status: "syncing",
      logs_indexed: (state?.logs_indexed ?? 0) + logsIndexed,
      meta: { ...meta, deployment: depHash },
      updated_at: new Date().toISOString(),
    });
    range = nextRange(from, safe, sizer.size);
  }

  // ---------------------------------------------------------------- event handlers

  function base(l: DecodedLog, t: number): Row {
    return { chain_id: chainId, tx_hash: l.txHash, log_index: l.logIndex, block_number: l.blockNumber, block_hash: l.blockHash, ts: ts(t) };
  }

  function addPool(b: Batch, row: Row & { pool_id: string; venue: string; token0: string; token1: string; pool_address?: string | null }) {
    const p: PoolRow = { pool_id: row.pool_id, venue: row.venue, pool_address: row.pool_address ?? null, token0: row.token0, token1: row.token1 };
    pools.set(p.pool_id, p);
    touched.add(p.pool_id);
    b.add("pools", p.pool_id, { chain_id: chainId, ...row }, true);
  }

  function handle(l: DecodedLog, t: number, b: Batch) {
    const a = l.args;
    switch (`${l.role}.${l.eventName}`) {
      // ---------------- hub
      case "hub.AssetSet":
        b.add("tokens", token(a.token), {
          chain_id: chainId,
          address: a.token,
          asset_class: ASSET_CLASSES[Number(a.class)] ?? "NONE",
          asset_enabled: a.enabled,
          oracle: a.oracle === ZERO_ADDRESS ? null : a.oracle,
          max_staleness: Number(a.maxStaleness),
        }, true);
        break;
      case "hub.PoolRegistered": {
        const venue = VENUES[Number(a.venue)] ?? "NONE";
        const id = hexId(a.poolId);
        const poolId = venue === "V4" ? id : addrFromBytes32(id);
        const t0 = token(a.token0);
        const t1 = token(a.token1);
        const known = pools.get(poolId);
        addPool(b, {
          pool_id: poolId,
          venue,
          token0: known?.token0 ?? t0,
          token1: known?.token1 ?? t1,
          pool_address: venue === "V4" ? null : venue === "LAUNCH" ? a.pool : poolId,
          hub_pool_id: id,
          registered: true,
          creator: a.creator,
          ...(known ? {} : { created_at: ts(t), created_block: l.blockNumber, created_tx: l.txHash }),
        });
        break;
      }
      case "hub.PoolEnabled": {
        const id = hexId(a.poolId);
        const poolId = pools.has(id) ? id : addrFromBytes32(id);
        if (pools.has(poolId)) b.add("pools", poolId, { chain_id: chainId, pool_id: poolId, ...poolKeys(poolId), enabled: a.enabled }, true);
        break;
      }

      // ---------------- v4
      case "poolManager.Initialize": {
        if (!hook || a.hooks !== hook) break;
        const id = hexId(a.id);
        v4Ids.add(id);
        sqrtOf.set(id, BigInt(a.sqrtPriceX96));
        const t0 = token(a.currency0);
        const t1 = token(a.currency1);
        b.add("v4_pool_keys", id, {
          chain_id: chainId, pool_id: id, currency0: t0, currency1: t1, fee: Number(a.fee), tick_spacing: Number(a.tickSpacing), hooks: a.hooks,
          sqrt_price_x96: big(a.sqrtPriceX96), tick: Number(a.tick), block_number: l.blockNumber, tx_hash: l.txHash, ts: ts(t),
        });
        addPool(b, {
          pool_id: id, venue: "V4", token0: t0, token1: t1, hooks: a.hooks, tick_spacing: Number(a.tickSpacing),
          dynamic_fee: (Number(a.fee) & 0x800000) !== 0, fee_pips: Number(a.fee) & 0x7fffff,
          sqrt_price_x96: big(a.sqrtPriceX96), active_index: Number(a.tick), price: priceOf(t0, t1, a.sqrtPriceX96),
          created_at: ts(t), created_block: l.blockNumber, created_tx: l.txHash,
        });
        break;
      }
      case "poolManager.Swap": {
        const id = hexId(a.id);
        if (!v4Ids.has(id)) break;
        const p = pools.get(id)!;
        // event amounts are the swapper's deltas (negative = paid into the pool)
        const d0 = -BigInt(a.amount0);
        const d1 = -BigInt(a.amount1);
        const zeroForOne = d0 > 0n;
        const amountIn = zeroForOne ? d0 : d1;
        const amountOut = zeroForOne ? -d1 : -d0;
        const fee = Number(a.fee);
        const feeAmount = (amountIn * BigInt(fee)) / 1_000_000n;
        const price = priceOf(p.token0, p.token1, a.sqrtPriceX96);
        sqrtOf.set(id, BigInt(a.sqrtPriceX96));
        b.add("swaps", `${l.txHash}:${l.logIndex}`, {
          ...base(l, t), pool_id: id, venue: "V4", sender: a.sender, recipient: a.sender,
          token_in: zeroForOne ? p.token0 : p.token1, token_out: zeroForOne ? p.token1 : p.token0,
          amount_in: big(amountIn), amount_out: big(amountOut), fee_amount: big(feeAmount), delta0: big(d0), delta1: big(d1), price,
          ...usdOf(zeroForOne ? p.token0 : p.token1, amountIn, zeroForOne ? p.token1 : p.token0, amountOut, feeAmount),
        });
        b.add("pools", id, { chain_id: chainId, pool_id: id, ...poolKeys(id), sqrt_price_x96: big(a.sqrtPriceX96), active_index: Number(a.tick), liquidity: big(a.liquidity), fee_pips: fee, price }, true);
        touched.add(id);
        break;
      }
      case "poolManager.ModifyLiquidity": {
        const id = hexId(a.id);
        if (!v4Ids.has(id)) break;
        const delta = BigInt(a.liquidityDelta);
        // the event has no token amounts: derive the pool's balance change from the range and current price
        const { amount0, amount1 } = amountsForLiquidity(sqrtOf.get(id) ?? 0n, Number(a.tickLower), Number(a.tickUpper), delta);
        b.add("liquidity_events", `${l.txHash}:${l.logIndex}`, {
          ...base(l, t), pool_id: id, venue: "V4", source: "v4", kind: delta >= 0n ? "add" : "remove", sender: a.sender,
          tick_lower: Number(a.tickLower), tick_upper: Number(a.tickUpper), liquidity_delta: big(delta), amount0: big(amount0), amount1: big(amount1),
        });
        touched.add(id);
        break;
      }

      // ---------------- positions NFT
      case "positions.Minted":
        b.add("positions", String(a.tokenId), {
          chain_id: chainId, token_id: String(a.tokenId), pool_id: hexId(a.poolId), owner: a.owner, tick_lower: Number(a.tickLower), tick_upper: Number(a.tickUpper),
          minted_block: l.blockNumber, minted_tx: l.txHash, minted_at: ts(t),
        }, true);
        break;
      case "positions.Transfer":
        if (a.from === ZERO_ADDRESS) break; // mint handled by Minted
        b.patch("positions", String(a.tokenId), { chain_id: chainId, token_id: String(a.tokenId) }, { owner: a.to, burned: a.to === ZERO_ADDRESS });
        break;
      case "positions.Locked": {
        const permanent = BigInt(a.end) >= UINT64_MAX;
        b.patch("positions", String(a.tokenId), { chain_id: chainId, token_id: String(a.tokenId) }, {
          lock_cliff: permanent ? null : ts(Number(a.cliff)), lock_end: permanent ? null : ts(Number(a.end)), lock_permanent: permanent, locked_liquidity: big(a.lockedLiquidity),
        });
        break;
      }
      case "positions.LiquidityChanged":
        b.add("liquidity_events", `${l.txHash}:${l.logIndex}`, {
          ...base(l, t), source: "positions", kind: BigInt(a.liquidityDelta) >= 0n ? "add" : "remove", token_id: String(a.tokenId), liquidity_delta: big(a.liquidityDelta), amount0: big(a.amount0), amount1: big(a.amount1),
        });
        break;
      case "positions.FeesCollected":
        b.add("liquidity_events", `${l.txHash}:${l.logIndex}`, {
          ...base(l, t), source: "positions", kind: "collect", token_id: String(a.tokenId), recipient: a.recipient, amount0: big(a.amount0), amount1: big(a.amount1),
        });
        break;

      // ---------------- DLMM / DAMM
      case "dlmmFactory.PoolCreated":
        addPool(b, {
          pool_id: a.pool, venue: "DLMM", pool_address: a.pool, token0: token(a.token0), token1: token(a.token1), bin_step_bps: Number(a.binStepBps),
          active_index: Number(a.activeId), creator: a.creator, created_at: ts(t), created_block: l.blockNumber, created_tx: l.txHash,
        });
        roleOf.set(a.pool, "dlmmPool");
        binSteps.set(a.pool, Number(a.binStepBps));
        break;
      case "dammFactory.PoolCreated":
        addPool(b, {
          pool_id: a.pool, venue: "DAMM", pool_address: a.pool, token0: token(a.token0), token1: token(a.token1), sqrt_price_x96: big(a.sqrtPriceX96),
          sqrt_price_lower_x96: big(a.sqrtPriceLowerX96), sqrt_price_upper_x96: big(a.sqrtPriceUpperX96), reserves_from_events: false,
          creator: a.creator, created_at: ts(t), created_block: l.blockNumber, created_tx: l.txHash,
        });
        roleOf.set(a.pool, "dammPool");
        break;
      case "dlmmPool.Swap":
      case "dammPool.Swap": {
        const p = pools.get(l.address);
        if (!p) break;
        const zeroForOne = a.tokenIn === p.token0;
        const amtIn = BigInt(a.amountIn);
        const amtOut = BigInt(a.amountOut);
        // the fee and protocol fee stay outside the curve reserves
        const intoCurve = amtIn - BigInt(a.feeAmount);
        b.add("swaps", `${l.txHash}:${l.logIndex}`, {
          ...base(l, t), pool_id: p.pool_id, venue: p.venue, sender: a.sender, recipient: a.recipient, token_in: a.tokenIn, token_out: a.tokenOut,
          amount_in: big(amtIn), amount_out: big(amtOut), fee_amount: big(a.feeAmount), protocol_fee_amount: big(a.protocolFeeAmount),
          delta0: big(zeroForOne ? intoCurve : -amtOut), delta1: big(zeroForOne ? -amtOut : intoCurve),
          price: p.venue === "DLMM" ? binPrice(p, Number(a.indexAfter)) : null,
          ...usdOf(a.tokenIn, amtIn, a.tokenOut, amtOut, BigInt(a.feeAmount)),
        });
        if (p.venue === "DLMM") b.add("pools", p.pool_id, { chain_id: chainId, pool_id: p.pool_id, ...poolKeys(p.pool_id), active_index: Number(a.indexAfter), price: binPrice(p, Number(a.indexAfter)) }, true);
        touched.add(p.pool_id);
        break;
      }
      case "dlmmPool.LiquidityAdded":
      case "dlmmPool.LiquidityRemoved": {
        const p = pools.get(l.address);
        if (!p) break;
        const add = l.eventName === "LiquidityAdded";
        const sum = (xs: bigint[]) => xs.reduce((s, x) => s + BigInt(x), 0n);
        const a0 = add ? sum(a.amounts0) : -BigInt(a.amount0);
        const a1 = add ? sum(a.amounts1) : -BigInt(a.amount1);
        b.add("liquidity_events", `${l.txHash}:${l.logIndex}`, {
          ...base(l, t), pool_id: p.pool_id, venue: "DLMM", source: "dlmm", kind: add ? "add" : "remove", sender: a.sender, recipient: a.recipient,
          bin_ids: (a.ids as number[]).map(Number), shares: big(sum(a.shares)), amount0: big(a0), amount1: big(a1),
        });
        touched.add(p.pool_id);
        break;
      }
      case "dammPool.LiquidityAdded":
      case "dammPool.LiquidityRemoved": {
        const p = pools.get(l.address);
        if (!p) break;
        const add = l.eventName === "LiquidityAdded";
        b.add("liquidity_events", `${l.txHash}:${l.logIndex}`, {
          ...base(l, t), pool_id: p.pool_id, venue: "DAMM", source: "damm", kind: add ? "add" : "remove", sender: a.sender, recipient: a.recipient,
          shares: big(a.shares), amount0: big(add ? BigInt(a.amount0) : -BigInt(a.amount0)), amount1: big(add ? BigInt(a.amount1) : -BigInt(a.amount1)),
        });
        touched.add(p.pool_id);
        break;
      }
      case "dammPool.FeesClaimed": {
        const p = pools.get(l.address);
        if (!p) break;
        b.add("liquidity_events", `${l.txHash}:${l.logIndex}`, {
          ...base(l, t), pool_id: p.pool_id, venue: "DAMM", source: "damm", kind: "claim", sender: a.account, recipient: a.recipient, amount0: big(a.amount0), amount1: big(a.amount1),
        });
        break;
      }

      // ---------------- limit orders
      case "dlmmLimitOrders.OrderPlaced":
        b.add("limit_orders", String(a.orderId), {
          chain_id: chainId, order_id: String(a.orderId), owner: a.owner, pool_address: a.pool, pool_id: pools.get(a.pool)?.pool_id ?? a.pool,
          bin_id: Number(a.binId), side: ORDER_SIDES[Number(a.side)], amount_in: big(a.amountIn), status: "open",
          placed_block: l.blockNumber, placed_tx: l.txHash, placed_log_index: l.logIndex, placed_at: ts(t),
        }, true);
        break;
      case "dlmmLimitOrders.OrderCancelled":
      case "dlmmLimitOrders.OrderClaimed": {
        const cancelled = l.eventName === "OrderCancelled";
        b.patch("limit_orders", String(a.orderId), { chain_id: chainId, order_id: String(a.orderId) }, {
          status: cancelled ? "cancelled" : "claimed",
          returned0: big(cancelled ? a.returned0 : a.amount0), returned1: big(cancelled ? a.returned1 : a.amount1),
          closed_block: l.blockNumber, closed_tx: l.txHash, closed_log_index: l.logIndex, closed_at: ts(t),
        });
        break;
      }

      // ---------------- launchpad
      case "launchpad.LaunchCreated": {
        const tk = token(a.token);
        const weth = A.weth!;
        const [t0, t1] = weth < tk ? [weth, tk] : [tk, weth];
        b.add("launches", tk, {
          chain_id: chainId, token: tk, creator: a.creator, name: a.name, symbol: a.symbol, metadata_uri: a.metadataURI || null,
          created_at: ts(t), created_block: l.blockNumber, created_tx: l.txHash, created_log_index: l.logIndex,
        }, true);
        addPool(b, {
          pool_id: tk, venue: "LAUNCH", pool_address: l.address, token0: t0, token1: t1, launch_token: tk, mode: "plain", reserves_from_events: false,
          creator: a.creator, fee_pips: 10_000, created_at: ts(t), created_block: l.blockNumber, created_tx: l.txHash,
        });
        b.add("tokens", tk, { chain_id: chainId, address: tk, symbol: a.symbol, name: a.name, decimals: 18, kind: "launch" }, true);
        break;
      }
      case "launchpad.Trade": {
        const tk = a.token as string;
        b.add("launch_trades", `${l.txHash}:${l.logIndex}`, {
          ...base(l, t), token: tk, trader: a.trader, is_buy: a.isBuy, weth_amount: big(a.wethAmount), token_amount: big(a.tokenAmount), fee: big(a.fee),
          real_weth_after: big(a.realWethAfter), amount_usd: usdOne(A.weth!, BigInt(a.wethAmount)),
        });
        b.patch("launches", tk, { chain_id: chainId, token: tk }, { real_weth: big(a.realWethAfter) });
        touched.add(tk);
        break;
      }
      case "launchpad.Graduated": {
        const tk = a.token as string;
        const v4 = hexId(a.v4PoolId);
        b.patch("launches", tk, { chain_id: chainId, token: tk }, {
          graduated: true, v4_pool_id: v4, position_id: String(a.positionId),
          graduation_weth: big(a.wethLiquidity), graduation_tokens: big(a.tokenLiquidity), graduated_at: ts(t), graduated_block: l.blockNumber, graduated_tx: l.txHash, graduated_log_index: l.logIndex,
        });
        b.add("pools", tk, { chain_id: chainId, pool_id: tk, ...poolKeys(tk), enabled: false }, true);
        if (pools.has(v4)) b.add("pools", v4, { chain_id: chainId, pool_id: v4, ...poolKeys(v4), launch_token: tk }, true);
        touched.add(tk);
        break;
      }

      // ---------------- router
      case "router.RouteExecuted":
        b.add("route_executions", `${l.txHash}:${l.logIndex}`, {
          ...base(l, t), sender: a.sender, recipient: a.recipient, token_in: token(a.tokenIn), token_out: token(a.tokenOut), amount_in: big(a.amountIn), amount_out: big(a.amountOut),
          hops: Number(a.hops), amount_usd: usdOne(a.tokenIn, BigInt(a.amountIn)) ?? usdOne(a.tokenOut, BigInt(a.amountOut)),
        });
        break;

      // ---------------- credit
      case "lendingVault.Borrowed":
      case "lendingVault.Repaid":
      case "lendingVault.Deposit":
      case "lendingVault.Withdraw":
      case "lendingVault.InterestAccrued":
        b.add("vault_events", `${l.txHash}:${l.logIndex}`, {
          ...base(l, t), source: "vault", kind: l.eventName, account: a.owner ?? a.to ?? a.from ?? null, counterparty: a.sender ?? a.receiver ?? null,
          assets: big(a.assets ?? a.interest ?? null), shares: big(a.shares ?? a.debtShares ?? null),
          extra: l.eventName === "InterestAccrued" ? { reserves: String(a.reserves), borrowIndexRay: String(a.borrowIndexRay) } : {},
        });
        break;
      case "creditManager.Pledged":
      case "creditManager.Released":
      case "creditManager.Borrow":
      case "creditManager.Repay":
      case "creditManager.Liquidated":
        b.add("vault_events", `${l.txHash}:${l.logIndex}`, {
          ...base(l, t), source: "credit", kind: l.eventName, token_id: String(a.tokenId), account: a.owner ?? a.payer ?? a.liquidator ?? null,
          assets: big(a.assets ?? a.debtRepaid ?? null), extra: a.collateralValueUsd !== undefined ? { collateralValueUsd: scaleE18(BigInt(a.collateralValueUsd)) } : {},
        });
        break;

      // ---------------- buyback
      case "buyback.RevenueReceived":
        b.add("buybacks", `${l.txHash}:${l.logIndex}`, {
          ...base(l, t), kind: "revenue", token: a.token === ZERO_ADDRESS ? A.weth : token(a.token), amount: big(a.amount), from_address: a.from,
          amount_usd: usdOne(a.token === ZERO_ADDRESS ? A.weth! : a.token, BigInt(a.amount)),
        });
        break;
      case "buyback.BuybackExecuted":
        b.add("buybacks", `${l.txHash}:${l.logIndex}`, {
          ...base(l, t), kind: "buyback", token: a.tokenIn === ZERO_ADDRESS ? A.weth : token(a.tokenIn), amount: big(a.amountIn), aeth_bought: big(a.aethBought),
          aeth_burned: big(a.aethBurned), to_treasury: big(a.toTreasury), amount_usd: usdOne(a.tokenIn === ZERO_ADDRESS ? A.weth! : a.tokenIn, BigInt(a.amountIn)),
        });
        break;
    }
  }

  // Pool rows always carry their NOT NULL columns so they can be upserted.
  function poolKeys(id: string) {
    const p = pools.get(id)!;
    return { venue: p.venue, token0: p.token0, token1: p.token1 };
  }

  function decimalsOf(a: string) {
    return tokens.get(a)?.decimals ?? depTokens.get(a)?.decimals ?? 18;
  }
  function priceOf(t0: string, t1: string, sqrt: bigint) {
    return priceFromSqrtX96(BigInt(sqrt), decimalsOf(t0), decimalsOf(t1));
  }
  function binPrice(p: PoolRow, id: number) {
    const step = binSteps.get(p.pool_id) ?? 0;
    return step ? priceFromBin(id, step, decimalsOf(p.token0), decimalsOf(p.token1)) : null;
  }
  function usdOne(tk: string, raw: bigint) {
    const px = tokens.get(tk.toLowerCase())?.price_usd;
    return px ? toHuman(raw, decimalsOf(tk.toLowerCase())) * px : null;
  }
  function usdOf(tIn: string, aIn: bigint, tOut: string, aOut: bigint, fee: bigint) {
    const priced = (a: string) => ({ decimals: decimalsOf(a), price: tokens.get(a)?.price_usd ?? null });
    const { amountUsd, feeUsd } = swapUsd(aIn, priced(tIn), aOut, priced(tOut), fee);
    return { amount_usd: amountUsd, fee_usd: feeUsd };
  }

  async function loadTokens(b: Batch) {
    const list = [...newTokens].filter((a) => !tokens.has(a));
    for (const a of list) {
      const d = depTokens.get(a);
      let symbol = d?.symbol;
      let name = d?.name;
      let decimals = d?.decimals;
      if (!symbol || decimals === undefined) {
        const [s, n, dec] = await Promise.all([
          client.readContract({ address: a as Hex, abi: erc20Abi, functionName: "symbol" }).catch(() => "?"),
          client.readContract({ address: a as Hex, abi: erc20Abi, functionName: "name" }).catch(() => ""),
          client.readContract({ address: a as Hex, abi: erc20Abi, functionName: "decimals" }).catch(() => 18),
        ]);
        symbol ??= String(s);
        name ??= String(n);
        decimals ??= Number(dec);
      }
      const kind = d?.kind ?? (a === A.weth ? "canonical" : "unknown");
      tokens.set(a, { address: a, symbol: symbol!, decimals: decimals!, kind, asset_class: null, price_usd: null });
      b.add("tokens", a, {
        chain_id: chainId, address: a, symbol, name: name ?? "", decimals, kind, is_stable: isStableToken(symbol, kind),
        ...(b.tables.tokens?.get(a) ?? {}),
      }, true);
    }
    newTokens.clear();
  }

  // ---------------------------------------------------------------- chain reads + prices
  const chainMeta = await refreshChainState(db, client, chainId, A, pools, tokens, touched);

  const { data: refreshed, error: refreshErr } = await db.rpc("aethra_refresh", {
    p_chain: chainId,
    p_pools: touched.size ? [...touched] : null,
    p_since: since ? ts(since) : null,
  });
  if (refreshErr) throw new Error(`aethra_refresh: ${refreshErr.message}`);

  const caughtUp = from > safe;
  await db.from("indexer_state").upsert({
    chain_id: chainId,
    last_block: from - 1,
    head_block: head,
    status: caughtUp ? "ok" : "syncing",
    error: null,
    chunk_size: sizer.size,
    last_run_ms: Date.now() - started,
    logs_indexed: (state?.logs_indexed ?? 0) + logsIndexed,
    meta: { ...meta, ...chainMeta, deployment: depHash },
    updated_at: new Date().toISOString(),
  });
  return { chainId, from: lastBlock, to: from - 1, head, logs: logsIndexed, pools: touched.size, caughtUp, refresh: refreshed };
}

/** Reserves/prices for non-event-sourced venues, current fees, and USD prices for every token. */
async function refreshChainState(
  db: SupabaseClient,
  client: PublicClient,
  chainId: number,
  A: Record<string, string | null>,
  pools: Map<string, PoolRow>,
  tokens: Map<string, TokenRow>,
  touched: Set<string>,
): Promise<Record<string, unknown>> {
  const meta: Record<string, unknown> = {};
  const dec = (a: string) => tokens.get(a)?.decimals ?? 18;
  const updates: Row[] = [];

  // DAMM: reserves + price + fee; DLMM: fee + active bin
  const live = [...pools.values()].filter((p) => p.venue === "DAMM" || p.venue === "DLMM");
  for (const part of chunked(live, 25)) {
    await Promise.all(part.map(async (p) => {
      const addr = p.pool_address as Hex;
      try {
        if (p.venue === "DAMM") {
          const [sqrt, liq, res, fee] = await Promise.all([
            client.readContract({ address: addr, abi: dammPoolAbi, functionName: "sqrtPriceX96" }),
            client.readContract({ address: addr, abi: dammPoolAbi, functionName: "liquidity" }),
            client.readContract({ address: addr, abi: dammPoolAbi, functionName: "reserves" }),
            client.readContract({ address: addr, abi: dammPoolAbi, functionName: "currentFee" }),
          ]);
          updates.push({
            chain_id: chainId, pool_id: p.pool_id, venue: p.venue, token0: p.token0, token1: p.token1, sqrt_price_x96: big(sqrt), liquidity: big(liq),
            reserve0: big(res[0]), reserve1: big(res[1]), fee_pips: Number(fee), price: priceFromSqrtX96(sqrt, dec(p.token0), dec(p.token1)),
          });
        } else {
          const [active, fee] = await Promise.all([
            client.readContract({ address: addr, abi: dlmmPoolAbi, functionName: "activeId" }),
            client.readContract({ address: addr, abi: dlmmPoolAbi, functionName: "currentFee" }),
          ]);
          updates.push({ chain_id: chainId, pool_id: p.pool_id, venue: p.venue, token0: p.token0, token1: p.token1, active_index: Number(active), fee_pips: Number(fee) });
        }
      } catch {
        // pool unreadable this run; keep the previous state
      }
    }));
  }

  // LAUNCH: reserves and price from the curve state
  if (A.launchpad) {
    const launchAbi = [...launchpadAbi, ...[{ type: "function", name: "launch", stateMutability: "view", inputs: [{ name: "token", type: "address" }], outputs: [{ type: "tuple", components: [
      { name: "token", type: "address" }, { name: "creator", type: "address" }, { name: "virtualWeth", type: "uint128" }, { name: "virtualToken", type: "uint128" },
      { name: "realWeth", type: "uint128" }, { name: "realToken", type: "uint128" }, { name: "createdAt", type: "uint64" }, { name: "graduated", type: "bool" }, { name: "positionId", type: "uint256" },
    ] }] } as const]];
    const curves = [...pools.values()].filter((p) => p.venue === "LAUNCH" && touched.has(p.pool_id));
    for (const p of curves) {
      try {
        const l = await client.readContract({ address: A.launchpad as Hex, abi: launchAbi, functionName: "launch", args: [p.pool_id as Hex] });
        const wethIs0 = p.token0 === A.weth;
        const w = Number(l.virtualWeth + l.realWeth) / 1e18;
        const tk = Number(l.virtualToken + l.realToken) / 1e18;
        const priceWethPerToken = w / tk;
        updates.push({
          chain_id: chainId, pool_id: p.pool_id, venue: p.venue, token0: p.token0, token1: p.token1,
          reserve0: big(wethIs0 ? l.realWeth : l.realToken), reserve1: big(wethIs0 ? l.realToken : l.realWeth),
          price: wethIs0 ? 1 / priceWethPerToken : priceWethPerToken, enabled: !l.graduated,
        });
      } catch {
        // ignore
      }
    }
    try {
      const threshold = await client.readContract({ address: A.launchpad as Hex, abi: launchpadAbi, functionName: "graduationThreshold" });
      meta.graduationThreshold = String(threshold);
    } catch {
      // ignore
    }
  }
  await upsertGrouped(db, "pools", updates);

  // USD prices: oracle assets from the hub, then pool-derived for the rest
  const { data: tokRows } = await db.from("tokens").select("address,symbol,kind,decimals,asset_class").eq("chain_id", chainId);
  const oracle = new Map<string, number>();
  await Promise.all((tokRows ?? []).filter((t) => t.asset_class && t.asset_class !== "NONE").map(async (t) => {
    try {
      const [px, fresh] = await client.readContract({ address: A.hub as Hex, abi: hubAbi, functionName: "tryGetPrice", args: [t.address as Hex] });
      const v = scaleE18(px);
      if (fresh && v) oracle.set(t.address, v);
    } catch {
      // no feed
    }
  }));
  const { data: poolPx } = await db.from("pools").select("pool_id,venue,token0,token1,price,reserve0,reserve1,enabled").eq("chain_id", chainId);
  const prices = derivePrices(
    (tokRows ?? []).map((t) => ({ address: t.address, symbol: t.symbol, kind: t.kind, decimals: t.decimals, oraclePrice: oracle.get(t.address) ?? null })),
    (poolPx ?? []).map((p) => ({ ...p, reserve0: BigInt(p.reserve0 ?? 0), reserve1: BigInt(p.reserve1 ?? 0) })),
  );
  const now = new Date().toISOString();
  const rows = [...prices.entries()].map(([address, p]) => ({
    chain_id: chainId, address, price_usd: p.price, price_source: p.via ? `pool:${p.via}` : p.source, price_updated_at: now,
  }));
  await upsertGrouped(db, "tokens", rows);
  return meta;
}

// ------------------------------------------------------------------ entry

Deno.serve(async (req) => {
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  // pg_cron sends INDEXER_TOKEN (Vault `indexer_token`); the service key also works for manual runs.
  // A dedicated token avoids depending on which service key format the runtime exposes.
  const allowed = [Deno.env.get("INDEXER_TOKEN"), key].filter((v): v is string => !!v).map((v) => `Bearer ${v}`);
  if (!allowed.includes(req.headers.get("authorization") ?? "")) return new Response("unauthorized", { status: 401 });
  const db = createClient(Deno.env.get("SUPABASE_URL")!, key, { auth: { persistSession: false } });
  const url = new URL(req.url);
  const only = url.searchParams.get("chain");
  const deadline = Date.now() + BUDGET_MS;

  let chainIds: number[];
  if (only) chainIds = [Number(only)];
  else {
    const { data } = await db.from("chains").select("chain_id").eq("enabled", true);
    chainIds = (data ?? []).map((c) => c.chain_id);
  }

  const results = [];
  for (const id of chainIds) {
    try {
      results.push(await indexChain(db, id, deadline));
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      await db.from("indexer_state").upsert({ chain_id: id, status: "error", error: msg.slice(0, 1000), updated_at: new Date().toISOString() });
      results.push({ chainId: id, error: msg });
    }
  }
  return Response.json({ ok: true, results });
});
