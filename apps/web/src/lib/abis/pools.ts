/** IAethraPool + IDLMMPool + IDAMMPool + factories + limit orders (IAethraPools.sol). */
const commonPool = [
  { type: "function", name: "token0", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "token1", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "currentFee", stateMutability: "view", inputs: [], outputs: [{ type: "uint24" }] },
  {
    type: "function",
    name: "quoteExactInput",
    stateMutability: "view",
    inputs: [
      { name: "tokenIn", type: "address" },
      { name: "amountIn", type: "uint256" },
    ],
    outputs: [
      { name: "amountOut", type: "uint256" },
      { name: "feePips", type: "uint24" },
    ],
  },
] as const;

export const dlmmPoolAbi = [
  ...commonPool,
  { type: "function", name: "binStepBps", stateMutability: "view", inputs: [], outputs: [{ type: "uint16" }] },
  { type: "function", name: "activeId", stateMutability: "view", inputs: [], outputs: [{ type: "int24" }] },
  {
    type: "function",
    name: "getBin",
    stateMutability: "view",
    inputs: [{ name: "id", type: "int24" }],
    outputs: [
      { name: "reserve0", type: "uint128" },
      { name: "reserve1", type: "uint128" },
      { name: "totalShares", type: "uint256" },
    ],
  },
  {
    type: "function",
    name: "sharesOf",
    stateMutability: "view",
    inputs: [
      { name: "id", type: "int24" },
      { name: "account", type: "address" },
    ],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "getBins",
    stateMutability: "view",
    inputs: [
      { name: "fromId", type: "int24" },
      { name: "toId", type: "int24" },
      { name: "maxCount", type: "uint256" },
    ],
    outputs: [
      { name: "ids", type: "int24[]" },
      { name: "reserves0", type: "uint128[]" },
      { name: "reserves1", type: "uint128[]" },
    ],
  },
  {
    type: "function",
    name: "addLiquidity",
    stateMutability: "nonpayable",
    inputs: [
      { name: "ids", type: "int24[]" },
      { name: "amounts0", type: "uint256[]" },
      { name: "amounts1", type: "uint256[]" },
      { name: "recipient", type: "address" },
      { name: "deadline", type: "uint256" },
    ],
    outputs: [{ name: "shares", type: "uint256[]" }],
  },
  {
    type: "function",
    name: "removeLiquidity",
    stateMutability: "nonpayable",
    inputs: [
      { name: "ids", type: "int24[]" },
      { name: "shares", type: "uint256[]" },
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
] as const;

export const dammPoolAbi = [
  ...commonPool,
  { type: "function", name: "sqrtPriceX96", stateMutability: "view", inputs: [], outputs: [{ type: "uint160" }] },
  { type: "function", name: "sqrtPriceLowerX96", stateMutability: "view", inputs: [], outputs: [{ type: "uint160" }] },
  { type: "function", name: "sqrtPriceUpperX96", stateMutability: "view", inputs: [], outputs: [{ type: "uint160" }] },
  { type: "function", name: "liquidity", stateMutability: "view", inputs: [], outputs: [{ type: "uint128" }] },
  {
    type: "function",
    name: "reserves",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "reserve0", type: "uint256" },
      { name: "reserve1", type: "uint256" },
    ],
  },
  { type: "function", name: "sharesOf", stateMutability: "view", inputs: [{ name: "account", type: "address" }], outputs: [{ type: "uint256" }] },
  {
    type: "function",
    name: "claimableFees",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [
      { name: "fee0", type: "uint256" },
      { name: "fee1", type: "uint256" },
    ],
  },
  {
    type: "function",
    name: "addLiquidity",
    stateMutability: "nonpayable",
    inputs: [
      { name: "amount0Max", type: "uint256" },
      { name: "amount1Max", type: "uint256" },
      { name: "minShares", type: "uint256" },
      { name: "recipient", type: "address" },
      { name: "deadline", type: "uint256" },
    ],
    outputs: [
      { name: "shares", type: "uint256" },
      { name: "amount0", type: "uint256" },
      { name: "amount1", type: "uint256" },
    ],
  },
  {
    type: "function",
    name: "removeLiquidity",
    stateMutability: "nonpayable",
    inputs: [
      { name: "shares", type: "uint256" },
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
    name: "claimFees",
    stateMutability: "nonpayable",
    inputs: [{ name: "recipient", type: "address" }],
    outputs: [
      { name: "fee0", type: "uint256" },
      { name: "fee1", type: "uint256" },
    ],
  },
] as const;

export const dlmmFactoryAbi = [
  {
    type: "function",
    name: "createPool",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "p",
        type: "tuple",
        components: [
          { name: "tokenA", type: "address" },
          { name: "tokenB", type: "address" },
          { name: "binStepBps", type: "uint16" },
          { name: "activeId", type: "int24" },
          { name: "baseFee", type: "uint24" },
          { name: "maxFee", type: "uint24" },
        ],
      },
    ],
    outputs: [{ name: "pool", type: "address" }],
  },
  {
    type: "function",
    name: "getPool",
    stateMutability: "view",
    inputs: [
      { name: "tokenA", type: "address" },
      { name: "tokenB", type: "address" },
      { name: "binStepBps", type: "uint16" },
    ],
    outputs: [{ type: "address" }],
  },
  { type: "function", name: "allPools", stateMutability: "view", inputs: [], outputs: [{ type: "address[]" }] },
] as const;

