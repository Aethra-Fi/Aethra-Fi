// ABI fragments for the Aethra Fi indexer.
// Derived from packages/contracts/src/interfaces/{IAethraHub,IAethraPools,IAethraPeriphery}.sol and the
// Uniswap v4 IPoolManager interface. Keep this file as the single place to update when events change.
// Enum-typed event params are encoded as uint8 on chain (Venue, AssetClass, Side).
import { parseAbi } from "npm:viem@2.57.7";

export const hubAbi = parseAbi([
  "event AssetSet(address indexed token, uint8 class, bool enabled, address oracle, uint32 maxStaleness)",
  "event PoolRegistered(bytes32 indexed poolId, uint8 indexed venue, address pool, address token0, address token1, address creator)",
  "event PoolEnabled(bytes32 indexed poolId, bool enabled)",
  "function tryGetPrice(address token) view returns (uint256 priceE18, bool fresh, bool marketOpen)",
]);

/** Uniswap v4 PoolManager (only the events the indexer needs). */
export const poolManagerAbi = parseAbi([
  "event Initialize(bytes32 indexed id, address indexed currency0, address indexed currency1, uint24 fee, int24 tickSpacing, address hooks, uint160 sqrtPriceX96, int24 tick)",
  "event ModifyLiquidity(bytes32 indexed id, address indexed sender, int24 tickLower, int24 tickUpper, int256 liquidityDelta, bytes32 salt)",
  "event Swap(bytes32 indexed id, address indexed sender, int128 amount0, int128 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick, uint24 fee)",
]);

/** Shared by DLMM and DAMM pools (IAethraPool). */
const aethraPoolSwap =
  "event Swap(address indexed sender, address indexed recipient, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, uint256 feeAmount, uint256 protocolFeeAmount, int24 indexAfter)";

export const dlmmPoolAbi = parseAbi([
  aethraPoolSwap,
  "event LiquidityAdded(address indexed sender, address indexed recipient, int24[] ids, uint256[] amounts0, uint256[] amounts1, uint256[] shares)",
  "event LiquidityRemoved(address indexed sender, address indexed recipient, int24[] ids, uint256[] shares, uint256 amount0, uint256 amount1)",
  "function activeId() view returns (int24)",
  "function currentFee() view returns (uint24)",
  "function binStepBps() view returns (uint16)",
]);

export const dammPoolAbi = parseAbi([
  aethraPoolSwap,
  "event LiquidityAdded(address indexed sender, address indexed recipient, uint256 shares, uint256 amount0, uint256 amount1)",
  "event LiquidityRemoved(address indexed sender, address indexed recipient, uint256 shares, uint256 amount0, uint256 amount1)",
  "event FeesClaimed(address indexed account, address indexed recipient, uint256 amount0, uint256 amount1)",
  "function sqrtPriceX96() view returns (uint160)",
  "function liquidity() view returns (uint128)",
  "function reserves() view returns (uint256 reserve0, uint256 reserve1)",
  "function currentFee() view returns (uint24)",
]);

export const dlmmFactoryAbi = parseAbi([
  "event PoolCreated(address indexed pool, address indexed token0, address indexed token1, uint16 binStepBps, int24 activeId, address creator)",
]);

export const dammFactoryAbi = parseAbi([
  "event PoolCreated(address indexed pool, address indexed token0, address indexed token1, uint160 sqrtPriceX96, uint160 sqrtPriceLowerX96, uint160 sqrtPriceUpperX96, address creator)",
]);

export const limitOrdersAbi = parseAbi([
  "event OrderPlaced(uint256 indexed orderId, address indexed owner, address indexed pool, int24 binId, uint8 side, uint256 amountIn)",
  "event OrderCancelled(uint256 indexed orderId, uint256 returned0, uint256 returned1)",
  "event OrderClaimed(uint256 indexed orderId, uint256 amount0, uint256 amount1)",
]);

export const launchpadAbi = parseAbi([
  "event LaunchCreated(address indexed token, address indexed creator, string name, string symbol, string metadataURI)",
  "event Trade(address indexed token, address indexed trader, bool isBuy, uint256 wethAmount, uint256 tokenAmount, uint256 fee, uint256 realWethAfter)",
  "event Graduated(address indexed token, bytes32 indexed v4PoolId, uint256 positionId, uint256 wethLiquidity, uint256 tokenLiquidity)",
  "function graduationThreshold() view returns (uint256 wethTarget)",
]);

