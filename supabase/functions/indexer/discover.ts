// External pool discovery: which non-Aethra Uniswap v4 pools are worth tracking right now.
// 1. count Swap events per pool over a recent window (pools nobody trades are not interesting),
// 2. resolve each pool's PoolKey from its Initialize event (cached in v4_pool_keys),
// 3. read active liquidity and price straight from PoolManager storage (extsload, batched through Multicall3),
// 4. value the active liquidity through a priced token and keep the best.
// Pure IO: the caller decides what to store. The math lives in _shared/external.ts.
import type { Hex, PublicClient } from "npm:viem@2.57.7";
import { chunked } from "../_shared/chunking.ts";
import {
  type Candidate,
  decodeLiquidity,
  decodeSlot0,
  liquiditySlot,
  type PricedToken,
  selectTop,
  slot0Slot,
  virtualValueUsd,
} from "../_shared/external.ts";
import { decodeLog, type RawLog, TOPICS } from "../_shared/normalize.ts";

export type GetLogs = (params: Record<string, unknown>) => Promise<RawLog[]>;

export interface PoolKeyRow {
  pool_id: string;
  currency0: string;
  currency1: string;
  fee: number;
  tick_spacing: number;
  hooks: string;
  block_number: number;
  tx_hash: string;
  sqrt_price_x96: string;
  tick: number;
}

export interface DiscoverDeps {
  client: PublicClient;
  getLogs: GetLogs;
  poolManager: string;
  multicall3: string;
  /** latest block to read (already behind the confirmation margin) */
  head: number;
  /** pools we already track, plus anything else to skip (e.g. Aethra's own) */
  skip: Set<string>;
  loadKeys: (ids: string[]) => Promise<PoolKeyRow[]>;
  saveKeys: (rows: PoolKeyRow[]) => Promise<void>;
  /** a trusted USD price for a currency (stable, oracle or WETH/ETH), else null */
  anchor: (currency: string) => PricedToken | null;
  windowBlocks: number;
  minSwaps: number;
  minUsd: number;
  limit: number;
  /** stop looking up pool keys here and carry on with what is cached; the next run resumes */
  softDeadline: number;
  /** abort (throw) when the run is out of time */
  deadline: number;
}

export interface DiscoverResult {
  picked: Candidate[];
  keyRows: Map<string, PoolKeyRow>;
  stats: { swapPools: number; candidates: number; resolved: number; unresolved: number; valued: number; picked: number };
}

const hex = (n: number) => `0x${n.toString(16)}`;
const MC3_ABI = [{
  type: "function", name: "aggregate3", stateMutability: "view", // payable on-chain; eth_call does not care
  inputs: [{ name: "calls", type: "tuple[]", components: [{ name: "target", type: "address" }, { name: "allowFailure", type: "bool" }, { name: "callData", type: "bytes" }] }],
  outputs: [{ name: "returnData", type: "tuple[]", components: [{ name: "success", type: "bool" }, { name: "returnData", type: "bytes" }] }],
}] as const;
/** extsload(bytes32) */
const EXTSLOAD = "0x1e2eaeaf";
const INIT_WINDOW = 7_500_000; // the node refuses wider ranges (8,000,000) when a topic position has one value
/** Blocks of recent Initialize events read in bulk (young pools are the common case): ~9 days */
const BULK_BLOCKS = 7_500_000;
const BULK_STEP = 750_000;

function timeLeft(deadline: number) {
  if (Date.now() > deadline) throw new Error("discovery: out of time");
}

/** Swap events per pool id over the last `window` blocks, in ranges that stay under the log limit. */
export async function recentSwapCounts(d: Pick<DiscoverDeps, "getLogs" | "poolManager" | "head" | "windowBlocks" | "deadline">): Promise<Map<string, number>> {
  const counts = new Map<string, number>();
  const floor = Math.max(0, d.head - d.windowBlocks + 1);
  let size = 10_000;
  let to = d.head;
  while (to >= floor) {
    timeLeft(d.deadline);
    const from = Math.max(floor, to - size + 1);
    try {
      const logs = await d.getLogs({ fromBlock: hex(from), toBlock: hex(to), address: d.poolManager, topics: [TOPICS.v4Swap] });
      for (const l of logs) {
        const id = l.topics[1]?.toLowerCase();
        if (id) counts.set(id, (counts.get(id) ?? 0) + 1);
      }
      to = from - 1;
    } catch (e) {
      if (size <= 250) throw e;
      size = Math.floor(size / 2);
    }
  }
  return counts;
}

/**
 * PoolKey for each id: cache first, then its Initialize event. The node allows wide ranges (8M blocks) only when each
 * topic position holds a single value, so this is one query per pool, newest window first and stopping on a hit.
 * Most active pools are young, so that is usually one query. Pools not found stay unresolved and are skipped.
 */
