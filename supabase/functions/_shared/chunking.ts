// Block range planning and adaptive chunk sizing for eth_getLogs.

export const DEFAULT_CHUNK = 2_000;
export const CONFIRMATIONS = 2;
export const RESCAN_BLOCKS = 20;

/**
 * First block to scan this run. With a cursor we step back `rescan` blocks (light reorg tolerance;
 * writes are idempotent). Without one we start at the deployment start block.
 */
export function planStart(lastBlock: number | null, startBlock: number, rescan = RESCAN_BLOCKS): number {
  if (lastBlock === null || lastBlock === undefined) return Math.max(0, startBlock);
  return Math.max(startBlock, lastBlock + 1 - rescan, 0);
}

/** Highest block we index: head minus the confirmation margin. */
export function safeHead(head: number, confirmations = CONFIRMATIONS): number {
  return Math.max(0, head - confirmations);
}

/** Inclusive [from, to] for the next chunk, or null when caught up. */
export function nextRange(from: number, safe: number, size: number): { from: number; to: number } | null {
  if (from > safe) return null;
  return { from, to: Math.min(safe, from + Math.max(1, size) - 1) };
}

/**
 * Adaptive chunk size: halve on RPC errors (down to 1 block), grow back x2 after a few clean chunks
 * (up to `max`). `exhausted` means a 1-block range still failed.
 */
export class ChunkSizer {
  size: number;
  readonly max: number;
  private streak = 0;
  failures = 0;

  constructor(initial = DEFAULT_CHUNK, max = initial) {
    this.size = Math.max(1, initial);
    this.max = Math.max(this.size, max);
  }

  /** Returns false when the range can no longer be split. */
  fail(): boolean {
    this.failures++;
    this.streak = 0;
    if (this.size <= 1) return false;
    this.size = Math.max(1, Math.floor(this.size / 2));
    return true;
  }

  success(): void {
    this.streak++;
    if (this.streak >= 3 && this.size < this.max) {
      this.size = Math.min(this.max, this.size * 2);
      this.streak = 0;
    }
  }
}

/** Exponential backoff with a cap, for retrying transient RPC errors. */
export function backoffMs(attempt: number, base = 250, cap = 4_000): number {
  return Math.min(cap, base * 2 ** Math.max(0, attempt));
}

/** Split a list into chunks of `n` (address / topic filters). */
export function chunked<T>(items: T[], n: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += n) out.push(items.slice(i, i + n));
  return out;
}
