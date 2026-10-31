import { describe, expect, it } from "vitest";
import type { ApiPool } from "@/lib/api";
import { candidateRoutes } from "@/lib/routing";

const A = "0x00000000000000000000000000000000000000a1";
const B = "0x00000000000000000000000000000000000000b2";
const tok = (address: string, symbol: string) => ({ address, symbol, name: symbol, decimals: 18, kind: "canonical", logo_url: null });

function pool(over: Partial<ApiPool>): ApiPool {
  return {
    pool_id: "0x01", chain_id: 4663, venue: "V4", pool_address: null, hooks: "0x0000000000000000000000000000000000000000",
    token0: tok(A, "AAA"), token1: tok(B, "BBB"), fee_pips: 3000, tick_spacing: 60, bin_step_bps: null, active_index: 0,
    sqrt_price_x96: null, mode: "plain", creator: null, tvl_usd: 1, volume_24h_usd: 0, trades_24h: 0, price_change_24h: 0,
    sparkline: [], is_fresh: false, enabled: true, created_at: "2026-10-31T00:00:00Z", ...over,
  };
}

describe("candidateRoutes", () => {
  it("routes through Aethra pools", () => {
    expect(candidateRoutes([pool({})], A, B, null)).toHaveLength(1);
  });

  it("never routes through an external pool: the Aethra router has no venue for it", () => {
    expect(candidateRoutes([pool({ external: true })], A, B, null)).toHaveLength(0);
  });
});
