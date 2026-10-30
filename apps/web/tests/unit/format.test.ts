import { describe, expect, it } from "vitest";
import { formatFeePips, formatPct, formatTokenAmount, formatUsd, parseAmount, shortAddress, timeAgo } from "@/lib/format";

describe("format", () => {
  it("formats usd", () => {
    expect(formatUsd(1234.5)).toBe("$1,234.50");
    expect(formatUsd(1_250_000, { compact: true })).toBe("$1.25M");
    expect(formatUsd(null)).toBe("—");
    expect(formatUsd(0.00123)).toBe("$0.00123");
  });
  it("formats fee pips", () => {
    expect(formatFeePips(3000)).toBe("0.3%");
    expect(formatFeePips(500)).toBe("0.05%");
    expect(formatFeePips(10000)).toBe("1.0%");
  });
  it("formats pct with sign", () => {
    expect(formatPct(1.234, 2, { sign: true })).toBe("+1.23%");
    expect(formatPct(-0.5)).toBe("-0.50%");
  });
  it("formats token amounts", () => {
    expect(formatTokenAmount(1_500_000_000_000_000_000n, 18)).toBe("1.5");
    expect(formatTokenAmount("123456789", 6, 2)).toBe("123.45");
    expect(formatTokenAmount(1n, 18, 4)).toBe("<0.0001");
    expect(formatTokenAmount(0n, 18)).toBe("0");
    expect(formatTokenAmount("garbage", 18)).toBe("—");
  });
  it("parses amounts", () => {
    expect(parseAmount("1.5", 18)).toBe(1_500_000_000_000_000_000n);
    expect(parseAmount("0.000001", 6)).toBe(1n);
    expect(parseAmount("0.0000001", 6)).toBeNull();
    expect(parseAmount("abc", 6)).toBeNull();
    expect(parseAmount("1,000", 0)).toBe(1000n);
  });
  it("shortens addresses", () => {
    expect(shortAddress("0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C")).toBe("0xd09D…9a7C");
  });
  it("time ago", () => {
    const now = Date.parse("2026-01-01T00:10:00Z");
    expect(timeAgo("2026-01-01T00:09:30Z", now)).toBe("30s ago");
    expect(timeAgo("2026-01-01T00:00:00Z", now)).toBe("10m ago");
  });
});
