import { describe, expect, it } from "vitest";
import {
  binDistribution,
  binToPrice,
  formatFeePips,
  fullRangeTicks,
  nearestUsableTick,
  priceToBin,
  priceToSqrtPriceX96,
  priceToTick,
  sqrtPriceX96ToPrice,
  tickToPrice,
} from "./math.js";
import { candidateRoutes, encodePoolKey, minOut, sortTokens } from "./router.js";
import { Venue } from "./types.js";

describe("price math", () => {
  it("round-trips sqrtPriceX96 with mixed decimals", () => {
    const s = priceToSqrtPriceX96(2400, 18, 6);
    expect(sqrtPriceX96ToPrice(s, 18, 6)).toBeCloseTo(2400, 2);
    const t = priceToSqrtPriceX96(1 / 2400, 6, 18);
    expect(sqrtPriceX96ToPrice(t, 6, 18)).toBeCloseTo(1 / 2400, 8);
  });

  it("round-trips ticks", () => {
    const tick = priceToTick(250, 18, 18);
    expect(tickToPrice(tick, 18, 18)).toBeLessThanOrEqual(250);
    expect(tickToPrice(tick + 1, 18, 18)).toBeGreaterThan(250);
  });

  it("rounds ticks to spacing and computes full range", () => {
    expect(nearestUsableTick(-15, 10)).toBe(-20);
    expect(nearestUsableTick(15, 10)).toBe(10);
    expect(fullRangeTicks(60)).toEqual([-887220, 887220]);
  });

  it("maps prices to DLMM bins and back", () => {
    for (const p of [0.5, 1, 1.7, 2400]) {
      const id = priceToBin(p, 25, 18, 18);
      expect(binToPrice(id, 25, 18, 18)).toBeLessThanOrEqual(p * (1 + 1e-9));
      expect(binToPrice(id + 1, 25, 18, 18)).toBeGreaterThan(p);
    }
    expect(priceToBin(1, 25, 18, 18)).toBe(0);
  });

  it("formats fees", () => {
    expect(formatFeePips(3000)).toBe("0.30%");
    expect(formatFeePips(500)).toBe("0.05%");
    expect(formatFeePips(10_000)).toBe("1.00%");
  });

  it("builds normalized bin distributions", () => {
    for (const shape of ["spot", "curve", "bidask"] as const) {
      const d = binDistribution(100, 5, shape);
      expect(d.ids).toHaveLength(11);
      expect(d.weight0.reduce((a, b) => a + b)).toBeCloseTo(1);
      expect(d.weight1.reduce((a, b) => a + b)).toBeCloseTo(1);
      // token0 only at/above active, token1 only at/below
      expect(d.weight0[0]).toBe(0);
      expect(d.weight1[10]).toBe(0);
    }
  });
});

describe("routing helpers", () => {
  const A = "0x0000000000000000000000000000000000000001" as const;
  const B = "0x0000000000000000000000000000000000000002" as const;
  const W = "0x0000000000000000000000000000000000000003" as const;
  const P = "0x00000000000000000000000000000000000000aa" as const;

  it("sorts tokens numerically", () => {
    expect(sortTokens(B, A)).toEqual([A, B]);
  });

  it("enumerates direct and two-hop routes", () => {
    const pools = [
      { venue: Venue.DLMM, token0: A, token1: B, address: P },
      { venue: Venue.DAMM, token0: A, token1: W, address: P },
      { venue: Venue.DAMM, token0: B, token1: W, address: P },
    ];
    const routes = candidateRoutes(pools, A, B, [W]);
    expect(routes).toHaveLength(2);
    expect(routes[0]).toHaveLength(1);
    expect(routes[1]).toHaveLength(2);
    expect(routes[1]![0]!.tokenOut).toBe(W);
  });

  it("encodes pool keys and applies slippage", () => {
    const enc = encodePoolKey({ currency0: A, currency1: B, fee: 0x800000, tickSpacing: 10, hooks: W });
    expect(enc.length).toBe(2 + 64 * 5);
    expect(minOut(10_000n, 50)).toBe(9950n);
  });
});