export const dammFactoryAbi = [
  {
    type: "function",
    name: "createPool",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "p",
        type: "tuple",
        components: [
          { name: "tokenA", type: "address" },
          { name: "tokenB", type: "address" },
          { name: "sqrtPriceX96", type: "uint160" },
          { name: "sqrtPriceLowerX96", type: "uint160" },
          { name: "sqrtPriceUpperX96", type: "uint160" },
          { name: "baseFee", type: "uint24" },
          { name: "maxFee", type: "uint24" },
          { name: "launchFeeStart", type: "uint24" },
          { name: "launchFeeDuration", type: "uint32" },
        ],
      },
    ],
    outputs: [{ name: "pool", type: "address" }],
  },
  { type: "function", name: "allPools", stateMutability: "view", inputs: [], outputs: [{ type: "address[]" }] },
] as const;

export const dlmmLimitOrdersAbi = [
  {
    type: "function",
    name: "place",
    stateMutability: "nonpayable",
    inputs: [
      { name: "pool", type: "address" },
      { name: "binId", type: "int24" },
      { name: "side", type: "uint8" },
      { name: "amountIn", type: "uint256" },
      { name: "deadline", type: "uint256" },
    ],
    outputs: [{ name: "orderId", type: "uint256" }],
  },
  {
    type: "function",
    name: "cancel",
    stateMutability: "nonpayable",
    inputs: [
      { name: "orderId", type: "uint256" },
      { name: "recipient", type: "address" },
    ],
    outputs: [
      { name: "amount0", type: "uint256" },
      { name: "amount1", type: "uint256" },
    ],
  },
  {
    type: "function",
    name: "claim",
    stateMutability: "nonpayable",
    inputs: [
      { name: "orderId", type: "uint256" },
      { name: "recipient", type: "address" },
    ],
    outputs: [
      { name: "amount0", type: "uint256" },
      { name: "amount1", type: "uint256" },
    ],
  },
  { type: "function", name: "status", stateMutability: "view", inputs: [{ name: "orderId", type: "uint256" }], outputs: [{ type: "uint8" }] },
  {
    type: "function",
    name: "orderValue",
    stateMutability: "view",
    inputs: [{ name: "orderId", type: "uint256" }],
    outputs: [
      { name: "amount0", type: "uint256" },
      { name: "amount1", type: "uint256" },
    ],
  },
  { type: "function", name: "ordersOf", stateMutability: "view", inputs: [{ name: "owner", type: "address" }], outputs: [{ type: "uint256[]" }] },
  {
    type: "function",
    name: "getOrder",
    stateMutability: "view",
    inputs: [{ name: "orderId", type: "uint256" }],
    outputs: [
      {
        type: "tuple",
        components: [
          { name: "owner", type: "address" },
          { name: "pool", type: "address" },
          { name: "binId", type: "int24" },
          { name: "side", type: "uint8" },
          { name: "amountIn", type: "uint128" },
          { name: "shares", type: "uint256" },
          { name: "createdAt", type: "uint64" },
          { name: "closed", type: "bool" },
        ],
      },
    ],
  },
] as const;
