import { describe, expect, it } from "vitest";
import { amountsForLiquidity, fullRangeTicks, liquidityForAmounts, priceToSqrtPriceX96, priceToTick, sqrtPriceX96ToPrice, tickToPrice } from "@/lib/v4math";
import { apyFromPerSecondWad, healthState, kinkBorrowRate } from "@/lib/credit";
import { minReceived } from "@/lib/routing";

describe("v4 math", () => {
  it("tick <-> price", () => {
    expect(tickToPrice(0)).toBe(1);
    expect(priceToTick(tickToPrice(6000))).toBe(6000);
    expect(priceToTick(tickToPrice(6010), 60)).toBe(6000);
  });
  it("sqrtPrice round trip", () => {
    const p = 2500;
    const s = priceToSqrtPriceX96(p, 18, 6);
    expect(Math.abs(sqrtPriceX96ToPrice(s, 18, 6) / p - 1)).toBeLessThan(1e-9);
  });
  it("full range aligned", () => {
    expect(fullRangeTicks(60)).toEqual([-887220, 887220]);
  });
  it("liquidity never exceeds the amounts", () => {
    const s = priceToSqrtPriceX96(1);
    const L = liquidityForAmounts(s, -600, 600, 10n ** 18n, 10n ** 18n);
    const { amount0, amount1 } = amountsForLiquidity(s, -600, 600, L);
    expect(amount0).toBeLessThanOrEqual(1e18);
    expect(amount1).toBeLessThanOrEqual(1e18);
    expect(amount0).toBeGreaterThan(0.99e18);
  });
});

describe("credit + routing", () => {
  it("apy from per-second rate", () => {
    const apy = apyFromPerSecondWad(3_170_979_198n); // ~10% APR
    expect(apy).toBeGreaterThan(10);
    expect(apy).toBeLessThan(10.6);
  });
  it("kink model", () => {
    expect(kinkBorrowRate(0)).toBe(0);
    expect(kinkBorrowRate(80)).toBe(8);
    expect(kinkBorrowRate(100)).toBe(128);
  });
  it("health state", () => {
    expect(healthState(2)).toBe("safe");
    expect(healthState(1.2)).toBe("warning");
    expect(healthState(1.05)).toBe("danger");
    expect(healthState(null)).toBe("none");
  });
  it("min received", () => {
    expect(minReceived(10_000n, 0.5)).toBe(9_950n);
    expect(minReceived(10_000n, 1)).toBe(9_900n);
  });
});
