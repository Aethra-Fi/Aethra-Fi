// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {IAethraHub, Venue, AssetClass} from "../interfaces/IAethraHub.sol";
import {VolatilityFee} from "../libraries/VolatilityFee.sol";

/// @title AethraHook
/// @notice One Uniswap v4 hook for every Aethra v4 pool. The mode is chosen at pool initialization:
///         - DYNAMIC: volatility-accumulator fee (calm markets pay the base fee, bursts pay more).
///         - ORACLE: for pools with a tokenized stock. Adds an oracle guard on top of the dynamic fee:
///           swaps that move the pool toward the oracle price pay only the base fee, swaps that move it
///           away pay a deviation surcharge, a closed market multiplies the fee, and a swap may never
///           leave the pool further than `maxDeviationBps` from the oracle (circuit breaker).
///         A share of every fee (hub.protocolFeeShareBps) is taken by the hook as ERC-6909 claims and
///         later swept to the buyback contract.
/// @dev Deployed as an ERC-1967 proxy at a CREATE2 address whose low bits encode HOOK_FLAGS.
///      The flag set is fixed forever, so it includes every callback we may want later.
contract AethraHook is IHooks, IUnlockCallback, UUPSUpgradeable, Ownable2StepUpgradeable {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

    uint160 public constant HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG
        | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    enum Mode {
        NONE,
        DYNAMIC,
        ORACLE
    }

    struct OracleParams {
        uint16 maxDeviationBps; // circuit breaker: max |pool - oracle| / oracle after a swap
        uint16 surchargePipsPerBps; // extra fee per bps of deviation for deviation-increasing swaps
        uint16 closedMarketMultiplierBps; // fee multiplier while the equity market is closed (10_000 = 1x)
    }

    struct PoolConfig {
        Mode mode;
        uint8 decimals0;
        uint8 decimals1;
        VolatilityFee.Params fee;
        VolatilityFee.State vol;
        OracleParams oracle;
    }

    struct PoolView {
        Mode mode;
        uint24 feeZeroForOne;
        uint24 feeOneForZero;
        uint24 accumulator;
        uint256 poolPriceE18;
        uint256 oraclePriceE18; // 0 if unavailable
        uint256 deviationBps;
        bool oracleFresh;
        bool marketOpen;
        bool breakerTripped;
    }

    /// @custom:storage-location erc7201:aethra.storage.Hook
    struct HookStorage {
        IAethraHub hub;
        address positions; // only LP manager allowed to modify liquidity (0 = anyone)
        VolatilityFee.Params defaultDynamic;
        VolatilityFee.Params defaultOracle;
        OracleParams defaultOracleParams;
        mapping(PoolId => PoolConfig) pools;
        mapping(Currency => uint256) protocolFees; // claims held by the hook, per currency
    }

    // scripts/erc7201.sh aethra.storage.Hook
    bytes32 private constant HOOK_STORAGE = 0x59390587fd845bdf9e4bb01516b2c0b64931d42e0c674af536c1c01546852c00;
    // transient slots: fee charged in beforeSwap (pips) and pre-swap deviation, consumed in afterSwap
    uint256 private constant T_FEE = 0xae7a0001; // transient slot
    uint256 private constant T_DEV = 0xae7a0002; // transient slot

    IPoolManager public immutable poolManager;

    event PoolConfigured(PoolId indexed poolId, Mode mode, VolatilityFee.Params fee, OracleParams oracle);
    event SwapFee(PoolId indexed poolId, uint24 feePips, uint24 accumulator, uint256 deviationBps);
    event ProtocolFeesCollected(Currency indexed currency, address indexed to, uint256 amount);
    event PositionsSet(address positions);

    error NotPoolManager();
    error NotDynamicFee();
    error UnknownPool();
    error PoolDisabled();
    error OnlyPositions();
    error CircuitBreaker(uint256 deviationBps);
    error OracleUnavailable();
    error HookNotImplemented();
    error LaunchpadOnly();
    error AssetNotEnabled(address token);

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
        _disableInitializers();
    }

    function initialize(address owner_, IAethraHub hub_, address positions_) external initializer {
        __Ownable_init(owner_);
        HookStorage storage $ = _s();
        $.hub = hub_;
        $.positions = positions_;
        // base 0.05%, max 2%: tick spacing 10 (~0.1% per index)
        $.defaultDynamic = VolatilityFee.Params({
            baseFee: 500,
            maxFee: 20_000,
            filterPeriod: 30,
            decayPeriod: 600,
            reductionBps: 5000,
            control: 120_000,
            maxAccumulator: 2_000_000,
            stepBps: 10
        });
        // stock pools: base 0.30%, max 3%
        $.defaultOracle = VolatilityFee.Params({
            baseFee: 3000,
            maxFee: 30_000,
            filterPeriod: 30,
            decayPeriod: 600,
            reductionBps: 5000,
            control: 120_000,
            maxAccumulator: 2_000_000,
            stepBps: 10
        });
        $.defaultOracleParams =
            OracleParams({maxDeviationBps: 500, surchargePipsPerBps: 20, closedMarketMultiplierBps: 20_000});
    }

    function _s() private pure returns (HookStorage storage $) {
        assembly {
            $.slot := HOOK_STORAGE
        }
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    // ------------------------------------------------------------------ admin

    function setPositions(address positions_) external onlyOwner {
        _s().positions = positions_;
        emit PositionsSet(positions_);
    }

    function setDefaults(VolatilityFee.Params calldata dynamic_, VolatilityFee.Params calldata oracle_, OracleParams calldata op)
        external
        onlyOwner
    {
        VolatilityFee.validate(dynamic_);
        VolatilityFee.validate(oracle_);
        HookStorage storage $ = _s();
        ($.defaultDynamic, $.defaultOracle, $.defaultOracleParams) = (dynamic_, oracle_, op);
    }

    function setPoolParams(PoolKey calldata key, VolatilityFee.Params calldata p, OracleParams calldata op)
        external
        onlyOwner
    {
        VolatilityFee.validate(p);
        PoolConfig storage c = _s().pools[key.toId()];
        if (c.mode == Mode.NONE) revert UnknownPool();
        c.fee = p;
        c.oracle = op;
        emit PoolConfigured(key.toId(), c.mode, p, op);
    }

    // ------------------------------------------------------------------ views

    function hub() external view returns (IAethraHub) {
        return _s().hub;
    }

    function positions() external view returns (address) {
        return _s().positions;
    }

    function poolConfig(PoolId id) external view returns (PoolConfig memory) {
        return _s().pools[id];
    }

    function protocolFees(Currency currency) external view returns (uint256) {
        return _s().protocolFees[currency];
    }

    /// @notice Live fee and oracle-guard state for UIs and the indexer.
    function poolView(PoolKey calldata key) external view returns (PoolView memory v) {
        PoolId id = key.toId();
        PoolConfig memory c = _s().pools[id];
        if (c.mode == Mode.NONE) return v;
        (uint160 sqrtP, int24 tick,,) = poolManager.getSlot0(id);
        int24 index = _index(tick, key.tickSpacing);
        v.mode = c.mode;
        v.accumulator = _accumulatorNow(c.vol, c.fee, index);
        uint24 volFee = VolatilityFee.fee(c.fee, v.accumulator);
        v.poolPriceE18 = _poolPriceE18(sqrtP, c.decimals0, c.decimals1);
        v.feeZeroForOne = volFee;
        v.feeOneForZero = volFee;
        if (c.mode == Mode.ORACLE) {
            Guard memory g = _guard(key, c, sqrtP);
            v.oraclePriceE18 = g.oraclePriceE18;
            v.deviationBps = g.deviationBps;
            v.oracleFresh = g.fresh;
            v.marketOpen = g.marketOpen;
            v.breakerTripped = g.fresh && g.deviationBps > c.oracle.maxDeviationBps;
            v.feeZeroForOne = _oracleFee(c, g, volFee, true);
            v.feeOneForZero = _oracleFee(c, g, volFee, false);
        }
    }

    // ------------------------------------------------------------------ hook callbacks

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external view onlyPoolManager returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert NotDynamicFee();
        // A launchpad token's pool is created by its launchpad at graduation. Blocking everyone else stops a
        // front-runner from initializing it at a skewed price and arbitraging the graduation liquidity.
        _requireLaunchpad(Currency.unwrap(key.currency0), sender);
        _requireLaunchpad(Currency.unwrap(key.currency1), sender);
        return IHooks.beforeInitialize.selector;
    }

    function _requireLaunchpad(address token, address sender) internal view {
        IAethraHub.PoolInfo memory info = _s().hub.pool(bytes32(uint256(uint160(token))));
        if (info.venue == Venue.LAUNCH && info.pool != address(0) && info.pool != sender) revert LaunchpadOnly();
    }

    function afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        external
        onlyPoolManager
        returns (bytes4)
    {
        HookStorage storage $ = _s();
        PoolId id = key.toId();
        address t0 = Currency.unwrap(key.currency0);
        address t1 = Currency.unwrap(key.currency1);
        bool isStock = $.hub.asset(t0).class == AssetClass.STOCK || $.hub.asset(t1).class == AssetClass.STOCK;

        PoolConfig storage c = $.pools[id];
        c.mode = isStock ? Mode.ORACLE : Mode.DYNAMIC;
        c.decimals0 = _decimals(t0);
        c.decimals1 = _decimals(t1);
        c.fee = isStock ? $.defaultOracle : $.defaultDynamic;
        c.oracle = $.defaultOracleParams;
        c.vol.indexRef = _index(tick, key.tickSpacing);
        c.vol.lastUpdate = uint40(block.timestamp);

        if (isStock) {
            // The mode is fixed at initialization, so a stock pool may only start once its assets are live and the
            // opening price is inside the oracle band. Otherwise anyone could open (or front-run) a pool at a skewed price.
            _requireAssetEnabled($.hub, t0);
            _requireAssetEnabled($.hub, t1);
            Guard memory g = _guard(key, c, sqrtPriceX96);
            if (!g.fresh) revert OracleUnavailable();
            if (g.deviationBps > c.oracle.maxDeviationBps) revert CircuitBreaker(g.deviationBps);
        }

        $.hub.registerPool(PoolId.unwrap(id), Venue.V4, address(this), t0, t1, sender);
        emit PoolConfigured(id, c.mode, c.fee, c.oracle);
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address sender, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        address p = _s().positions;
        if (p != address(0) && sender != p) revert OnlyPositions();
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        // Removing is always allowed (locks are enforced by AethraPositions). Reserved for future logic.
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        HookStorage storage $ = _s();
        PoolId id = key.toId();
        if (!$.hub.isPoolEnabled(PoolId.unwrap(id))) revert PoolDisabled();
        PoolConfig storage c = $.pools[id];

        (uint160 sqrtP, int24 tick,,) = poolManager.getSlot0(id);
        int24 index = _index(tick, key.tickSpacing);
        VolatilityFee.State memory vol = c.vol;
        VolatilityFee.Params memory p = c.fee;
        VolatilityFee.beforeSwap(vol, p, index, block.timestamp);
        c.vol = vol;
        uint24 accumulator = _burstAccumulator(vol, p, index);
        uint24 fee = VolatilityFee.fee(p, accumulator);

        uint256 dev;
        if (c.mode == Mode.ORACLE) {
            Guard memory g = _guard(key, c, sqrtP);
            if (!g.fresh) revert OracleUnavailable();
            dev = g.deviationBps;
            bool towardOracle = _towardOracle(g, params.zeroForOne);
            if (!towardOracle && dev > c.oracle.maxDeviationBps) revert CircuitBreaker(dev);
            fee = _oracleFee(c, g, fee, params.zeroForOne);
            _tstore(T_DEV, dev + 1); // +1 so 0 means "not an oracle pool"
        }

        _tstore(T_FEE, fee);
        emit SwapFee(id, fee, accumulator, dev);

        // LP fee = fee * (1 - protocol share); the protocol share is taken in afterSwap.
        uint256 share = $.hub.protocolFeeShareBps();
        uint24 lpFee = uint24(uint256(fee) * (10_000 - share) / 10_000);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, lpFee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        HookStorage storage $ = _s();
        PoolId id = key.toId();
        PoolConfig storage c = $.pools[id];

        (uint160 sqrtP, int24 tick,,) = poolManager.getSlot0(id);
        VolatilityFee.State memory vol = c.vol;
        VolatilityFee.afterSwap(vol, c.fee, _index(tick, key.tickSpacing), block.timestamp);
        c.vol = vol;

        uint256 preDev = _tload(T_DEV);
        if (preDev != 0) {
            _tstore(T_DEV, 0);
            Guard memory g = _guard(key, c, sqrtP);
            // a swap may end beyond the breaker band only if it reduced the deviation
            if (g.deviationBps > c.oracle.maxDeviationBps && g.deviationBps > preDev - 1) {
                revert CircuitBreaker(g.deviationBps);
            }
        }

        // protocol fee on the unspecified currency (output for exact-in, input for exact-out)
        uint256 fee = _tload(T_FEE);
        _tstore(T_FEE, 0);
        uint256 share = $.hub.protocolFeeShareBps();
        if (share == 0 || fee == 0) return (IHooks.afterSwap.selector, 0);

        bool specifiedIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        int128 unspecified = specifiedIs0 ? delta.amount1() : delta.amount0();
        if (unspecified < 0) unspecified = -unspecified;
        uint256 hookFee = uint256(uint128(unspecified)) * fee * share / 10_000 / 1e6;
        if (hookFee == 0) return (IHooks.afterSwap.selector, 0);

        Currency currency = specifiedIs0 ? key.currency1 : key.currency0;
        poolManager.mint(address(this), currency.toId(), hookFee);
        $.protocolFees[currency] += hookFee;
        return (IHooks.afterSwap.selector, int128(int256(hookFee)));
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    // ------------------------------------------------------------------ protocol fee sweep

    /// @notice Sweep accrued protocol fees in `currency` to the hub's buyback contract. Callable by anyone.
    function collectProtocolFees(Currency currency) external returns (uint256 amount) {
        HookStorage storage $ = _s();
        address to = $.hub.buyback();
        amount = $.protocolFees[currency];
        if (to == address(0) || amount == 0) return 0;
        $.protocolFees[currency] = 0;
        poolManager.unlock(abi.encode(currency, to, amount));
        emit ProtocolFeesCollected(currency, to, amount);
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (Currency currency, address to, uint256 amount) = abi.decode(data, (Currency, address, uint256));
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, to, amount);
        return "";
    }

    // ------------------------------------------------------------------ internals

    struct Guard {
        uint256 poolPriceE18; // token1 per token0, human units
        uint256 oraclePriceE18;
        uint256 deviationBps;
        bool poolAbove; // pool price above oracle price
        bool fresh;
        bool marketOpen;
    }

    function _requireAssetEnabled(IAethraHub h, address token) internal view {
        IAethraHub.Asset memory a = h.asset(token);
        if (a.class == AssetClass.STOCK && !a.enabled) revert AssetNotEnabled(token);
    }

    function _guard(PoolKey calldata key, PoolConfig memory c, uint160 sqrtP) internal view returns (Guard memory g) {
        IAethraHub h = _s().hub;
        (uint256 p0, bool f0, bool o0) = h.tryGetPrice(Currency.unwrap(key.currency0));
        (uint256 p1, bool f1, bool o1) = h.tryGetPrice(Currency.unwrap(key.currency1));
        g.fresh = f0 && f1;
        g.marketOpen = o0 && o1;
        g.poolPriceE18 = _poolPriceE18(sqrtP, c.decimals0, c.decimals1);
        if (!g.fresh) return g;
        g.oraclePriceE18 = FullMath.mulDiv(p0, 1e18, p1);
        uint256 diff;
        (diff, g.poolAbove) = g.poolPriceE18 >= g.oraclePriceE18
            ? (g.poolPriceE18 - g.oraclePriceE18, true)
            : (g.oraclePriceE18 - g.poolPriceE18, false);
        g.deviationBps = FullMath.mulDiv(diff, 10_000, g.oraclePriceE18);
    }

    /// @dev zeroForOne lowers the pool price, so it moves toward the oracle when the pool is above it.
    function _towardOracle(Guard memory g, bool zeroForOne) internal pure returns (bool) {
        return g.deviationBps == 0 || g.poolAbove == zeroForOne;
    }

    function _oracleFee(PoolConfig memory c, Guard memory g, uint24 volFee, bool zeroForOne)
        internal
        pure
        returns (uint24)
    {
        uint256 f;
        if (!g.fresh) {
            f = c.fee.maxFee;
        } else if (_towardOracle(g, zeroForOne)) {
            f = c.fee.baseFee;
        } else {
            f = uint256(volFee) + g.deviationBps * c.oracle.surchargePipsPerBps;
        }
        if (!g.marketOpen) f = f * c.oracle.closedMarketMultiplierBps / 10_000;
        return uint24(f > c.fee.maxFee ? c.fee.maxFee : f);
    }

    /// @dev Human-unit price (token1 per token0) in 1e18 from sqrtPriceX96 and decimals.
    function _poolPriceE18(uint160 sqrtP, uint8 d0, uint8 d1) internal pure returns (uint256) {
        uint256 priceX96 = FullMath.mulDiv(sqrtP, sqrtP, 1 << 96); // raw token1/token0 * 2^96
        uint256 raw = FullMath.mulDiv(priceX96, 1e18, 1 << 96);
        if (d0 >= d1) return raw * 10 ** (d0 - d1);
        return raw / 10 ** (d1 - d0);
    }

    function _index(int24 tick, int24 spacing) internal pure returns (int24 i) {
        i = tick / spacing;
        if (tick < 0 && tick % spacing != 0) i--;
    }

    function _burstAccumulator(VolatilityFee.State memory vol, VolatilityFee.Params memory p, int24 index)
        internal
        pure
        returns (uint24)
    {
        int256 d = int256(index) - int256(vol.indexRef);
        uint256 acc = uint256(vol.refAcc) + uint256(d < 0 ? -d : d) * 10_000;
        return uint24(acc > p.maxAccumulator ? p.maxAccumulator : acc);
    }

    function _accumulatorNow(VolatilityFee.State memory vol, VolatilityFee.Params memory p, int24 index)
        internal
        view
        returns (uint24)
    {
        VolatilityFee.State memory tmp = VolatilityFee.State(vol.accumulator, vol.refAcc, vol.indexRef, vol.lastUpdate);
        VolatilityFee.beforeSwap(tmp, p, index, block.timestamp);
        return _burstAccumulator(tmp, p, index);
    }

    function _decimals(address token) internal view returns (uint8) {
        if (token == address(0)) return 18;
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            return d;
        } catch {
            return 18;
        }
    }

    function _tstore(uint256 slot, uint256 v) private {
        assembly {
            tstore(slot, v)
        }
    }

    function _tload(uint256 slot) private view returns (uint256 v) {
        assembly {
            v := tload(slot)
        }
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
