// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Common exact-input surface implemented by every Aethra-native pool (DLMM, DAMM).
/// @dev Pools pull `tokenIn` from msg.sender with transferFrom (the router approves each hop).
///      Fees are in pips (1e-6). `index` is the bin id (DLMM) or tick / tickSpacing (DAMM).
interface IAethraPool {
    /// @notice Emitted by every Aethra-native pool so the indexer can treat venues uniformly.
    event Swap(
        address indexed sender,
        address indexed recipient,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 feeAmount,
        uint256 protocolFeeAmount,
        int24 indexAfter
    );

    error Expired();
    error Slippage();
    error InvalidToken();
    error ZeroAmount();

    function token0() external view returns (address);
    function token1() external view returns (address);
    /// @return amountOut expected output, feePips fee that would be charged right now
    function quoteExactInput(address tokenIn, uint256 amountIn) external view returns (uint256 amountOut, uint24 feePips);
    function swapExactInput(address tokenIn, uint256 amountIn, uint256 minAmountOut, address recipient, uint256 deadline)
        external
        returns (uint256 amountOut);
    /// @notice Current total fee in pips (base + volatility part).
    function currentFee() external view returns (uint24);
}

/// @notice Discrete-bin liquidity market. Price of bin `id` (token1 per token0, raw units, Q128.128):
///         price(id) = (1 + binStepBps / 10_000) ^ id. Bin 0 is price 1.
///         Bins above the active bin hold only token0, bins below only token1, the active bin holds both.
interface IDLMMPool is IAethraPool {
    event LiquidityAdded(address indexed sender, address indexed recipient, int24[] ids, uint256[] amounts0, uint256[] amounts1, uint256[] shares);
    event LiquidityRemoved(address indexed sender, address indexed recipient, int24[] ids, uint256[] shares, uint256 amount0, uint256 amount1);

    function binStepBps() external view returns (uint16);
    function activeId() external view returns (int24);
    function getBin(int24 id) external view returns (uint128 reserve0, uint128 reserve1, uint256 totalShares);
    function priceX128(int24 id) external view returns (uint256);
    function sharesOf(int24 id, address account) external view returns (uint256);
    /// @notice Non-empty bins in [fromId, toId] (inclusive), for liquidity charts. Bounded by `maxCount`.
    function getBins(int24 fromId, int24 toId, uint256 maxCount)
        external
        view
        returns (int24[] memory ids, uint128[] memory reserves0, uint128[] memory reserves1);

    function addLiquidity(
        int24[] calldata ids,
        uint256[] calldata amounts0,
        uint256[] calldata amounts1,
        address recipient,
        uint256 deadline
    ) external returns (uint256[] memory shares);

    function removeLiquidity(
        int24[] calldata ids,
        uint256[] calldata shares,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient,
        uint256 deadline
    ) external returns (uint256 amount0, uint256 amount1);
}

interface IDLMMFactory {
    struct CreateParams {
        address tokenA;
        address tokenB;
        uint16 binStepBps;
        int24 activeId;
        uint24 baseFee; // pips
        uint24 maxFee; // pips
    }

    event PoolCreated(address indexed pool, address indexed token0, address indexed token1, uint16 binStepBps, int24 activeId, address creator);

    function createPool(CreateParams calldata p) external returns (address pool);
    function getPool(address tokenA, address tokenB, uint16 binStepBps) external view returns (address);
    function allPools() external view returns (address[] memory);
    function isPool(address pool) external view returns (bool);
}

/// @notice Limit orders on DLMM pools: single-sided liquidity in one bin, filled as the active bin crosses it.
interface IDLMMLimitOrders {
    enum Side {
        SELL_TOKEN0, // deposit token0 in a bin above the active bin, receive token1 when filled
        SELL_TOKEN1 // deposit token1 in a bin below the active bin, receive token0 when filled
    }
    enum Status {
        NONE,
        OPEN,
        PARTIAL,
        FILLED,
        CLOSED
    }

    struct Order {
        address owner;
        address pool;
        int24 binId;
        Side side;
        uint128 amountIn;
        uint256 shares;
        uint64 createdAt;
        bool closed;
    }

    event OrderPlaced(uint256 indexed orderId, address indexed owner, address indexed pool, int24 binId, Side side, uint256 amountIn);
    event OrderCancelled(uint256 indexed orderId, uint256 returned0, uint256 returned1);
    event OrderClaimed(uint256 indexed orderId, uint256 amount0, uint256 amount1);

    function place(address pool, int24 binId, Side side, uint256 amountIn, uint256 deadline) external returns (uint256 orderId);
    /// @notice Withdraw whatever the order's shares are worth now (input and/or output token).
    function cancel(uint256 orderId, address recipient) external returns (uint256 amount0, uint256 amount1);
    /// @notice Withdraw a fully filled order (reverts if not FILLED).
    function claim(uint256 orderId, address recipient) external returns (uint256 amount0, uint256 amount1);
    function getOrder(uint256 orderId) external view returns (Order memory);
    function status(uint256 orderId) external view returns (Status);
    /// @return amount0 amount1 current value of the order's shares
    function orderValue(uint256 orderId) external view returns (uint256 amount0, uint256 amount1);
    function ordersOf(address owner) external view returns (uint256[] memory);
}