export const routerAbi = parseAbi([
  "event RouteExecuted(address indexed sender, address indexed recipient, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, uint8 hops)",
]);

export const positionsAbi = parseAbi([
  "event Minted(uint256 indexed tokenId, address indexed owner, bytes32 indexed poolId, int24 tickLower, int24 tickUpper)",
  "event LiquidityChanged(uint256 indexed tokenId, int256 liquidityDelta, int256 amount0, int256 amount1)",
  "event FeesCollected(uint256 indexed tokenId, address recipient, uint256 amount0, uint256 amount1)",
  "event Locked(uint256 indexed tokenId, uint64 cliff, uint64 end, uint128 lockedLiquidity)",
  // ERC-721 ownership changes
  "event Transfer(address indexed from, address indexed to, uint256 indexed tokenId)",
]);

export const lendingVaultAbi = parseAbi([
  "event Borrowed(address indexed to, uint256 assets, uint256 debtShares)",
  "event Repaid(address indexed from, uint256 assets, uint256 debtShares)",
  "event InterestAccrued(uint256 interest, uint256 reserves, uint256 borrowIndexRay)",
  // ERC-4626 supply side
  "event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares)",
  "event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares)",
]);

export const creditManagerAbi = parseAbi([
  "event Pledged(uint256 indexed tokenId, address indexed owner)",
  "event Released(uint256 indexed tokenId, address indexed owner)",
  "event Borrow(uint256 indexed tokenId, address indexed owner, uint256 assets)",
  "event Repay(uint256 indexed tokenId, address indexed payer, uint256 assets)",
  "event Liquidated(uint256 indexed tokenId, address indexed liquidator, uint256 debtRepaid, uint256 collateralValueUsd)",
]);

export const buybackAbi = parseAbi([
  "event RevenueReceived(address indexed token, uint256 amount, address indexed from)",
  "event BuybackExecuted(address indexed tokenIn, uint256 amountIn, uint256 aethBought, uint256 aethBurned, uint256 toTreasury)",
]);

export const erc20Abi = parseAbi([
  "function symbol() view returns (string)",
  "function name() view returns (string)",
  "function decimals() view returns (uint8)",
]);

/** Contract roles the indexer knows, keyed by the field name in deployments.addresses. */
export type Role =
  | "hub"
  | "poolManager"
  | "router"
  | "positions"
  | "dlmmFactory"
  | "dlmmLimitOrders"
  | "dammFactory"
  | "launchpad"
  | "lendingVault"
  | "creditManager"
  | "buyback"
  | "dlmmPool"
  | "dammPool";

// deno-lint-ignore no-explicit-any
export const abiByRole: Record<Role, readonly any[]> = {
  hub: hubAbi,
  poolManager: poolManagerAbi,
  router: routerAbi,
  positions: positionsAbi,
  dlmmFactory: dlmmFactoryAbi,
  dlmmLimitOrders: limitOrdersAbi,
  dammFactory: dammFactoryAbi,
  launchpad: launchpadAbi,
  lendingVault: lendingVaultAbi,
  creditManager: creditManagerAbi,
  buyback: buybackAbi,
  dlmmPool: dlmmPoolAbi,
  dammPool: dammPoolAbi,
};

/** Static (singleton) roles read from deployments.addresses. Pools are discovered from events. */
export const STATIC_ROLES: Exclude<Role, "dlmmPool" | "dammPool" | "poolManager">[] = [
  "hub",
  "router",
  "positions",
  "dlmmFactory",
  "dlmmLimitOrders",
  "dammFactory",
  "launchpad",
  "lendingVault",
  "creditManager",
  "buyback",
];

export const VENUES = ["NONE", "V4", "DLMM", "DAMM", "LAUNCH"] as const;
export const ASSET_CLASSES = ["NONE", "CANONICAL", "STOCK", "LAUNCH", "RWA"] as const;
export const ORDER_SIDES = ["SELL_TOKEN0", "SELL_TOKEN1"] as const;
