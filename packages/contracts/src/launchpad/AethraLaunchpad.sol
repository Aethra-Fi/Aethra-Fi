// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardTransientUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {IAethraLaunchpad} from "../interfaces/IAethraPools.sol";
import {IAethraPositions} from "../interfaces/IAethraPeriphery.sol";
import {IAethraHub, Venue} from "../interfaces/IAethraHub.sol";
import {LaunchToken} from "./LaunchToken.sol";

interface IWETH9 {
    function deposit() external payable;
}

/// @title AethraLaunchpad
/// @notice Fair-launch bonding curves quoted in WETH that graduate into a Uniswap v4 pool (Aethra hook,
///         dynamic fee, tick spacing 60) with a permanently locked full-range Aethra position.
/// @dev Curve model: virtual constant product over effective reserves
///         W = virtualWeth + realWeth,  T = virtualToken + realToken,  W * T = k.
///      `Launch.virtualToken` stores only the virtual (never sellable) token part; `realToken` is what the curve
///      can still sell. The config value `virtualToken` is the *initial effective* token reserve (e.g. 1.073e27),
///      so a launch stores `virtualToken - curveSupply`. A launch graduates when the curve is sold out
///      (realToken == 0), i.e. when realWeth reaches the launch's threshold W_end - virtualWeth.
///      Buys larger than the remaining curve supply are clamped: only the WETH actually needed is pulled from
///      the caller (the rest of the allowance / balance stays with the caller; routers must account for it).
///      Fee-on-transfer tokens are irrelevant here (WETH + own launch tokens only).
contract AethraLaunchpad is
    IAethraLaunchpad,
    IERC721Receiver,
    UUPSUpgradeable,
    Ownable2StepUpgradeable,
    ReentrancyGuardTransientUpgradeable
{
    using SafeERC20 for IERC20;

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    int24 public constant TICK_SPACING = 60;
    uint24 internal constant PIPS = 1_000_000;
    uint24 public constant MAX_TRADE_FEE = 50_000; // 5%
    uint16 public constant MAX_GRADUATION_FEE_BPS = 1000; // 10%

    error ZeroAmount();
    error InvalidToken();
    error InvalidConfig();
    error NotReady();
    error NotGraduated();
    error BadValue();
    error RefundFailed();
    error PoolInitFailed();
    error PositionsLocked();

    event CurveConfigSet(uint128 virtualWeth, uint128 virtualToken, uint128 curveSupply);
    event FeeConfigSet(uint24 tradeFeePips, uint16 graduationFeeBps, uint16 creatorFeeBps);
    event GraduationTargetsSet(address poolManager, address positions, address hook);
    event GraduatedFeesCollected(
        address indexed token, uint256 wethToCreator, uint256 tokenToCreator, uint256 wethToProtocol, uint256 tokenToProtocol
    );

    struct Config {
        uint128 virtualWeth; // initial virtual WETH reserve
        uint128 virtualToken; // initial effective token reserve (virtual + curve supply)
        uint128 curveSupply; // tokens sold by the curve; TOTAL_SUPPLY - curveSupply is reserved for graduation
        uint24 tradeFeePips; // curve trade fee, paid in WETH
        uint16 graduationFeeBps; // share of raised WETH taken at graduation
        uint16 creatorFeeBps; // creator share of the locked position's LP fees
    }

    /// @custom:storage-location erc7201:aethra.storage.Launchpad
    struct LaunchpadStorage {
        IAethraHub hub;
        address weth;
        address tokenImplementation;
        address poolManager;
        address positions;
        address hook;
        uint32 graduatedCount;
        Config config;
        mapping(address => Launch) launches;
        address[] launchList;
    }

    // keccak256(abi.encode(uint256(keccak256("aethra.storage.Launchpad")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant LAUNCHPAD_STORAGE = 0x3b7d32d600c1341ca75ab8c84b1e7db0770c257e47879578dc52acacf6057300;

    function _s() private pure returns (LaunchpadStorage storage $) {
        assembly {
            $.slot := LAUNCHPAD_STORAGE
        }
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        IAethraHub hub_,
        address weth_,
        address tokenImplementation_,
        address poolManager_,
        address positions_,
        address hook_
    ) external initializer {
        __Ownable_init(owner_);
        __ReentrancyGuardTransient_init();
        LaunchpadStorage storage $ = _s();
        ($.hub, $.weth, $.tokenImplementation) = (hub_, weth_, tokenImplementation_);
        _setGraduationTargets(poolManager_, positions_, hook_);
        _setCurveConfig(1.5e18, 1_073_000_000e18, 800_000_000e18);
        _setFeeConfig(10_000, 0, 5000);
    }

    // ------------------------------------------------------------------ create

    /// @dev Initial buy: send ETH (msg.value, wrapped; unused ETH refunded) or pull `initialBuyWeth` WETH.
    ///      If both are given they must match. The initial buy has no slippage bound (creator is first).
    function create(string calldata name, string calldata symbol, string calldata metadataURI, uint256 initialBuyWeth)
        external
        payable
        nonReentrant
        returns (address token)
    {
        if (msg.value != 0 && initialBuyWeth != 0 && initialBuyWeth != msg.value) revert BadValue();
        LaunchpadStorage storage $ = _s();
        token = LibClone.clone($.tokenImplementation);
        LaunchToken(token).initialize(name, symbol, address(this));

        Config memory c = $.config;
        Launch storage l = $.launches[token];
        l.token = token;
        l.creator = msg.sender;
        l.virtualWeth = c.virtualWeth;
        l.virtualToken = c.virtualToken - c.curveSupply;
        l.realToken = c.curveSupply;
        l.createdAt = uint64(block.timestamp);
        $.launchList.push(token);

        address weth_ = $.weth;
        (address t0, address t1) = weth_ < token ? (weth_, token) : (token, weth_);
        $.hub.registerPool(bytes32(uint256(uint160(token))), Venue.LAUNCH, address(this), t0, t1, msg.sender);
        emit LaunchCreated(token, msg.sender, name, symbol, metadataURI);

        uint256 buyIn = msg.value != 0 ? msg.value : initialBuyWeth;
        if (buyIn != 0) {
            (uint256 gross, uint256 fee, uint256 out) = _applyBuy(l, c.tradeFeePips, buyIn);
            if (msg.value != 0) {
                IWETH9(weth_).deposit{value: gross}();
                if (msg.value > gross) {
                    (bool ok,) = msg.sender.call{value: msg.value - gross}("");
                    if (!ok) revert RefundFailed();
                }
            } else {
                IERC20(weth_).safeTransferFrom(msg.sender, address(this), gross);
            }
            _settleBuy($, l, gross, fee, out, msg.sender);
        }
    }

    // ------------------------------------------------------------------ trading

    /// @dev Buys (tokenIn == WETH) pull only the WETH actually used, which is less than `amountIn` when the buy
    ///      is clamped at the end of the curve. The clamping buy graduates the launch in the same transaction.
    function swapExactInput(
        address token,
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline
    ) external nonReentrant returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert Expired();
        if (amountIn == 0) revert ZeroAmount();
        LaunchpadStorage storage $ = _s();
        Launch storage l = _activeLaunch($, token);
        uint24 feePips = $.config.tradeFeePips;
        address weth_ = $.weth;

        if (tokenIn == weth_) {
            (uint256 gross, uint256 fee, uint256 out) = _applyBuy(l, feePips, amountIn);
            if (out < minAmountOut) revert Slippage();
            IERC20(weth_).safeTransferFrom(msg.sender, address(this), gross);
            _settleBuy($, l, gross, fee, out, recipient);
            amountOut = out;
        } else if (tokenIn == token) {
            (uint256 fee, uint256 out) = _applySell(l, feePips, amountIn);
            if (out < minAmountOut) revert Slippage();
            IERC20(token).safeTransferFrom(msg.sender, address(this), amountIn);
            IERC20(weth_).safeTransfer(recipient, out);
            _toSink($, weth_, fee);
            emit Trade(token, msg.sender, false, out, amountIn, fee, l.realWeth);
            amountOut = out;
        } else {
            revert InvalidToken();
        }
    }

    /// @dev Returns 0 for unknown or graduated launches and for invalid tokenIn. Buys are clamped.
    function quoteExactInput(address token, address tokenIn, uint256 amountIn) external view returns (uint256 amountOut) {
        LaunchpadStorage storage $ = _s();
        Launch memory l = $.launches[token];
        if (l.token == address(0) || l.graduated || amountIn == 0) return 0;
        uint24 feePips = $.config.tradeFeePips;
        if (tokenIn == $.weth) (,, amountOut) = _quoteBuy(l, feePips, amountIn);
        else if (tokenIn == token) (,, amountOut) = _quoteSell(l, feePips, amountIn);
    }

    /// @notice Like quoteExactInput for buys, but also returns the WETH that would actually be used.
    function quoteBuy(address token, uint256 wethIn)
        external
        view
        returns (uint256 wethUsed, uint256 fee, uint256 tokensOut)
    {
        LaunchpadStorage storage $ = _s();
        Launch memory l = $.launches[token];
        if (l.token == address(0) || l.graduated || wethIn == 0) return (0, 0, 0);
        return _quoteBuy(l, $.config.tradeFeePips, wethIn);
    }

    /// @notice Spot price of the curve: WETH per token, scaled by 1e18.
    function spotPrice(address token) external view returns (uint256 wethPerTokenE18) {
        Launch memory l = _s().launches[token];
        if (l.token == address(0)) return 0;
        return FullMath.mulDiv(uint256(l.virtualWeth) + l.realWeth, 1e18, uint256(l.virtualToken) + l.realToken);
    }

    // ------------------------------------------------------------------ graduation

    function graduate(address token) external nonReentrant {
        LaunchpadStorage storage $ = _s();
        Launch storage l = _activeLaunch($, token);
        if (l.realToken != 0) revert NotReady();
        _graduate($, l);
    }

    /// @notice Collect the locked position's LP fees and split them between the creator and hub.buyback().
    ///         Callable by anyone.
    function collectGraduatedFees(address token)
        external
        nonReentrant
        returns (uint256 wethToCreator, uint256 tokenToCreator, uint256 wethToProtocol, uint256 tokenToProtocol)
    {
        LaunchpadStorage storage $ = _s();
        Launch storage l = $.launches[token];
        if (l.token == address(0)) revert UnknownLaunch();
        if (!l.graduated) revert NotGraduated();
        (uint256 fee0, uint256 fee1) = IAethraPositions($.positions).collect(l.positionId, address(this));
        address weth_ = $.weth;
        (uint256 feeWeth, uint256 feeToken) = weth_ < token ? (fee0, fee1) : (fee1, fee0);
        uint256 bps = $.config.creatorFeeBps;
        wethToCreator = feeWeth * bps / 10_000;
        tokenToCreator = feeToken * bps / 10_000;
        wethToProtocol = feeWeth - wethToCreator;
        tokenToProtocol = feeToken - tokenToCreator;
        address creator = l.creator;
        if (wethToCreator != 0) IERC20(weth_).safeTransfer(creator, wethToCreator);
        if (tokenToCreator != 0) IERC20(token).safeTransfer(creator, tokenToCreator);
        _toSink($, weth_, wethToProtocol);
        _toSink($, token, tokenToProtocol);
        emit GraduatedFeesCollected(token, wethToCreator, tokenToCreator, wethToProtocol, tokenToProtocol);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    // ------------------------------------------------------------------ admin

    function setCurveConfig(uint128 virtualWeth, uint128 virtualToken, uint128 curveSupply) external onlyOwner {
        _setCurveConfig(virtualWeth, virtualToken, curveSupply);
    }

    function setFeeConfig(uint24 tradeFeePips, uint16 graduationFeeBps, uint16 creatorFeeBps) external onlyOwner {
        _setFeeConfig(tradeFeePips, graduationFeeBps, creatorFeeBps);
    }

    /// @notice The hook may change at any time (affects future graduations). PoolManager and Positions can only
    ///         change before the first graduation, since locked positions live in the Positions contract.
    function setGraduationTargets(address poolManager_, address positions_, address hook_) external onlyOwner {
        LaunchpadStorage storage $ = _s();
        if ($.graduatedCount != 0 && (poolManager_ != $.poolManager || positions_ != $.positions)) {
            revert PositionsLocked();
        }
        _setGraduationTargets(poolManager_, positions_, hook_);
    }

    function _setCurveConfig(uint128 virtualWeth, uint128 virtualToken, uint128 curveSupply) internal {
        if (virtualWeth == 0 || curveSupply == 0 || curveSupply >= TOTAL_SUPPLY || virtualToken <= curveSupply) {
            revert InvalidConfig();
        }
        Config storage c = _s().config;
        (c.virtualWeth, c.virtualToken, c.curveSupply) = (virtualWeth, virtualToken, curveSupply);
        emit CurveConfigSet(virtualWeth, virtualToken, curveSupply);
    }

    function _setFeeConfig(uint24 tradeFeePips, uint16 graduationFeeBps, uint16 creatorFeeBps) internal {
        if (tradeFeePips > MAX_TRADE_FEE || graduationFeeBps > MAX_GRADUATION_FEE_BPS || creatorFeeBps > 10_000) {
            revert InvalidConfig();
        }
        Config storage c = _s().config;
        (c.tradeFeePips, c.graduationFeeBps, c.creatorFeeBps) = (tradeFeePips, graduationFeeBps, creatorFeeBps);
        emit FeeConfigSet(tradeFeePips, graduationFeeBps, creatorFeeBps);
    }

    function _setGraduationTargets(address poolManager_, address positions_, address hook_) internal {
        LaunchpadStorage storage $ = _s();
        ($.poolManager, $.positions, $.hook) = (poolManager_, positions_, hook_);
        emit GraduationTargetsSet(poolManager_, positions_, hook_);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ------------------------------------------------------------------ views

    function launch(address token) external view returns (Launch memory) {
        return _s().launches[token];
    }

    function launches() external view returns (address[] memory) {
        return _s().launchList;
    }

    function launchCount() external view returns (uint256) {
        return _s().launchList.length;
    }

    /// @dev WETH a new launch (current config) raises before graduating: W_end - virtualWeth where
    ///      W_end = virtualWeth * virtualToken / (virtualToken - curveSupply).
    function graduationThreshold() external view returns (uint256 wethTarget) {
        Config memory c = _s().config;
        return FullMath.mulDivRoundingUp(c.virtualWeth, c.virtualToken, c.virtualToken - c.curveSupply) - c.virtualWeth;
    }

    function config() external view returns (Config memory) {
        return _s().config;
    }

    function hub() external view returns (IAethraHub) {
        return _s().hub;
    }

    function weth() external view returns (address) {
        return _s().weth;
    }

    function tokenImplementation() external view returns (address) {
        return _s().tokenImplementation;
    }

    function graduationTargets() external view returns (address poolManager, address positions, address hook) {
        LaunchpadStorage storage $ = _s();
        return ($.poolManager, $.positions, $.hook);
    }

    /// @notice PoolKey the launch graduates (or graduated) into, with the currently configured hook.
    function poolKeyFor(address token) public view returns (PoolKey memory key) {
        LaunchpadStorage storage $ = _s();
        address weth_ = $.weth;
        (address t0, address t1) = weth_ < token ? (weth_, token) : (token, weth_);
        key = PoolKey(Currency.wrap(t0), Currency.wrap(t1), LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, IHooks($.hook));
    }

    // ------------------------------------------------------------------ internal: curve

    function _activeLaunch(LaunchpadStorage storage $, address token) internal view returns (Launch storage l) {
        l = $.launches[token];
        if (l.token == address(0)) revert UnknownLaunch();
        if (l.graduated) revert AlreadyGraduated();
    }

    /// @return gross WETH used (<= wethIn), fee WETH fee, out tokens bought (clamped at realToken)
    function _quoteBuy(Launch memory l, uint24 feePips, uint256 wethIn)
        internal
        pure
        returns (uint256 gross, uint256 fee, uint256 out)
    {
        uint256 w = uint256(l.virtualWeth) + l.realWeth;
        uint256 t = uint256(l.virtualToken) + l.realToken;
        gross = wethIn;
        fee = FullMath.mulDivRoundingUp(wethIn, feePips, PIPS);
        out = FullMath.mulDiv(t, wethIn - fee, w + wethIn - fee);
        if (out > l.realToken) {
            out = l.realToken;
            // net WETH needed so that (w + net) * (t - out) >= w * t; t - out == virtualToken > 0
            uint256 netNeeded = FullMath.mulDivRoundingUp(w, out, t - out);
            gross = FullMath.mulDivRoundingUp(netNeeded, PIPS, PIPS - feePips);
            if (gross > wethIn) gross = wethIn;
            fee = FullMath.mulDivRoundingUp(gross, feePips, PIPS);
        }
    }

    /// @return fee WETH fee, out WETH paid to the seller (after fee); gross = out + fee leaves the curve
    function _quoteSell(Launch memory l, uint24 feePips, uint256 tokenIn)
        internal
        pure
        returns (uint256 fee, uint256 gross, uint256 out)
    {
        uint256 w = uint256(l.virtualWeth) + l.realWeth;
        uint256 t = uint256(l.virtualToken) + l.realToken;
        gross = FullMath.mulDiv(w, tokenIn, t + tokenIn);
        if (gross > l.realWeth) gross = l.realWeth;
        fee = FullMath.mulDivRoundingUp(gross, feePips, PIPS);
        out = gross - fee;
    }

    function _applyBuy(Launch storage l, uint24 feePips, uint256 wethIn)
        internal
        returns (uint256 gross, uint256 fee, uint256 out)
    {
        (gross, fee, out) = _quoteBuy(l, feePips, wethIn);
        if (out == 0) revert ZeroAmount();
        l.realWeth += uint128(gross - fee);
        l.realToken -= uint128(out);
    }

    function _applySell(Launch storage l, uint24 feePips, uint256 tokenIn) internal returns (uint256 fee, uint256 out) {
        uint256 gross;
        (fee, gross, out) = _quoteSell(l, feePips, tokenIn);
        if (out == 0) revert ZeroAmount();
        l.realWeth -= uint128(gross);
        l.realToken += uint128(tokenIn);
    }

    /// @dev WETH for the buy (gross) is already in the contract.
    function _settleBuy(LaunchpadStorage storage $, Launch storage l, uint256 gross, uint256 fee, uint256 out, address to)
        internal
    {
        address token = l.token;
        IERC20(token).safeTransfer(to, out);
        _toSink($, $.weth, fee);
        emit Trade(token, msg.sender, true, gross, out, fee, l.realWeth);
        if (l.realToken == 0) _graduate($, l);
    }

    /// @dev Protocol revenue: hub.buyback(), else hub.treasury(), else kept here.
    function _toSink(LaunchpadStorage storage $, address token, uint256 amount) internal {
        if (amount == 0) return;
        IAethraHub h = $.hub;
        address to = h.buyback();
        if (to == address(0)) to = h.treasury();
        if (to != address(0)) IERC20(token).safeTransfer(to, amount);
    }

    // ------------------------------------------------------------------ internal: graduation

    function _graduate(LaunchpadStorage storage $, Launch storage l) internal {
        l.graduated = true;
        unchecked {
            ++$.graduatedCount;
        }
        address token = l.token;
        address weth_ = $.weth;
        bool wethIs0 = weth_ < token;

        uint256 raised = l.realWeth;
        uint256 gradFee = raised * $.config.graduationFeeBps / 10_000;
        uint256 wethAmt = raised - gradFee;
        // The curve is sold out, so the remaining balance is the graduation reserve.
        uint256 tokenAmt = IERC20(token).balanceOf(address(this));

        // Final curve price, token1 per token0 in raw units.
        uint256 w = uint256(l.virtualWeth) + l.realWeth;
        uint256 t = uint256(l.virtualToken) + l.realToken;
        uint160 sqrtP = wethIs0 ? _sqrtPriceX96(t, w) : _sqrtPriceX96(w, t);

        PoolKey memory key = poolKeyFor(token);
        bytes32 poolId = keccak256(abi.encode(key));
        IPoolManager pm = IPoolManager($.poolManager);
        // If someone initialized the pool first, add liquidity at the existing price instead of reverting forever.
        try pm.initialize(key, sqrtP) {}
        catch {
            sqrtP = uint160(uint256(pm.extsload(keccak256(abi.encodePacked(poolId, bytes32(uint256(6)))))));
            if (sqrtP == 0) revert PoolInitFailed();
        }

        (uint256 a0, uint256 a1) = wethIs0 ? (wethAmt, tokenAmt) : (tokenAmt, wethAmt);
        int24 tl = TickMath.minUsableTick(TICK_SPACING);
        int24 tu = TickMath.maxUsableTick(TICK_SPACING);
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP, TickMath.getSqrtPriceAtTick(tl), TickMath.getSqrtPriceAtTick(tu), a0, a1
        );
        // Shave a hair off so rounding inside Positions never exceeds the max amounts.
        liq -= uint128(liq / 1e9) + (liq > 0 ? 1 : 0);

        address positions_ = $.positions;
        (address t0, address t1) = wethIs0 ? (weth_, token) : (token, weth_);
        IERC20(t0).forceApprove(positions_, a0);
        IERC20(t1).forceApprove(positions_, a1);
        (uint256 tokenId, uint256 used0, uint256 used1) = IAethraPositions(positions_).mint(
            IAethraPositions.MintParams(key, tl, tu, liq, a0, a1, address(this), block.timestamp)
        );
        IERC20(t0).forceApprove(positions_, 0);
        IERC20(t1).forceApprove(positions_, 0);
        IAethraPositions(positions_).lock(tokenId, type(uint64).max, type(uint64).max);
        l.positionId = tokenId;

        (uint256 wethUsed, uint256 tokenUsed) = wethIs0 ? (used0, used1) : (used1, used0);
        _toSink($, weth_, raised - wethUsed);
        _toSink($, token, tokenAmt - tokenUsed);
        emit Graduated(token, poolId, tokenId, wethUsed, tokenUsed);
    }

    /// @dev sqrt(num / den) in Q64.96, clamped to the valid v4 price range.
    function _sqrtPriceX96(uint256 num, uint256 den) internal pure returns (uint160) {
        uint256 r;
        uint256 q = num / den;
        if (q < (1 << 64)) r = FixedPointMathLib.sqrt(FullMath.mulDiv(num, 1 << 192, den));
        else if (q < (1 << 128)) r = FixedPointMathLib.sqrt(FullMath.mulDiv(num, 1 << 128, den)) << 32;
        else r = TickMath.MAX_SQRT_PRICE - 1;
        if (r < TickMath.MIN_SQRT_PRICE) r = TickMath.MIN_SQRT_PRICE;
        if (r >= TickMath.MAX_SQRT_PRICE) r = TickMath.MAX_SQRT_PRICE - 1;
        return uint160(r);
    }
}
