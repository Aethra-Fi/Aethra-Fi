import { logTimestamp } from "./normalize.ts";

Deno.test("logTimestamp reads a filled block time", () => {
  if (logTimestamp({ blockTimestamp: "0x6543c0f0" }) !== 1698939120) throw new Error("wrong time");
});

Deno.test("logTimestamp treats 0x0 and missing as unknown", () => {
  for (const raw of [{ blockTimestamp: "0x0" }, { blockTimestamp: undefined }, { blockTimestamp: "" }]) {
    if (logTimestamp(raw) !== null) throw new Error(`expected null for ${raw.blockTimestamp}`);
  }
});