/// @notice Dynamic AMM: one concentrated range [sqrtPriceLower, sqrtPriceUpper] per pool with fungible shares
///         (shares == liquidity units). Full range when the bounds are TickMath MIN/MAX. One-sided launch
///         when initialized at a range edge. Dynamic volatility fee + optional time-based launch fee schedule.
interface IDAMMPool is IAethraPool {
    event LiquidityAdded(address indexed sender, address indexed recipient, uint256 shares, uint256 amount0, uint256 amount1);
    event LiquidityRemoved(address indexed sender, address indexed recipient, uint256 shares, uint256 amount0, uint256 amount1);
    event FeesClaimed(address indexed account, address indexed recipient, uint256 amount0, uint256 amount1);

    function sqrtPriceX96() external view returns (uint160);
    function sqrtPriceLowerX96() external view returns (uint160);
    function sqrtPriceUpperX96() external view returns (uint160);
    function liquidity() external view returns (uint128);
    function reserves() external view returns (uint256 reserve0, uint256 reserve1);
    function sharesOf(address account) external view returns (uint256);
    function claimableFees(address account) external view returns (uint256 fee0, uint256 fee1);

    function addLiquidity(uint256 amount0Max, uint256 amount1Max, uint256 minShares, address recipient, uint256 deadline)
        external
        returns (uint256 shares, uint256 amount0, uint256 amount1);
    function removeLiquidity(uint256 shares, uint256 amount0Min, uint256 amount1Min, address recipient, uint256 deadline)
        external
        returns (uint256 amount0, uint256 amount1);
    function claimFees(address recipient) external returns (uint256 fee0, uint256 fee1);
}

interface IDAMMFactory {
    struct CreateParams {
        address tokenA;
        address tokenB;
        uint160 sqrtPriceX96; // initial price, token1 per token0 after sorting
        uint160 sqrtPriceLowerX96; // 0 = full range
        uint160 sqrtPriceUpperX96; // 0 = full range
        uint24 baseFee; // pips
        uint24 maxFee; // pips
        uint24 launchFeeStart; // pips; 0 = no launch schedule
        uint32 launchFeeDuration; // seconds over which the launch fee decays linearly to baseFee
    }

    event PoolCreated(address indexed pool, address indexed token0, address indexed token1, uint160 sqrtPriceX96, uint160 sqrtPriceLowerX96, uint160 sqrtPriceUpperX96, address creator);

    function createPool(CreateParams calldata p) external returns (address pool);
    function allPools() external view returns (address[] memory);
    function isPool(address pool) external view returns (bool);
    function poolsForPair(address tokenA, address tokenB) external view returns (address[] memory);
}

/// @notice Fair-launch bonding curve (virtual constant product, quoted in WETH) that graduates into a
///         Uniswap v4 pool (Aethra hook, dynamic fee) with permanently locked liquidity.
interface IAethraLaunchpad {
    struct Launch {
        address token;
        address creator;
        uint128 virtualWeth;
        uint128 virtualToken;
        uint128 realWeth; // WETH raised on the curve
        uint128 realToken; // tokens still sellable on the curve
        uint64 createdAt;
        bool graduated;
        uint256 positionId; // Aethra position NFT holding the graduated liquidity (0 before)
    }

    event LaunchCreated(address indexed token, address indexed creator, string name, string symbol, string metadataURI);
    event Trade(address indexed token, address indexed trader, bool isBuy, uint256 wethAmount, uint256 tokenAmount, uint256 fee, uint256 realWethAfter);
    event Graduated(address indexed token, bytes32 indexed v4PoolId, uint256 positionId, uint256 wethLiquidity, uint256 tokenLiquidity);

    error UnknownLaunch();
    error AlreadyGraduated();
    error Expired();
    error Slippage();

    function create(string calldata name, string calldata symbol, string calldata metadataURI, uint256 initialBuyWeth)
        external
        payable
        returns (address token);
    /// @notice Exact-input trade on a curve. tokenIn is WETH (buy) or the launch token (sell). Pulls tokenIn from msg.sender.
    function swapExactInput(address token, address tokenIn, uint256 amountIn, uint256 minAmountOut, address recipient, uint256 deadline)
        external
        returns (uint256 amountOut);
    function quoteExactInput(address token, address tokenIn, uint256 amountIn) external view returns (uint256 amountOut);
    function launch(address token) external view returns (Launch memory);
    function launches() external view returns (address[] memory);
    function graduationThreshold() external view returns (uint256 wethTarget);
    /// @notice Anyone can graduate once realWeth >= threshold (also triggered automatically by the crossing buy).
    function graduate(address token) external;
}
