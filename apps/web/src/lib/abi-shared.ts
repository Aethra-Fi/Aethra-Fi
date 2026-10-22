// Shared ABI tuple shapes (mirrors packages/contracts/src/interfaces).
export const poolKeyComponents = [
  { name: "currency0", type: "address" },
  { name: "currency1", type: "address" },
  { name: "fee", type: "uint24" },
  { name: "tickSpacing", type: "int24" },
  { name: "hooks", type: "address" },
] as const;

export const hopComponents = [
  { name: "venue", type: "uint8" },
  { name: "pool", type: "address" },
  { name: "tokenIn", type: "address" },
  { name: "tokenOut", type: "address" },
  { name: "data", type: "bytes" },
] as const;
