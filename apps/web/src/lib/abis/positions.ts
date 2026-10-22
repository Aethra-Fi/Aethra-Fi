import { poolKeyComponents } from "./shared";

/** IAethraPositions + the ERC-721 functions the UI needs. */
export const aethraPositionsAbi = [
  {
    type: "function",
    name: "mint",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "p",
        type: "tuple",
        components: [
          { name: "key", type: "tuple", components: poolKeyComponents },
          { name: "tickLower", type: "int24" },
          { name: "tickUpper", type: "int24" },
          { name: "liquidity", type: "uint128" },
          { name: "amount0Max", type: "uint256" },
          { name: "amount1Max", type: "uint256" },
          { name: "recipient", type: "address" },
          { name: "deadline", type: "uint256" },
        ],
      },
    ],
    outputs: [
      { name: "tokenId", type: "uint256" },
      { name: "amount0", type: "uint256" },
      { name: "amount1", type: "uint256" },
    ],
  },
  {
    type: "function",
    name: "increaseLiquidity",
    stateMutability: "nonpayable",
    inputs: [
      { name: "tokenId", type: "uint256" },
      { name: "liquidity", type: "uint128" },
      { name: "amount0Max", type: "uint256" },
      { name: "amount1Max", type: "uint256" },
      { name: "deadline", type: "uint256" },
    ],
    outputs: [
      { name: "amount0", type: "uint256" },
      { name: "amount1", type: "uint256" },
    ],
  },
  {
    type: "function",
    name: "decreaseLiquidity",
    stateMutability: "nonpayable",
    inputs: [
      { name: "tokenId", type: "uint256" },
      { name: "liquidity", type: "uint128" },
      { name: "amount0Min", type: "uint256" },
      { name: "amount1Min", type: "uint256" },
      { name: "recipient", type: "address" },
      { name: "deadline", type: "uint256" },
    ],
    outputs: [
      { name: "amount0", type: "uint256" },
      { name: "amount1", type: "uint256" },
    ],
  },
  {
    type: "function",
    name: "collect",
    stateMutability: "nonpayable",
    inputs: [
      { name: "tokenId", type: "uint256" },
      { name: "recipient", type: "address" },
    ],
    outputs: [
      { name: "fee0", type: "uint256" },
      { name: "fee1", type: "uint256" },
    ],
  },
  {
    type: "function",
    name: "lock",
    stateMutability: "nonpayable",
    inputs: [
      { name: "tokenId", type: "uint256" },
      { name: "cliff", type: "uint64" },
      { name: "end", type: "uint64" },
    ],
    outputs: [],
  },
  { type: "function", name: "burn", stateMutability: "nonpayable", inputs: [{ name: "tokenId", type: "uint256" }], outputs: [] },
  {
    type: "function",
    name: "getPosition",
    stateMutability: "view",
    inputs: [{ name: "tokenId", type: "uint256" }],
    outputs: [
      {
        type: "tuple",
        components: [
          { name: "key", type: "tuple", components: poolKeyComponents },
          { name: "tickLower", type: "int24" },
          { name: "tickUpper", type: "int24" },
          { name: "liquidity", type: "uint128" },
        ],
      },
    ],
  },
  {
    type: "function",
    name: "getLock",
    stateMutability: "view",
    inputs: [{ name: "tokenId", type: "uint256" }],
    outputs: [
      {
        type: "tuple",
        components: [
          { name: "cliff", type: "uint64" },
          { name: "end", type: "uint64" },
          { name: "lockedLiquidity", type: "uint128" },
          { name: "withdrawn", type: "uint128" },
        ],
      },
    ],
  },
  { type: "function", name: "withdrawable", stateMutability: "view", inputs: [{ name: "tokenId", type: "uint256" }], outputs: [{ type: "uint128" }] },
  {
    type: "function",
    name: "positionAmounts",
    stateMutability: "view",
    inputs: [{ name: "tokenId", type: "uint256" }],
    outputs: [
      { name: "amount0", type: "uint256" },
      { name: "amount1", type: "uint256" },
    ],
  },
  { type: "function", name: "ownerOf", stateMutability: "view", inputs: [{ name: "tokenId", type: "uint256" }], outputs: [{ type: "address" }] },
  { type: "function", name: "nextTokenId", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ name: "owner", type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "getApproved", stateMutability: "view", inputs: [{ name: "tokenId", type: "uint256" }], outputs: [{ type: "address" }] },
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [
      { name: "to", type: "address" },
      { name: "tokenId", type: "uint256" },
    ],
    outputs: [],
  },
  {
    type: "event",
    name: "Minted",
    inputs: [
      { name: "tokenId", type: "uint256", indexed: true },
      { name: "owner", type: "address", indexed: true },
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "tickLower", type: "int24", indexed: false },
      { name: "tickUpper", type: "int24", indexed: false },
    ],
  },
  {
    type: "event",
    name: "Locked",
    inputs: [
      { name: "tokenId", type: "uint256", indexed: true },
      { name: "cliff", type: "uint64", indexed: false },
      { name: "end", type: "uint64", indexed: false },
      { name: "lockedLiquidity", type: "uint128", indexed: false },
    ],
  },
] as const;
