/** IAethraLaunchpad, ILendingVault (+ ERC-4626), ICreditManager, IAethraBuyback, IAethraHub (read subset), v4 PoolManager.initialize. */
import { hopComponents, poolKeyComponents } from "./shared";

export const launchpadAbi = [
  {
    type: "function",
    name: "create",
    stateMutability: "payable",
    inputs: [
      { name: "name", type: "string" },
      { name: "symbol", type: "string" },
      { name: "metadataURI", type: "string" },
      { name: "initialBuyWeth", type: "uint256" },
    ],
    outputs: [{ name: "token", type: "address" }],
  },
  {
    type: "function",
    name: "swapExactInput",
    stateMutability: "nonpayable",
    inputs: [
      { name: "token", type: "address" },
      { name: "tokenIn", type: "address" },
      { name: "amountIn", type: "uint256" },
      { name: "minAmountOut", type: "uint256" },
      { name: "recipient", type: "address" },
      { name: "deadline", type: "uint256" },
    ],
    outputs: [{ name: "amountOut", type: "uint256" }],
  },
  {
    type: "function",
    name: "quoteExactInput",
    stateMutability: "view",
    inputs: [
      { name: "token", type: "address" },
      { name: "tokenIn", type: "address" },
      { name: "amountIn", type: "uint256" },
    ],
    outputs: [{ name: "amountOut", type: "uint256" }],
  },
  {
    type: "function",
    name: "launch",
    stateMutability: "view",
    inputs: [{ name: "token", type: "address" }],
    outputs: [
      {
        type: "tuple",
        components: [
          { name: "token", type: "address" },
          { name: "creator", type: "address" },
          { name: "virtualWeth", type: "uint128" },
          { name: "virtualToken", type: "uint128" },
          { name: "realWeth", type: "uint128" },
          { name: "realToken", type: "uint128" },
          { name: "createdAt", type: "uint64" },
          { name: "graduated", type: "bool" },
          { name: "positionId", type: "uint256" },
        ],
      },
    ],
  },
  { type: "function", name: "launches", stateMutability: "view", inputs: [], outputs: [{ type: "address[]" }] },
  { type: "function", name: "graduationThreshold", stateMutability: "view", inputs: [], outputs: [{ name: "wethTarget", type: "uint256" }] },
  { type: "function", name: "graduate", stateMutability: "nonpayable", inputs: [{ name: "token", type: "address" }], outputs: [] },
] as const;

export const lendingVaultAbi = [
  { type: "function", name: "asset", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "decimals", stateMutability: "view", inputs: [], outputs: [{ type: "uint8" }] },
  { type: "function", name: "totalAssets", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "totalBorrows", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "utilizationBps", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "borrowRatePerSecondWad", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "supplyRatePerSecondWad", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ name: "account", type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "convertToAssets", stateMutability: "view", inputs: [{ name: "shares", type: "uint256" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "maxWithdraw", stateMutability: "view", inputs: [{ name: "owner", type: "address" }], outputs: [{ type: "uint256" }] },
  {
    type: "function",
    name: "deposit",
    stateMutability: "nonpayable",
    inputs: [
      { name: "assets", type: "uint256" },
      { name: "receiver", type: "address" },
    ],
    outputs: [{ name: "shares", type: "uint256" }],
  },
  {
    type: "function",
    name: "withdraw",
    stateMutability: "nonpayable",
    inputs: [
      { name: "assets", type: "uint256" },
      { name: "receiver", type: "address" },
      { name: "owner", type: "address" },
    ],
    outputs: [{ name: "shares", type: "uint256" }],
  },
] as const;

export const creditManagerAbi = [
  { type: "function", name: "pledge", stateMutability: "nonpayable", inputs: [{ name: "tokenId", type: "uint256" }], outputs: [] },
  { type: "function", name: "release", stateMutability: "nonpayable", inputs: [{ name: "tokenId", type: "uint256" }], outputs: [] },
  {
    type: "function",
    name: "borrow",
    stateMutability: "nonpayable",
    inputs: [
      { name: "tokenId", type: "uint256" },
      { name: "assets", type: "uint256" },
      { name: "to", type: "address" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "repay",
    stateMutability: "nonpayable",
    inputs: [
      { name: "tokenId", type: "uint256" },
      { name: "assets", type: "uint256" },
    ],
    outputs: [{ name: "repaid", type: "uint256" }],
  },
  { type: "function", name: "liquidate", stateMutability: "nonpayable", inputs: [{ name: "tokenId", type: "uint256" }], outputs: [] },
  { type: "function", name: "debtOf", stateMutability: "view", inputs: [{ name: "tokenId", type: "uint256" }], outputs: [{ type: "uint256" }] },
  {
    type: "function",
    name: "health",
    stateMutability: "view",
    inputs: [{ name: "tokenId", type: "uint256" }],
    outputs: [
      { name: "valueUsdE18", type: "uint256" },
      { name: "maxBorrow", type: "uint256" },
      { name: "healthFactorE18", type: "uint256" },
    ],
  },
  { type: "function", name: "loansOf", stateMutability: "view", inputs: [{ name: "owner", type: "address" }], outputs: [{ type: "uint256[]" }] },
] as const;

export const buybackAbi = [
  { type: "function", name: "totalBurned", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "totalBought", stateMutability: "view", inputs: [{ name: "tokenIn", type: "address" }], outputs: [{ name: "spent", type: "uint256" }] },
  { type: "function", name: "aeth", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  {
    type: "function",
    name: "execute",
    stateMutability: "nonpayable",
    inputs: [
      { name: "tokenIn", type: "address" },
      { name: "amountIn", type: "uint256" },
      { name: "route", type: "tuple[]", components: hopComponents },
      { name: "minAethOut", type: "uint256" },
    ],
    outputs: [{ name: "burned", type: "uint256" }],
  },
] as const;

export const hubAbi = [
  {
    type: "function",
    name: "tryGetPrice",
    stateMutability: "view",
    inputs: [{ name: "token", type: "address" }],
    outputs: [
      { name: "priceE18", type: "uint256" },
      { name: "fresh", type: "bool" },
      { name: "marketOpen", type: "bool" },
    ],
  },
  { type: "function", name: "protocolFeeShareBps", stateMutability: "view", inputs: [], outputs: [{ type: "uint16" }] },
  { type: "function", name: "treasury", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "buyback", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "poolCount", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "assetCount", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
] as const;

/** Uniswap v4 IPoolManager.initialize (canonical PoolManager, not an Aethra contract). */
export const poolManagerAbi = [
  {
    type: "function",
    name: "initialize",
    stateMutability: "nonpayable",
    inputs: [
      { name: "key", type: "tuple", components: poolKeyComponents },
      { name: "sqrtPriceX96", type: "uint160" },
    ],
    outputs: [{ name: "tick", type: "int24" }],
  },
] as const;
