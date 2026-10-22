import { hopComponents } from "./shared";

/** IAethraRouter (packages/contracts/src/interfaces/IAethraPeriphery.sol). */
export const aethraRouterAbi = [
  {
    type: "function",
    name: "swap",
    stateMutability: "payable",
    inputs: [
      { name: "hops", type: "tuple[]", components: hopComponents },
      { name: "amountIn", type: "uint256" },
      { name: "minAmountOut", type: "uint256" },
      { name: "recipient", type: "address" },
      { name: "deadline", type: "uint256" },
      { name: "unwrapETH", type: "bool" },
    ],
    outputs: [{ name: "amountOut", type: "uint256" }],
  },
  {
    type: "function",
    name: "quote",
    stateMutability: "nonpayable",
    inputs: [
      { name: "hops", type: "tuple[]", components: hopComponents },
      { name: "amountIn", type: "uint256" },
    ],
    outputs: [
      { name: "amountOut", type: "uint256" },
      { name: "hopAmounts", type: "uint256[]" },
    ],
  },
  { type: "function", name: "weth", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  {
    type: "event",
    name: "RouteExecuted",
    inputs: [
      { name: "sender", type: "address", indexed: true },
      { name: "recipient", type: "address", indexed: true },
      { name: "tokenIn", type: "address", indexed: false },
      { name: "tokenOut", type: "address", indexed: false },
      { name: "amountIn", type: "uint256", indexed: false },
      { name: "amountOut", type: "uint256", indexed: false },
      { name: "hops", type: "uint8", indexed: false },
    ],
  },
  { type: "error", name: "Expired", inputs: [] },
  { type: "error", name: "Slippage", inputs: [] },
  { type: "error", name: "BadRoute", inputs: [] },
  { type: "error", name: "BadVenue", inputs: [] },
  {
    type: "error",
    name: "QuoteResult",
    inputs: [
      { name: "amountOut", type: "uint256" },
      { name: "hopAmounts", type: "uint256[]" },
    ],
  },
] as const;
