// Raw JSON-RPC logs -> decoded, ordered events tagged with the emitting contract's role.
import { decodeEventLog, type Hex, toEventSelector } from "npm:viem@2.57.7";
import { abiByRole, poolManagerAbi, type Role } from "./abis.ts";

export interface RawLog {
  address: string;
  topics: string[];
  data: string;
  blockNumber: string;
  transactionHash: string;
  logIndex: string;
  blockHash: string;
  blockTimestamp?: string;
  removed?: boolean;
}

export interface DecodedLog {
  role: Role;
  address: string;
  eventName: string;
  // deno-lint-ignore no-explicit-any
  args: Record<string, any>;
  blockNumber: number;
  logIndex: number;
  txHash: string;
  blockHash: string;
  blockTimestamp: number | null;
}

export const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

export const lower = (a: string | null | undefined): string | null => (a ? a.toLowerCase() : null);

/** Normalize decoded args: addresses and hashes lowercase; arrays kept; bigint kept. */
// deno-lint-ignore no-explicit-any
function normalizeArgs(args: any): Record<string, any> {
  // deno-lint-ignore no-explicit-any
  const out: Record<string, any> = {};
  for (const [k, v] of Object.entries(args ?? {})) {
    out[k] = typeof v === "string" && v.startsWith("0x") ? v.toLowerCase() : v;
  }
  return out;
}

/** Block time of a raw log in seconds, or null when the node did not fill it (Robinhood Chain returns `0x0`). */
export function logTimestamp(raw: Pick<RawLog, "blockTimestamp">): number | null {
  if (!raw.blockTimestamp) return null;
  const sec = Number(BigInt(raw.blockTimestamp));
  return sec > 0 ? sec : null;
}

/** Decode one log with the ABI of its role. Unknown events (e.g. ERC-20 Approval) return null. */
export function decodeLog(raw: RawLog, role: Role): DecodedLog | null {
  if (raw.removed) return null;
  if (!raw.topics?.length) return null;
  try {
    const decoded = decodeEventLog({
      abi: abiByRole[role],
      data: raw.data as Hex,
      topics: raw.topics as [Hex, ...Hex[]],
      strict: true,
    });
    return {
      role,
      address: raw.address.toLowerCase(),
      eventName: String(decoded.eventName),
      args: normalizeArgs(decoded.args),
      blockNumber: Number(BigInt(raw.blockNumber)),
      logIndex: Number(BigInt(raw.logIndex)),
      txHash: raw.transactionHash.toLowerCase(),
      blockHash: raw.blockHash?.toLowerCase() ?? "",
      blockTimestamp: logTimestamp(raw),
    };
  } catch {
    return null;
  }
}

export function sortLogs<T extends { blockNumber: number; logIndex: number }>(logs: T[]): T[] {
  return [...logs].sort((a, b) => a.blockNumber - b.blockNumber || a.logIndex - b.logIndex);
}

export function dedupeRawLogs(logs: RawLog[]): RawLog[] {
  const seen = new Set<string>();
  const out: RawLog[] = [];
  for (const l of logs) {
    const k = `${l.transactionHash.toLowerCase()}:${BigInt(l.logIndex)}`;
    if (seen.has(k)) continue;
    seen.add(k);
    out.push(l);
  }
  return out;
}

export const TOPICS = {
  v4Initialize: toEventSelector(poolManagerAbi.find((x) => x.type === "event" && x.name === "Initialize")!),
  v4Swap: toEventSelector(poolManagerAbi.find((x) => x.type === "event" && x.name === "Swap")!),
  v4ModifyLiquidity: toEventSelector(poolManagerAbi.find((x) => x.type === "event" && x.name === "ModifyLiquidity")!),
};

/** v4 dynamic-fee flag in PoolKey.fee */
export const DYNAMIC_FEE_FLAG = 0x800000;
export const UINT64_MAX = (1n << 64n) - 1n;
