// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardTransientUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {SwapMath} from "v4-core/libraries/SwapMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint128} from "v4-core/libraries/FixedPoint128.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {VolatilityFee} from "../libraries/VolatilityFee.sol";
import {IDAMMPool} from "../interfaces/IAethraPools.sol";
import {IAethraHub} from "../interfaces/IAethraHub.sol";

/// @title DAMMPool
/// @notice Single-range concentrated AMM (v3 math over one [lower, upper] sqrt-price range) with fungible,
///         non-transferable shares (1 share == 1 liquidity unit), a volatility fee and an optional
///         decaying launch fee. Deployed as a BeaconProxy by DAMMFactory.
/// @dev Fee-on-transfer and rebasing tokens are NOT supported: the pool assumes `transferFrom(amount)`
///      delivers exactly `amount`. Reserves are tracked explicitly; LP fees and protocol fees are held on
///      top of the reserves and never re-enter the curve.
contract DAMMPool is IDAMMPool, Initializable, ReentrancyGuardTransientUpgradeable {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @notice Liquidity permanently locked (not attributed to anyone) on the first deposit.
    uint128 public constant MIN_LIQUIDITY = 1000;
    /// @notice Ticks per fee index unit (index = tick / 60).
    int24 public constant INDEX_TICKS = 60;

    error InsufficientLiquidity();
    error InsufficientShares();

    event ProtocolFeesCollected(address indexed to, uint256 amount0, uint256 amount1);

    struct Account {
        uint128 shares;
        uint128 owed0;
        uint128 owed1;
        uint256 feeGrowth0LastX128;
        uint256 feeGrowth1LastX128;
    }

    /// @custom:storage-location erc7201:aethra.storage.DAMMPool
    struct PoolStorage {
        address factory;
        address token0;
        address token1;
        uint160 sqrtPriceX96;
        uint160 sqrtPriceLowerX96;
        uint160 sqrtPriceUpperX96;
        uint128 liquidity;
        uint128 reserve0;
        uint128 reserve1;
        uint128 protocolFees0;
        uint128 protocolFees1;
        uint24 launchFeeStart;
        uint32 launchFeeDuration;
        uint40 createdAt;
        uint256 feeGrowthGlobal0X128;
        uint256 feeGrowthGlobal1X128;
        VolatilityFee.Params params;
        VolatilityFee.State vol;
        mapping(address => Account) accounts;
    }

    // keccak256(abi.encode(uint256(keccak256("aethra.storage.DAMMPool")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant POOL_STORAGE = 0x35d9a67146703351153fb091eb5b879da75ba9e8720ea13b55e2ab40348c1d00;

    /// @notice Hub is shared by every pool behind the beacon (implementation immutable).
    IAethraHub public immutable hub;

    function _s() private pure returns (PoolStorage storage $) {
        assembly {
            $.slot := POOL_STORAGE
        }
    }

    constructor(IAethraHub hub_) {
        hub = hub_;
        _disableInitializers();
    }

    /// @notice Called once by the factory through the BeaconProxy constructor. Parameters are validated there.
    function initialize(
        address token0_,
        address token1_,
        uint160 sqrtPriceX96_,
        uint160 sqrtPriceLowerX96_,
        uint160 sqrtPriceUpperX96_,
        VolatilityFee.Params calldata params_,
        uint24 launchFeeStart_,
        uint32 launchFeeDuration_
    ) external initializer {
        __ReentrancyGuardTransient_init();
        PoolStorage storage $ = _s();
        $.factory = msg.sender;
        ($.token0, $.token1) = (token0_, token1_);
        ($.sqrtPriceX96, $.sqrtPriceLowerX96, $.sqrtPriceUpperX96) =
            (sqrtPriceX96_, sqrtPriceLowerX96_, sqrtPriceUpperX96_);
        $.params = params_;
        ($.launchFeeStart, $.launchFeeDuration, $.createdAt) =
            (launchFeeStart_, launchFeeDuration_, uint40(block.timestamp));
        $.vol.indexRef = _index(sqrtPriceX96_);
        $.vol.lastUpdate = uint40(block.timestamp);
    }

    // ------------------------------------------------------------------ swaps

    function swapExactInput(address tokenIn, uint256 amountIn, uint256 minAmountOut, address recipient, uint256 deadline)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        if (block.timestamp > deadline) revert Expired();
        if (amountIn == 0) revert ZeroAmount();
        PoolStorage storage $ = _s();
        bool zeroForOne;
        address tokenOut;
        if (tokenIn == $.token0) (zeroForOne, tokenOut) = (true, $.token1);
        else if (tokenIn == $.token1) tokenOut = $.token0;
        else revert InvalidToken();

        uint160 sqrtP = $.sqrtPriceX96;
        int24 indexBefore = _index(sqrtP);
        VolatilityFee.Params memory p = $.params;
        VolatilityFee.State memory vs = $.vol;
        uint24 feePips = _fee($, p, vs, indexBefore);

        (bool ok, uint160 sqrtNext, uint256 used, uint256 out, uint256 feeAmount) =
            _step($, sqrtP, zeroForOne, amountIn, feePips);
        if (!ok) revert InsufficientLiquidity();
        if (out < minAmountOut) revert Slippage();
        amountOut = out;

        uint256 protocolFee = feeAmount * hub.protocolFeeShareBps() / 10_000;
        uint256 lpGrowth = FullMath.mulDiv(feeAmount - protocolFee, FixedPoint128.Q128, $.liquidity);
        if (zeroForOne) {
            unchecked {
                $.feeGrowthGlobal0X128 += lpGrowth;
            }
            $.protocolFees0 = (uint256($.protocolFees0) + protocolFee).toUint128();
            $.reserve0 = (uint256($.reserve0) + used).toUint128();
            $.reserve1 -= uint128(out);
        } else {
            unchecked {
                $.feeGrowthGlobal1X128 += lpGrowth;
            }
            $.protocolFees1 = (uint256($.protocolFees1) + protocolFee).toUint128();
            $.reserve1 = (uint256($.reserve1) + used).toUint128();
            $.reserve0 -= uint128(out);
        }
        $.sqrtPriceX96 = sqrtNext;

        int24 indexAfter = _index(sqrtNext);
        VolatilityFee.beforeSwap(vs, p, indexBefore, block.timestamp);
        VolatilityFee.afterSwap(vs, p, indexAfter, block.timestamp);
        $.vol = vs;

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(recipient, out);
        emit Swap(msg.sender, recipient, tokenIn, tokenOut, amountIn, out, feeAmount, protocolFee, indexAfter);
    }

    function quoteExactInput(address tokenIn, uint256 amountIn) external view returns (uint256 amountOut, uint24 feePips) {
        PoolStorage storage $ = _s();
        bool zeroForOne = tokenIn == $.token0;
        if (!zeroForOne && tokenIn != $.token1) return (0, 0);
        uint160 sqrtP = $.sqrtPriceX96;
        feePips = _fee($, $.params, $.vol, _index(sqrtP));
        if (amountIn == 0) return (0, feePips);
        (bool ok,, , uint256 out,) = _step($, sqrtP, zeroForOne, amountIn, feePips);
        if (ok) amountOut = out;
    }

    function currentFee() external view returns (uint24) {
        PoolStorage storage $ = _s();
        return _fee($, $.params, $.vol, _index($.sqrtPriceX96));
    }

    // ------------------------------------------------------------------ liquidity

    function addLiquidity(uint256 amount0Max, uint256 amount1Max, uint256 minShares, address recipient, uint256 deadline)
        external
        nonReentrant
        returns (uint256 shares, uint256 amount0, uint256 amount1)
    {
        if (block.timestamp > deadline) revert Expired();
        PoolStorage storage $ = _s();
        uint160 sqrtP = $.sqrtPriceX96;
        uint160 lower = $.sqrtPriceLowerX96;
        uint160 upper = $.sqrtPriceUpperX96;
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(sqrtP, lower, upper, amount0Max, amount1Max);
        if (liq == 0) revert ZeroAmount();
        // At an edge the other token's amount is exactly 0 (one-sided).
        amount0 = SqrtPriceMath.getAmount0Delta(sqrtP, upper, liq, true);
        amount1 = SqrtPriceMath.getAmount1Delta(lower, sqrtP, liq, true);
        if (amount0 > amount0Max || amount1 > amount1Max) revert Slippage();

        uint128 total = $.liquidity;
        shares = liq;
        if (total == 0) {
            if (liq <= MIN_LIQUIDITY) revert InsufficientLiquidity();
            shares = liq - MIN_LIQUIDITY;
        }
        if (shares < minShares) revert Slippage();

        _accrue($, recipient);
        Account storage a = $.accounts[recipient];
        a.shares += uint128(shares);
        $.liquidity = (uint256(total) + liq).toUint128();
        $.reserve0 = (uint256($.reserve0) + amount0).toUint128();
        $.reserve1 = (uint256($.reserve1) + amount1).toUint128();

        if (amount0 != 0) IERC20($.token0).safeTransferFrom(msg.sender, address(this), amount0);
        if (amount1 != 0) IERC20($.token1).safeTransferFrom(msg.sender, address(this), amount1);
        emit LiquidityAdded(msg.sender, recipient, shares, amount0, amount1);
    }

    function removeLiquidity(uint256 shares, uint256 amount0Min, uint256 amount1Min, address recipient, uint256 deadline)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        if (block.timestamp > deadline) revert Expired();
        if (shares == 0) revert ZeroAmount();
        PoolStorage storage $ = _s();
        Account storage a = $.accounts[msg.sender];
        if (shares > a.shares) revert InsufficientShares();
        _accrue($, msg.sender);

        uint128 total = $.liquidity;
        amount0 = uint256($.reserve0) * shares / total;
        amount1 = uint256($.reserve1) * shares / total;
        if (amount0 < amount0Min || amount1 < amount1Min) revert Slippage();

        a.shares -= uint128(shares);
        $.liquidity = total - uint128(shares);
        $.reserve0 -= uint128(amount0);
        $.reserve1 -= uint128(amount1);

        if (amount0 != 0) IERC20($.token0).safeTransfer(recipient, amount0);
        if (amount1 != 0) IERC20($.token1).safeTransfer(recipient, amount1);
        emit LiquidityRemoved(msg.sender, recipient, shares, amount0, amount1);
    }

    function claimFees(address recipient) external nonReentrant returns (uint256 fee0, uint256 fee1) {
        PoolStorage storage $ = _s();
        _accrue($, msg.sender);
        Account storage a = $.accounts[msg.sender];
        (fee0, fee1) = (a.owed0, a.owed1);
        (a.owed0, a.owed1) = (0, 0);
        if (fee0 != 0) IERC20($.token0).safeTransfer(recipient, fee0);
        if (fee1 != 0) IERC20($.token1).safeTransfer(recipient, fee1);
        emit FeesClaimed(msg.sender, recipient, fee0, fee1);
    }

    /// @notice Send accrued protocol fees to hub.buyback() (treasury if unset). Callable by anyone.
    ///         No-op when neither destination is configured.
    function collectProtocolFees() external nonReentrant returns (uint256 amount0, uint256 amount1) {
        address to = hub.buyback();
        if (to == address(0)) to = hub.treasury();
        if (to == address(0)) return (0, 0);
        PoolStorage storage $ = _s();
        (amount0, amount1) = ($.protocolFees0, $.protocolFees1);
        ($.protocolFees0, $.protocolFees1) = (0, 0);
        if (amount0 != 0) IERC20($.token0).safeTransfer(to, amount0);
        if (amount1 != 0) IERC20($.token1).safeTransfer(to, amount1);
        emit ProtocolFeesCollected(to, amount0, amount1);
    }

    // ------------------------------------------------------------------ views

    function factory() external view returns (address) {
        return _s().factory;
    }

    function token0() external view returns (address) {
        return _s().token0;
    }

    function token1() external view returns (address) {
        return _s().token1;
    }

    function sqrtPriceX96() external view returns (uint160) {
        return _s().sqrtPriceX96;
    }

    function sqrtPriceLowerX96() external view returns (uint160) {
        return _s().sqrtPriceLowerX96;
    }

    function sqrtPriceUpperX96() external view returns (uint160) {
        return _s().sqrtPriceUpperX96;
    }

    function liquidity() external view returns (uint128) {
        return _s().liquidity;
    }

    function reserves() external view returns (uint256 reserve0, uint256 reserve1) {
        PoolStorage storage $ = _s();
        return ($.reserve0, $.reserve1);
    }

    function sharesOf(address account) external view returns (uint256) {
        return _s().accounts[account].shares;
    }

    function claimableFees(address account) external view returns (uint256 fee0, uint256 fee1) {
        PoolStorage storage $ = _s();
        Account storage a = $.accounts[account];
        (uint256 p0, uint256 p1) = _pending($, a);
        return (a.owed0 + p0, a.owed1 + p1);
    }

    function protocolFees() external view returns (uint256 amount0, uint256 amount1) {
        PoolStorage storage $ = _s();
        return ($.protocolFees0, $.protocolFees1);
    }

    function feeGrowthGlobalX128() external view returns (uint256 g0, uint256 g1) {
        PoolStorage storage $ = _s();
        return ($.feeGrowthGlobal0X128, $.feeGrowthGlobal1X128);
    }

    /// @notice Fee configuration: volatility params + launch schedule (start fee, duration, creation time).
    function feeConfig()
        external
        view
        returns (VolatilityFee.Params memory params, uint24 launchFeeStart, uint32 launchFeeDuration, uint40 createdAt)
    {
        PoolStorage storage $ = _s();
        return ($.params, $.launchFeeStart, $.launchFeeDuration, $.createdAt);
    }

    function volatilityState() external view returns (VolatilityFee.State memory) {
        return _s().vol;
    }

    /// @notice Current fee index (tick / 60).
    function currentIndex() external view returns (int24) {
        return _index(_s().sqrtPriceX96);
    }

    // ------------------------------------------------------------------ internal

    function _index(uint160 sqrtP) internal pure returns (int24) {
        return TickMath.getTickAtSqrtPrice(sqrtP) / INDEX_TICKS;
    }

    /// @dev max(volatility fee, linearly decaying launch fee).
    function _fee(PoolStorage storage $, VolatilityFee.Params memory p, VolatilityFee.State memory vs, int24 index)
        internal
        view
        returns (uint24 f)
    {
        f = VolatilityFee.currentFee(vs, p, index, block.timestamp);
        uint256 start = $.launchFeeStart;
        if (start > p.baseFee) {
            uint256 elapsed = block.timestamp - $.createdAt;
            uint256 duration = $.launchFeeDuration;
            if (elapsed < duration) {
                uint256 launchFee = start - (start - p.baseFee) * elapsed / duration;
                if (launchFee > f) f = uint24(launchFee);
            }
        }
    }

    /// @dev One exact-input step toward the range bound. ok == false when liquidity runs out.
    function _step(PoolStorage storage $, uint160 sqrtP, bool zeroForOne, uint256 amountIn, uint24 feePips)
        internal
        view
        returns (bool ok, uint160 sqrtNext, uint256 used, uint256 out, uint256 feeAmount)
    {
        uint128 liq = $.liquidity;
        if (liq == 0 || amountIn > uint256(type(int256).max)) return (false, 0, 0, 0, 0);
        uint160 target = zeroForOne ? $.sqrtPriceLowerX96 : $.sqrtPriceUpperX96;
        (sqrtNext, used, out, feeAmount) = SwapMath.computeSwapStep(sqrtP, target, liq, -int256(amountIn), feePips);
        ok = used + feeAmount == amountIn && out <= (zeroForOne ? $.reserve1 : $.reserve0);
    }

    function _pending(PoolStorage storage $, Account storage a) internal view returns (uint256 p0, uint256 p1) {
        uint256 shares = a.shares;
        if (shares == 0) return (0, 0);
        unchecked {
            p0 = FullMath.mulDiv($.feeGrowthGlobal0X128 - a.feeGrowth0LastX128, shares, FixedPoint128.Q128);
            p1 = FullMath.mulDiv($.feeGrowthGlobal1X128 - a.feeGrowth1LastX128, shares, FixedPoint128.Q128);
        }
    }

    function _accrue(PoolStorage storage $, address account) internal {
        Account storage a = $.accounts[account];
        (uint256 p0, uint256 p1) = _pending($, a);
        if (p0 != 0) a.owed0 = (uint256(a.owed0) + p0).toUint128();
        if (p1 != 0) a.owed1 = (uint256(a.owed1) + p1).toUint128();
        a.feeGrowth0LastX128 = $.feeGrowthGlobal0X128;
        a.feeGrowth1LastX128 = $.feeGrowthGlobal1X128;
    }
}
