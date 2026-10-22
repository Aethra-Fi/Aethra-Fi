import { describe, expect, it } from "vitest";
import { binFromPrice, distributeBins, priceFromBin, shapeWeight } from "@/lib/dlmm";

describe("price <-> bin", () => {
  it("bin 0 is price 1", () => {
    expect(priceFromBin(0, 25)).toBe(1);
    expect(binFromPrice(1, 25)).toBe(0);
  });
  it("round trips across bin steps and decimals", () => {
    for (const step of [1, 10, 25, 100]) {
      for (const id of [-5000, -321, -1, 0, 1, 77, 4200]) {
        expect(binFromPrice(priceFromBin(id, step), step)).toBe(id);
        expect(binFromPrice(priceFromBin(id, step, 18, 6), step, 18, 6)).toBe(id);
      }
    }
  });
  it("applies decimals", () => {
    // 1 WETH (18) = 2500 USDG (6): raw price = 2500e6/1e18
    const id = binFromPrice(2500, 10, 18, 6);
    expect(Math.abs(priceFromBin(id, 10, 18, 6) / 2500 - 1)).toBeLessThan(0.0006);
  });
  it("rounds directionally between bins", () => {
    const mid = Math.sqrt(priceFromBin(10, 25) * priceFromBin(11, 25));
    expect(binFromPrice(mid, 25, 18, 18, "up")).toBe(11);
    expect(binFromPrice(mid, 25, 18, 18, "down")).toBe(10);
  });
  it("rejects bad input", () => {
    expect(() => binFromPrice(0, 25)).toThrow();
    expect(() => binFromPrice(1, 0)).toThrow();
  });
});

describe("bin shapes", () => {
  it("weights by shape", () => {
    expect(shapeWeight("spot", 3, 5)).toBe(1);
    expect(shapeWeight("spot", 6, 5)).toBe(0);
    expect(shapeWeight("curve", 0, 6)).toBeGreaterThan(shapeWeight("curve", 4, 6));
    expect(shapeWeight("bidask", 5, 5)).toBeGreaterThan(shapeWeight("bidask", 0, 5));
  });

  for (const shape of ["spot", "curve", "bidask"] as const) {
    it(`${shape}: amounts sum exactly and respect sides`, () => {
      const amount0 = 1_000_000_000_000_000_007n;
      const amount1 = 3_333_333n;
      const d = distributeBins({ activeId: 100, radius: 7, shape, amount0, amount1 });
      expect(d.ids).toHaveLength(15);
      expect(d.ids[0]).toBe(93);
      expect(d.amounts0.reduce((a, b) => a + b, 0n)).toBe(amount0);
      expect(d.amounts1.reduce((a, b) => a + b, 0n)).toBe(amount1);
      d.ids.forEach((id, i) => {
        if (id < 100) expect(d.amounts0[i]).toBe(0n);
        if (id > 100) expect(d.amounts1[i]).toBe(0n);
      });
    });
  }

  it("radius 0 puts everything in the active bin", () => {
    const d = distributeBins({ activeId: -3, radius: 0, shape: "curve", amount0: 10n, amount1: 20n });
    expect(d.ids).toEqual([-3]);
    expect(d.amounts0).toEqual([10n]);
    expect(d.amounts1).toEqual([20n]);
  });

  it("one-sided deposit leaves the other side empty", () => {
    const d = distributeBins({ activeId: 0, radius: 3, shape: "spot", amount0: 99n, amount1: 0n });
    expect(d.amounts1.every((a) => a === 0n)).toBe(true);
    expect(d.weights1.every((w) => w === 0)).toBe(true);
  });
});
