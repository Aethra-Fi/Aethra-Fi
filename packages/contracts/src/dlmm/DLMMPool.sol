// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {FixedPointMathLib as FPM} from "solady/utils/FixedPointMathLib.sol";
import {IDLMMPool} from "../interfaces/IAethraPools.sol";
import {IAethraHub} from "../interfaces/IAethraHub.sol";
import {VolatilityFee} from "../libraries/VolatilityFee.sol";
import {BinMath} from "./BinMath.sol";

/// @title DLMMPool
/// @notice Discrete-bin liquidity market. Each bin is a constant-sum market at a fixed price
///         (token1 per token0) of (1 + binStep/10_000)^id. Bins above the active bin hold only token0,
///         bins below hold only token1 and the active bin may hold both.
/// @dev Deployed as a BeaconProxy by DLMMFactory; storage is ERC-7201 namespaced.
///      Swap fees are charged on the input amount per bin and come from the VolatilityFee accumulator
///      (index = bin id). The LP part stays in the bin (auto-compounding), the protocol part accrues in
///      the pool until anyone calls `collectProtocolFees`, which forwards it to the hub's buyback.
///      Liquidity shares are internal (no ERC-1155); use `transferShares` to move them.
///      Reserves are book-kept internally: fee-on-transfer and rebasing tokens are NOT supported.
contract DLMMPool is IDLMMPool, Initializable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using BinMath for BinMath.Tree;

    /// @notice Shares permanently locked by the first deposit in a bin (anti share-inflation).
    uint256 public constant MIN_SHARES = 1000;
    /// @notice Maximum number of non-empty bins a single swap may consume.
    uint256 public constant MAX_BINS_PER_SWAP = 128;
    uint256 internal constant PIPS = 1e6;
    uint256 internal constant ONE = 1 << 128;

    struct Bin {
        uint128 reserve0;
        uint128 reserve1;
        uint256 totalShares;
    }

    /// @custom:storage-location erc7201:aethra.storage.DLMMPool
    struct PoolStorage {
        address factory;
        address token0;
        uint16 binStep;
        int24 activeId;
        address token1;
        address hub;
        uint128 protocolFees0;
        uint128 protocolFees1;
        VolatilityFee.Params params;
        VolatilityFee.State vol;
        mapping(int24 => Bin) bins;
        mapping(int24 => mapping(address => uint256)) shares;
        BinMath.Tree tree;
    }

    // keccak256(abi.encode(uint256(keccak256("aethra.storage.DLMMPool")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant POOL_STORAGE = 0x8e3d9d3d6c86470dce5fecf165a1346074fa474f8c4952930e2af0426be60000;

    event SharesTransferred(address indexed from, address indexed to, int24 indexed id, uint256 amount);
    event ProtocolFeesCollected(address indexed buyback, uint256 amount0, uint256 amount1);
    event FeeParamsSet(VolatilityFee.Params params);

    error InsufficientLiquidity();
    error InsufficientShares();
    error InvalidBin(int24 id);
    error LengthMismatch();
    error NotFactory();

    /// @dev Result of a simulated swap; per-bin deltas are applied afterwards when executing.
    struct SwapSim {
        bool ok;
        int24 activeId;
        uint256 amountOut;
        uint256 fee;
        uint256 protocolFee;
        uint256 n;
        int24[] ids;
        uint256[] toBin; // input added to the bin (input minus protocol fee)
        uint256[] fromBin; // output taken from the bin
        VolatilityFee.State vol;
    }

    function _s() private pure returns (PoolStorage storage $) {
        assembly ("memory-safe") {
            $.slot := POOL_STORAGE
        }
    }

    constructor() {
        _disableInitializers();
    }

    /// @notice Called once by the factory through the BeaconProxy constructor.
    function initialize(
        address hub_,
        address token0_,
        address token1_,
        uint16 binStep_,
        int24 activeId_,
        VolatilityFee.Params memory params_
    ) external initializer {
        BinMath.getPriceX128(activeId_, binStep_); // validates the id range
        PoolStorage storage $ = _s();
        $.factory = msg.sender;
        $.hub = hub_;
        $.token0 = token0_;
        $.token1 = token1_;
        $.binStep = binStep_;
        $.activeId = activeId_;
        _setParams($, params_);
        $.vol.indexRef = activeId_;
        $.vol.lastUpdate = uint40(block.timestamp);
    }

    // ------------------------------------------------------------------ views

    function token0() external view returns (address) {
        return _s().token0;
    }

    function token1() external view returns (address) {
        return _s().token1;
    }

    function factory() external view returns (address) {
        return _s().factory;
    }

    function hub() external view returns (address) {
        return _s().hub;
    }

    function binStepBps() external view returns (uint16) {
        return _s().binStep;
    }

    function activeId() external view returns (int24) {
        return _s().activeId;
    }

    function feeParams() external view returns (VolatilityFee.Params memory) {
        return _s().params;
    }

    function volatilityState() external view returns (VolatilityFee.State memory) {
        return _s().vol;
    }

    /// @notice Protocol fees accrued and not yet sent to buyback.
    function protocolFees() external view returns (uint128 amount0, uint128 amount1) {
        PoolStorage storage $ = _s();
        return ($.protocolFees0, $.protocolFees1);
    }

    function getBin(int24 id) external view returns (uint128 reserve0, uint128 reserve1, uint256 totalShares) {
        Bin storage b = _s().bins[id];
        return (b.reserve0, b.reserve1, b.totalShares);
    }

    function priceX128(int24 id) external view returns (uint256) {
        return BinMath.getPriceX128(id, _s().binStep);
    }

    function sharesOf(int24 id, address account) external view returns (uint256) {
        return _s().shares[id][account];
    }

    function currentFee() public view returns (uint24) {
        PoolStorage storage $ = _s();
        return VolatilityFee.currentFee($.vol, $.params, $.activeId, block.timestamp);
    }

    function getBins(int24 fromId, int24 toId, uint256 maxCount)
        external
        view
        returns (int24[] memory ids, uint128[] memory reserves0, uint128[] memory reserves1)
    {
        PoolStorage storage $ = _s();
        if (toId < fromId) {
            maxCount = 0;
        } else {
            uint256 span = uint256(int256(toId) - int256(fromId)) + 1;
            if (maxCount > span) maxCount = span;
        }
        ids = new int24[](maxCount);
        reserves0 = new uint128[](maxCount);
        reserves1 = new uint128[](maxCount);
        uint256 n;
        if (maxCount != 0) {
            int24 id = fromId;
            bool found = $.tree.contains(id);
            if (!found) (found, id) = $.tree.nextAbove(id);
            while (found && id <= toId && n < maxCount) {
                Bin storage b = $.bins[id];
                (ids[n], reserves0[n], reserves1[n]) = (id, b.reserve0, b.reserve1);
                ++n;
                if (id == toId) break;
                (found, id) = $.tree.nextAbove(id);
            }
        }
        assembly ("memory-safe") {
            mstore(ids, n)
            mstore(reserves0, n)
            mstore(reserves1, n)
        }
    }

    // ------------------------------------------------------------------ swaps

    function quoteExactInput(address tokenIn, uint256 amountIn) external view returns (uint256 amountOut, uint24 feePips) {
        PoolStorage storage $ = _s();
        bool zeroForOne = tokenIn == $.token0;
        if (!zeroForOne && tokenIn != $.token1) revert InvalidToken();
        feePips = currentFee();
        if (amountIn == 0) return (0, feePips);
        SwapSim memory sim = _simulate($, zeroForOne, amountIn);
        if (sim.ok) amountOut = sim.amountOut;
    }

    function swapExactInput(address tokenIn, uint256 amountIn, uint256 minAmountOut, address recipient, uint256 deadline)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        if (block.timestamp > deadline) revert Expired();
        if (amountIn == 0) revert ZeroAmount();
        PoolStorage storage $ = _s();
        bool zeroForOne = tokenIn == $.token0;
        if (!zeroForOne && tokenIn != $.token1) revert InvalidToken();

        SwapSim memory sim = _simulate($, zeroForOne, amountIn);
        if (!sim.ok) revert InsufficientLiquidity();
        amountOut = sim.amountOut;
        if (amountOut < minAmountOut) revert Slippage();

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        for (uint256 i; i < sim.n; ++i) {
            Bin storage b = $.bins[sim.ids[i]];
            if (zeroForOne) {
                b.reserve0 = (uint256(b.reserve0) + sim.toBin[i]).toUint128();
                b.reserve1 -= uint128(sim.fromBin[i]);
            } else {
                b.reserve1 = (uint256(b.reserve1) + sim.toBin[i]).toUint128();
                b.reserve0 -= uint128(sim.fromBin[i]);
            }
        }
        $.activeId = sim.activeId;
        $.vol = sim.vol;
        address tokenOut;
        if (zeroForOne) {
            $.protocolFees0 = (uint256($.protocolFees0) + sim.protocolFee).toUint128();
            tokenOut = $.token1;
        } else {
            $.protocolFees1 = (uint256($.protocolFees1) + sim.protocolFee).toUint128();
            tokenOut = $.token0;
        }

        IERC20(tokenOut).safeTransfer(recipient, amountOut);
        emit Swap(msg.sender, recipient, tokenIn, tokenOut, amountIn, amountOut, sim.fee, sim.protocolFee, sim.activeId);
    }

    /// @dev Walks bins from the active one in the swap direction, skipping empty bins via the bitmap.
    ///      zeroForOne (token0 in) consumes token1 from the active bin and then lower bins.
    function _simulate(PoolStorage storage $, bool zeroForOne, uint256 amountIn) private view returns (SwapSim memory sim) {
        VolatilityFee.Params memory p = $.params;
        sim.vol = $.vol;
        sim.ids = new int24[](MAX_BINS_PER_SWAP);
        sim.toBin = new uint256[](MAX_BINS_PER_SWAP);
        sim.fromBin = new uint256[](MAX_BINS_PER_SWAP);
        uint256 shareBps = IAethraHub($.hub).protocolFeeShareBps();
        uint16 step = $.binStep;
        int24 id = $.activeId;
        VolatilityFee.beforeSwap(sim.vol, p, id, block.timestamp);
        uint256 remaining = amountIn;

        while (true) {
            Bin storage b = $.bins[id];
            uint256 rOut = zeroForOne ? b.reserve1 : b.reserve0;
            if (rOut != 0) {
                if (sim.n == MAX_BINS_PER_SWAP) return sim; // ok == false
                VolatilityFee.afterSwap(sim.vol, p, id, block.timestamp);
                uint256 f = VolatilityFee.fee(p, sim.vol.accumulator);
                (uint256 inGross, uint256 out, uint256 fee) =
                    _fillBin(rOut, BinMath.getPriceX128(id, step), zeroForOne, f, remaining);
                uint256 pFee = fee * shareBps / 10_000;
                unchecked {
                    remaining -= inGross; // inGross <= remaining
                }
                sim.amountOut += out;
                sim.fee += fee;
                sim.protocolFee += pFee;
                (sim.ids[sim.n], sim.toBin[sim.n], sim.fromBin[sim.n]) = (id, inGross - pFee, out);
                ++sim.n;
                if (remaining == 0) break;
            }
            bool found;
            (found, id) = zeroForOne ? $.tree.nextBelow(id) : $.tree.nextAbove(id);
            if (!found) return sim; // ok == false
        }
        sim.activeId = id;
        sim.ok = true;
    }

    /// @dev Fill one bin at constant sum. Rounds in favour of the pool: output down, input and fee up.
    function _fillBin(uint256 rOut, uint256 price, bool zeroForOne, uint256 f, uint256 remaining)
        private
        pure
        returns (uint256 inGross, uint256 out, uint256 fee)
    {
        uint256 netMax = zeroForOne ? FPM.fullMulDivUp(rOut, ONE, price) : FPM.fullMulDivUp(rOut, price, ONE);
        uint256 grossMax = netMax + FPM.fullMulDivUp(netMax, f, PIPS - f);
        if (remaining >= grossMax) return (grossMax, rOut, grossMax - netMax);
        fee = FPM.fullMulDivUp(remaining, f, PIPS);
        uint256 net = remaining - fee;
        out = zeroForOne ? FPM.fullMulDiv(net, price, ONE) : FPM.fullMulDiv(net, ONE, price);
        if (out > rOut) out = rOut;
        inGross = remaining;
    }

    // ------------------------------------------------------------------ liquidity

    function addLiquidity(
        int24[] calldata ids,
        uint256[] calldata amounts0,
        uint256[] calldata amounts1,
        address recipient,
        uint256 deadline
    ) external nonReentrant returns (uint256[] memory shares) {
        if (block.timestamp > deadline) revert Expired();
        uint256 len = ids.length;
        if (len == 0 || amounts0.length != len || amounts1.length != len) revert LengthMismatch();
        PoolStorage storage $ = _s();
        int24 active = $.activeId;
        uint16 step = $.binStep;
        uint256 f = currentFee();
        shares = new uint256[](len);
        uint256 total0;
        uint256 total1;
        for (uint256 i; i < len; ++i) {
            int24 id = ids[i];
            uint256 x = amounts0[i];
            uint256 y = amounts1[i];
            if ((id > active && y != 0) || (id < active && x != 0)) revert InvalidBin(id);
            shares[i] = _deposit($, id, x, y, BinMath.getPriceX128(id, step), id == active ? f : 0, recipient);
            total0 += x;
            total1 += y;
        }
        if (total0 != 0) IERC20($.token0).safeTransferFrom(msg.sender, address(this), total0);
        if (total1 != 0) IERC20($.token1).safeTransferFrom(msg.sender, address(this), total1);
        emit LiquidityAdded(msg.sender, recipient, ids, amounts0, amounts1, shares);
    }

    /// @dev Value-based shares at the bin price: L = price * x + y (token1 units).
    ///      For the active bin a composition fee is charged on the part of the deposit that the
    ///      pro-rata withdrawal would implicitly swap, so add + remove cannot be used as a fee-free swap.
    function _deposit(PoolStorage storage $, int24 id, uint256 x, uint256 y, uint256 price, uint256 f, address to)
        private
        returns (uint256 s)
    {
        if (x == 0 && y == 0) revert ZeroAmount();
        Bin storage b = $.bins[id];
        uint256 total = b.totalShares;
        uint256 l = FPM.fullMulDiv(price, x, ONE) + y;
        if (total == 0) {
            if (l <= MIN_SHARES) revert ZeroAmount();
            s = l - MIN_SHARES;
            total = MIN_SHARES;
            $.tree.add(id);
        } else {
            uint256 r0 = b.reserve0;
            uint256 r1 = b.reserve1;
            uint256 lBin = FPM.fullMulDiv(price, r0, ONE) + r1;
            s = FPM.fullMulDiv(l, total, lBin);
            if (f != 0 && s != 0) {
                uint256 feeValue;
                uint256 x2 = FPM.fullMulDiv(s, r0 + x, total + s);
                uint256 y2 = FPM.fullMulDiv(s, r1 + y, total + s);
                if (x > x2) feeValue = FPM.fullMulDivUp(FPM.fullMulDivUp(x - x2, f, PIPS), price, ONE);
                else if (y > y2) feeValue = FPM.fullMulDivUp(y - y2, f, PIPS);
                s = feeValue >= l ? 0 : FPM.fullMulDiv(l - feeValue, total, lBin);
            }
            if (s == 0) revert ZeroAmount();
            if (r0 == 0 && r1 == 0) $.tree.add(id);
        }
        b.reserve0 = (uint256(b.reserve0) + x).toUint128();
        b.reserve1 = (uint256(b.reserve1) + y).toUint128();
        b.totalShares = total + s;
        $.shares[id][to] += s;
    }

    function removeLiquidity(
        int24[] calldata ids,
        uint256[] calldata shares,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient,
        uint256 deadline
    ) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        if (block.timestamp > deadline) revert Expired();
        uint256 len = ids.length;
        if (len == 0 || shares.length != len) revert LengthMismatch();
        PoolStorage storage $ = _s();
        for (uint256 i; i < len; ++i) {
            int24 id = ids[i];
            uint256 s = shares[i];
            if (s == 0) revert ZeroAmount();
            mapping(address => uint256) storage bal = $.shares[id];
            uint256 owned = bal[msg.sender];
            if (s > owned) revert InsufficientShares();
            Bin storage b = $.bins[id];
            uint256 total = b.totalShares;
            uint256 a0 = FPM.fullMulDiv(b.reserve0, s, total);
            uint256 a1 = FPM.fullMulDiv(b.reserve1, s, total);
            unchecked {
                bal[msg.sender] = owned - s;
                b.totalShares = total - s;
                b.reserve0 -= uint128(a0);
                b.reserve1 -= uint128(a1);
            }
            if (b.reserve0 == 0 && b.reserve1 == 0) $.tree.remove(id);
            amount0 += a0;
            amount1 += a1;
        }
        if (amount0 < amount0Min || amount1 < amount1Min) revert Slippage();
        if (amount0 != 0) IERC20($.token0).safeTransfer(recipient, amount0);
        if (amount1 != 0) IERC20($.token1).safeTransfer(recipient, amount1);
        emit LiquidityRemoved(msg.sender, recipient, ids, shares, amount0, amount1);
    }

    /// @notice Move `amount` shares of bin `id` from msg.sender to `to`.
    function transferShares(int24 id, address to, uint256 amount) external {
        mapping(address => uint256) storage bal = _s().shares[id];
        uint256 owned = bal[msg.sender];
        if (amount > owned) revert InsufficientShares();
        unchecked {
            bal[msg.sender] = owned - amount;
        }
        bal[to] += amount;
        emit SharesTransferred(msg.sender, to, id, amount);
    }

    // ------------------------------------------------------------------ protocol fees & admin

    /// @notice Send accrued protocol fees to the hub's buyback. Callable by anyone; no-op while buyback is unset.
    function collectProtocolFees() external nonReentrant returns (uint256 amount0, uint256 amount1) {
        PoolStorage storage $ = _s();
        address buyback = IAethraHub($.hub).buyback();
        if (buyback == address(0)) return (0, 0);
        (amount0, amount1) = ($.protocolFees0, $.protocolFees1);
        ($.protocolFees0, $.protocolFees1) = (0, 0);
        if (amount0 != 0) IERC20($.token0).safeTransfer(buyback, amount0);
        if (amount1 != 0) IERC20($.token1).safeTransfer(buyback, amount1);
        emit ProtocolFeesCollected(buyback, amount0, amount1);
    }

    /// @notice Replace the dynamic fee parameters (factory owner only, through the factory).
    function setFeeParams(VolatilityFee.Params memory params_) external {
        PoolStorage storage $ = _s();
        if (msg.sender != $.factory) revert NotFactory();
        _setParams($, params_);
    }

    function _setParams(PoolStorage storage $, VolatilityFee.Params memory p) private {
        p.stepBps = $.binStep;
        VolatilityFee.validate(p);
        $.params = p;
        emit FeeParamsSet(p);
    }
}
