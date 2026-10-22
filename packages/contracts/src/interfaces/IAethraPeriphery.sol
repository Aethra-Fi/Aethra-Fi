// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Venue} from "./IAethraHub.sol";

/// @notice Multi-venue exact-input router. A route is a list of hops executed in order; each hop's
///         output is the next hop's input. Best-route search happens off-chain (SDK) using `quote`.
interface IAethraRouter {
    struct Hop {
        Venue venue;
        address pool; // DLMM/DAMM pool, launchpad (LAUNCH), ignored for V4
        address tokenIn;
        address tokenOut;
        bytes data; // V4: abi.encode(PoolKey); LAUNCH: abi.encode(launchToken); else empty
    }

    event RouteExecuted(
        address indexed sender,
        address indexed recipient,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint8 hops
    );

    error Expired();
    error Slippage();
    error BadRoute();
    error BadVenue();
    error NotPoolManager();
    error QuoteResult(uint256 amountOut, uint256[] hopAmounts);

    /// @notice Execute a route. Send ETH with tokenIn == WETH to wrap. Set unwrapETH to receive ETH when tokenOut == WETH.
    function swap(Hop[] calldata hops, uint256 amountIn, uint256 minAmountOut, address recipient, uint256 deadline, bool unwrapETH)
        external
        payable
        returns (uint256 amountOut);

    /// @notice Simulate a route (call with eth_call; not a view because v4 quoting needs unlock).
    function quote(Hop[] calldata hops, uint256 amountIn) external returns (uint256 amountOut, uint256[] memory hopAmounts);

    function weth() external view returns (address);
}

/// @notice ERC-721 positions for Uniswap v4 pools (Aethra hook pools and plain v4 pools), with built-in
///         locks and linear vesting. Fees accrue in the PoolManager and are paid out on collect/modify.
interface IAethraPositions {
    struct Position {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    struct Lock {
        uint64 cliff; // no withdrawals before this timestamp
        uint64 end; // fully unlocked at this timestamp; type(uint64).max = permanent
        uint128 lockedLiquidity; // liquidity covered by the schedule
        uint128 withdrawn; // locked liquidity already withdrawn
    }

    struct MintParams {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 amount0Max;
        uint256 amount1Max;
        address recipient;
        uint256 deadline;
    }

    event Minted(uint256 indexed tokenId, address indexed owner, bytes32 indexed poolId, int24 tickLower, int24 tickUpper);
    event LiquidityChanged(uint256 indexed tokenId, int256 liquidityDelta, int256 amount0, int256 amount1);
    event FeesCollected(uint256 indexed tokenId, address recipient, uint256 amount0, uint256 amount1);
    event Locked(uint256 indexed tokenId, uint64 cliff, uint64 end, uint128 lockedLiquidity);

    error Expired();
    error NotOwnerOrApproved();
    error LockedLiquidity();
    error InvalidLock();
    error Slippage();
    error NotPoolManager();

    function mint(MintParams calldata p) external returns (uint256 tokenId, uint256 amount0, uint256 amount1);
    function increaseLiquidity(uint256 tokenId, uint128 liquidity, uint256 amount0Max, uint256 amount1Max, uint256 deadline)
        external
        returns (uint256 amount0, uint256 amount1);
    function decreaseLiquidity(
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient,
        uint256 deadline
    ) external returns (uint256 amount0, uint256 amount1);
    function collect(uint256 tokenId, address recipient) external returns (uint256 fee0, uint256 fee1);
    function burn(uint256 tokenId) external;
    /// @notice Lock (or extend the lock of) a position. Locks can only become stricter.
    function lock(uint256 tokenId, uint64 cliff, uint64 end) external;

    function getPosition(uint256 tokenId) external view returns (Position memory);
    function getLock(uint256 tokenId) external view returns (Lock memory);
    /// @notice Liquidity the owner may currently withdraw.
    function withdrawable(uint256 tokenId) external view returns (uint128);
    /// @notice Token amounts the position's liquidity is worth at the current pool price (excludes unclaimed fees).
    function positionAmounts(uint256 tokenId) external view returns (uint256 amount0, uint256 amount1);
    function ownerOf(uint256 tokenId) external view returns (address);
    function nextTokenId() external view returns (uint256);
}

/// @notice USD-stable lending vault (ERC-4626) whose borrowers are only the CreditManager.
interface ILendingVault {
    event Borrowed(address indexed to, uint256 assets, uint256 debtShares);
    event Repaid(address indexed from, uint256 assets, uint256 debtShares);
    event InterestAccrued(uint256 interest, uint256 reserves, uint256 borrowIndexRay);

    function lend(uint256 assets, address to) external returns (uint256 debtShares); // only credit manager
    function repayDebt(uint256 assets, address from) external returns (uint256 debtSharesBurned); // only credit manager
    function debtSharesToAssets(uint256 debtShares) external view returns (uint256);
    function assetsToDebtShares(uint256 assets) external view returns (uint256);
    function totalBorrows() external view returns (uint256);
    function utilizationBps() external view returns (uint256);
    function borrowRatePerSecondWad() external view returns (uint256);
    function supplyRatePerSecondWad() external view returns (uint256);
    function accrueInterest() external;
}

/// @notice Borrow stablecoins against Aethra position NFTs.
interface ICreditManager {
    struct Loan {
        address owner;
        uint256 debtShares;
        uint64 openedAt;
    }

    event Pledged(uint256 indexed tokenId, address indexed owner);
    event Released(uint256 indexed tokenId, address indexed owner);
    event Borrow(uint256 indexed tokenId, address indexed owner, uint256 assets);
    event Repay(uint256 indexed tokenId, address indexed payer, uint256 assets);
    event Liquidated(uint256 indexed tokenId, address indexed liquidator, uint256 debtRepaid, uint256 collateralValueUsd);

    error NotLoanOwner();
    error Unhealthy();
    error Healthy();
    error OutstandingDebt();
    error UnsupportedCollateral();

    function pledge(uint256 tokenId) external;
    function release(uint256 tokenId) external;
    function borrow(uint256 tokenId, uint256 assets, address to) external;
    function repay(uint256 tokenId, uint256 assets) external returns (uint256 repaid);
    function liquidate(uint256 tokenId) external;

    function loan(uint256 tokenId) external view returns (Loan memory);
    function debtOf(uint256 tokenId) external view returns (uint256);
    /// @return valueUsdE18 collateral value, maxBorrow at maxLtv, healthFactorE18 (liqThreshold * value / debt)
    function health(uint256 tokenId) external view returns (uint256 valueUsdE18, uint256 maxBorrow, uint256 healthFactorE18);
    function loansOf(address owner) external view returns (uint256[] memory);
}

/// @notice Protocol revenue sink: swaps collected fees into AETH and burns it (treasury keeps a share).
interface IAethraBuyback {
    event RevenueReceived(address indexed token, uint256 amount, address indexed from);
    event BuybackExecuted(address indexed tokenIn, uint256 amountIn, uint256 aethBought, uint256 aethBurned, uint256 toTreasury);

    error Cooldown();
    error Slippage();
    error NotKeeper();

    function execute(address tokenIn, uint256 amountIn, IAethraRouter.Hop[] calldata route, uint256 minAethOut)
        external
        returns (uint256 burned);
    function totalBurned() external view returns (uint256);
    function totalBought(address tokenIn) external view returns (uint256 spent);
    function aeth() external view returns (address);
}