async function resolveKeys(d: DiscoverDeps, ids: string[]): Promise<Map<string, PoolKeyRow>> {
  const out = new Map<string, PoolKeyRow>();
  for (const part of chunked(ids, 200)) for (const r of await d.loadKeys(part)) out.set(r.pool_id, r);
  const found: PoolKeyRow[] = [];
  const rowOf = (log: RawLog): PoolKeyRow | null => {
    const ev = decodeLog(log, "poolManager");
    if (!ev || ev.eventName !== "Initialize") return null;
    const a = ev.args;
    return {
      pool_id: String(a.id).toLowerCase(), currency0: String(a.currency0).toLowerCase(), currency1: String(a.currency1).toLowerCase(),
      fee: Number(a.fee), tick_spacing: Number(a.tickSpacing), hooks: String(a.hooks).toLowerCase(),
      block_number: ev.blockNumber, tx_hash: ev.txHash, sqrt_price_x96: BigInt(a.sqrtPriceX96).toString(), tick: Number(a.tick),
    };
  };

  // 1. bulk: every Initialize of the last ~9 days in a few wide queries (no id filter, so only ~10k results fit per
  //    query: split a window in half when the node says there are too many)
  const wanted = new Set(ids.filter((id) => !out.has(id)));
  async function bulk(from: number, to: number, depth = 0): Promise<void> {
    if (wanted.size === 0 || Date.now() > d.softDeadline) return;
    let logs: RawLog[];
    try {
      logs = await d.getLogs({ fromBlock: hex(from), toBlock: hex(to), address: d.poolManager, topics: [TOPICS.v4Initialize] });
    } catch (e) {
      if (depth >= 4 || to <= from) throw e;
      const mid = Math.floor((from + to) / 2);
      await bulk(from, mid, depth + 1);
      await bulk(mid + 1, to, depth + 1);
      return;
    }
    for (const log of logs) {
      const id = log.topics[1]?.toLowerCase();
      if (!id || !wanted.has(id)) continue;
      const row = rowOf(log);
      if (!row) continue;
      wanted.delete(id);
      out.set(id, row);
      found.push(row);
    }
  }
  const floor = Math.max(0, d.head - BULK_BLOCKS + 1);
  const wins: { from: number; to: number }[] = [];
  for (let to = d.head; to >= floor; to -= BULK_STEP) wins.push({ from: Math.max(floor, to - BULK_STEP + 1), to });
  for (const batch of chunked(wins, 3)) await Promise.all(batch.map((w) => bulk(w.from, w.to)));
  if (found.length) await d.saveKeys(found.slice());

  // 2. the rest (older pools): one query per pool
  const missing = ids.filter((id) => !out.has(id));

  const lookup = async (id: string) => {
    for (let to = d.head; to >= 0; to -= INIT_WINDOW) {
      if (Date.now() > d.softDeadline) return;
      const from = Math.max(0, to - INIT_WINDOW + 1);
      const logs = await d.getLogs({ fromBlock: hex(from), toBlock: hex(to), address: d.poolManager, topics: [TOPICS.v4Initialize, id] });
      const row = logs.length ? rowOf(logs[0]) : null;
      if (!row) continue;
      out.set(id, row);
      found.push(row);
      return;
    }
  };
  // most-traded first, saved batch by batch so a timeout loses nothing
  for (const batch of chunked(missing, 4)) {
    if (Date.now() > d.softDeadline) break;
    const before = found.length;
    await Promise.all(batch.map(lookup));
    if (found.length > before) await d.saveKeys(found.slice(before));
  }
  return out;
}

/** Active liquidity and price of each pool, read from PoolManager storage. */
async function readStates(d: DiscoverDeps, ids: string[]): Promise<Map<string, { liquidity: bigint; sqrtPriceX96: bigint; tick: number }>> {
  const out = new Map<string, { liquidity: bigint; sqrtPriceX96: bigint; tick: number }>();
  const word = (n: bigint) => `0x${n.toString(16).padStart(64, "0")}`;
  for (const part of chunked(ids, 150)) {
    timeLeft(d.deadline);
    const calls = part.flatMap((id) => [slot0Slot(id), liquiditySlot(id)].map((slot) => ({
      target: d.poolManager as Hex, allowFailure: true, callData: `${EXTSLOAD}${word(slot).slice(2)}` as Hex,
    })));
    const res = await d.client.readContract({ address: d.multicall3 as Hex, abi: MC3_ABI, functionName: "aggregate3", args: [calls] });
    part.forEach((id, i) => {
      const s0 = res[2 * i];
      const lq = res[2 * i + 1];
      if (!s0.success || !lq.success) return;
      const { sqrtPriceX96, tick } = decodeSlot0(BigInt(s0.returnData));
      out.set(id, { liquidity: decodeLiquidity(BigInt(lq.returnData)), sqrtPriceX96, tick });
    });
  }
  return out;
}

export async function discoverExternal(d: DiscoverDeps): Promise<DiscoverResult> {
  const counts = await recentSwapCounts(d);
  const active = [...counts.entries()]
    .filter(([id, n]) => n >= d.minSwaps && !d.skip.has(id))
    .sort((a, b) => b[1] - a[1])
    .slice(0, 300);
  const ids = active.map(([id]) => id);

  const keys = await resolveKeys(d, ids);
  const states = await readStates(d, ids.filter((id) => keys.has(id)));

  const cands: Candidate[] = [];
  for (const [id, swaps] of active) {
    const k = keys.get(id);
    const s = states.get(id);
    if (!k || !s) continue;
    const valueUsd = virtualValueUsd(s.liquidity, s.sqrtPriceX96, d.anchor(k.currency0), d.anchor(k.currency1));
    cands.push({
      id, currency0: k.currency0, currency1: k.currency1, hooks: k.hooks, fee: k.fee, tickSpacing: k.tick_spacing,
      createdBlock: k.block_number, sqrtPriceX96: s.sqrtPriceX96, tick: s.tick, liquidity: s.liquidity, swaps, valueUsd,
    });
  }
  const picked = selectTop(cands, { minUsd: d.minUsd, minSwaps: d.minSwaps, limit: d.limit });
  return {
    picked,
    keyRows: keys,
    stats: { swapPools: counts.size, candidates: active.length, resolved: keys.size, unresolved: active.length - keys.size, valued: cands.filter((c) => c.valueUsd > 0).length, picked: picked.length },
  };
}
