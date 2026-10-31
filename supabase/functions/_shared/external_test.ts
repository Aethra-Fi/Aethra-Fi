import { type Candidate, decodeLiquidity, decodeSlot0, liquiditySlot, selectTop, slot0Slot, virtualValueUsd } from "./external.ts";

function assert(cond: boolean, msg: string) {
  if (!cond) throw new Error(msg);
}
const near = (a: number, b: number, tol = 0.01) => Math.abs(a - b) <= Math.abs(b) * tol;

// pool of 10 ETH against 20,000 USDG at 2,000 USDG per ETH: raw price = 2000e6 / 1e18
const sqrtP = BigInt(Math.floor(Math.sqrt(2000e6 / 1e18) * 2 ** 96));
const L = (10n * 10n ** 18n * sqrtP) / 2n ** 96n; // L = x * sqrtP

Deno.test("virtualValueUsd values the priced side, doubled", () => {
  const eth = { decimals: 18, priceUsd: 2000 };
  const usdg = { decimals: 6, priceUsd: 1 };
  assert(near(virtualValueUsd(L, sqrtP, eth, null), 40_000), "token0 anchor");
  assert(near(virtualValueUsd(L, sqrtP, null, usdg), 40_000), "token1 anchor");
});

Deno.test("virtualValueUsd is zero without liquidity, price or an anchor", () => {
  const eth = { decimals: 18, priceUsd: 2000 };
  assert(virtualValueUsd(0n, sqrtP, eth, null) === 0, "no liquidity");
  assert(virtualValueUsd(L, 0n, eth, null) === 0, "no price");
  assert(virtualValueUsd(L, sqrtP, null, null) === 0, "no anchor");
});

Deno.test("decodeSlot0 unpacks price, signed tick and lp fee", () => {
  const word = (3000n << 208n) | ((0x1000000n - 201_064n) << 160n) | 12345n;
  const s = decodeSlot0(word);
  assert(s.sqrtPriceX96 === 12345n, "sqrt");
  assert(s.tick === -201_064, `tick ${s.tick}`);
  assert(s.lpFee === 3000, "fee");
  assert(decodeLiquidity((7n << 128n) | 99n) === 99n, "liquidity masks to 128 bits");
});

Deno.test("liquidity sits three slots after slot0", () => {
  const id = "0x6e1de9edc2201470f3c53a2cfe05b316683b7e512748aff3a1bbd680e2ab8f18";
  assert(liquiditySlot(id) === slot0Slot(id) + 3n, "offset");
});

Deno.test("selectTop drops dust, idle and excluded pools, best first", () => {
  const mk = (id: string, valueUsd: number, swaps: number): Candidate => ({
    id, currency0: "", currency1: "", hooks: "", fee: 0, tickSpacing: 60, createdBlock: 1, sqrtPriceX96: 1n, tick: 0, liquidity: 1n, swaps, valueUsd,
  });
  const out = selectTop([mk("a", 5_000, 10), mk("b", 50, 100), mk("c", 9_000, 1), mk("d", 20_000, 5), mk("e", 7_000, 3)], {
    minUsd: 1_000, minSwaps: 3, limit: 2, exclude: new Set(["d"]),
  });
  assert(out.map((c) => c.id).join() === "e,a", `got ${out.map((c) => c.id).join()}`);
});
