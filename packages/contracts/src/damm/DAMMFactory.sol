// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {VolatilityFee} from "../libraries/VolatilityFee.sol";
import {IDAMMFactory} from "../interfaces/IAethraPools.sol";
import {IAethraHub, Venue} from "../interfaces/IAethraHub.sol";
import {DAMMPool} from "./DAMMPool.sol";

/// @title DAMMFactory
/// @notice Permissionless factory for DAMM pools (BeaconProxy instances of one UpgradeableBeacon owned by the
///         protocol owner). Registers every pool in the AethraHub (venue DAMM, poolId = pool address).
contract DAMMFactory is IDAMMFactory, UUPSUpgradeable, Ownable2StepUpgradeable {
    /// @notice Full-range bounds (0 in CreateParams). Upper is MAX_SQRT_PRICE - 1 so ticks stay computable.
    uint160 public constant FULL_RANGE_LOWER = TickMath.MIN_SQRT_PRICE;
    uint160 public constant FULL_RANGE_UPPER = TickMath.MAX_SQRT_PRICE - 1;
    /// @notice Fee step per index unit: 60 ticks ~= 60 bps.
    uint16 public constant STEP_BPS = 60;

    error InvalidTokens();
    error InvalidRange();
    error InvalidFee();

    event VolatilityDefaultsSet(
        uint16 filterPeriod, uint16 decayPeriod, uint16 reductionBps, uint24 control, uint24 maxAccumulator
    );

    /// @notice Volatility parameters applied to every new pool (fees come from CreateParams).
    struct VolatilityDefaults {
        uint16 filterPeriod;
        uint16 decayPeriod;
        uint16 reductionBps;
        uint24 control;
        uint24 maxAccumulator;
    }

    /// @custom:storage-location erc7201:aethra.storage.DAMMFactory
    struct FactoryStorage {
        IAethraHub hub;
        address beacon;
        VolatilityDefaults vol;
        address[] pools;
        mapping(address => bool) isPool;
        mapping(bytes32 => address[]) pairPools;
    }

    // keccak256(abi.encode(uint256(keccak256("aethra.storage.DAMMFactory")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant FACTORY_STORAGE = 0xe4c224c09edb1e33d36e61681ff8b49724b5a1ba4e98774029023bc0f280aa00;

    function _s() private pure returns (FactoryStorage storage $) {
        assembly {
            $.slot := FACTORY_STORAGE
        }
    }

    constructor() {
        _disableInitializers();
    }

    /// @param beacon_ UpgradeableBeacon pointing at a DAMMPool implementation (owned by the protocol owner).
    function initialize(address owner_, IAethraHub hub_, address beacon_) external initializer {
        __Ownable_init(owner_);
        FactoryStorage storage $ = _s();
        ($.hub, $.beacon) = (hub_, beacon_);
        _setVolatilityDefaults(VolatilityDefaults(30, 600, 5000, 10_000, 350_000));
    }

    function createPool(CreateParams calldata p) external returns (address pool) {
        (address t0, address t1) = p.tokenA < p.tokenB ? (p.tokenA, p.tokenB) : (p.tokenB, p.tokenA);
        if (t0 == address(0) || t0 == t1) revert InvalidTokens();

        uint160 lower = p.sqrtPriceLowerX96 == 0 ? FULL_RANGE_LOWER : p.sqrtPriceLowerX96;
        uint160 upper = p.sqrtPriceUpperX96 == 0 ? FULL_RANGE_UPPER : p.sqrtPriceUpperX96;
        // Price may sit exactly on either edge (one-sided launch).
        if (
            lower < FULL_RANGE_LOWER || upper > FULL_RANGE_UPPER || lower >= upper || p.sqrtPriceX96 < lower
                || p.sqrtPriceX96 > upper
        ) revert InvalidRange();

        FactoryStorage storage $ = _s();
        VolatilityDefaults memory v = $.vol;
        VolatilityFee.Params memory params = VolatilityFee.Params({
            baseFee: p.baseFee,
            maxFee: p.maxFee,
            filterPeriod: v.filterPeriod,
            decayPeriod: v.decayPeriod,
            reductionBps: v.reductionBps,
            control: v.control,
            maxAccumulator: v.maxAccumulator,
            stepBps: STEP_BPS
        });
        VolatilityFee.validate(params);
        if (p.launchFeeStart > VolatilityFee.MAX_FEE_PIPS || (p.launchFeeStart > p.baseFee && p.launchFeeDuration == 0))
        {
            revert InvalidFee();
        }

        pool = address(
            new BeaconProxy(
                $.beacon,
                abi.encodeCall(
                    DAMMPool.initialize,
                    (t0, t1, p.sqrtPriceX96, lower, upper, params, p.launchFeeStart, p.launchFeeDuration)
                )
            )
        );
        $.pools.push(pool);
        $.isPool[pool] = true;
        $.pairPools[_pairKey(t0, t1)].push(pool);
        $.hub.registerPool(bytes32(uint256(uint160(pool))), Venue.DAMM, pool, t0, t1, msg.sender);
        emit PoolCreated(pool, t0, t1, p.sqrtPriceX96, lower, upper, msg.sender);
    }

    // ------------------------------------------------------------------ admin

    function setVolatilityDefaults(VolatilityDefaults calldata v) external onlyOwner {
        _setVolatilityDefaults(v);
    }

    function _setVolatilityDefaults(VolatilityDefaults memory v) internal {
        if (v.reductionBps > 10_000 || v.filterPeriod > v.decayPeriod) revert VolatilityFee.InvalidParams();
        _s().vol = v;
        emit VolatilityDefaultsSet(v.filterPeriod, v.decayPeriod, v.reductionBps, v.control, v.maxAccumulator);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ------------------------------------------------------------------ views

    function hub() external view returns (IAethraHub) {
        return _s().hub;
    }

    function beacon() external view returns (address) {
        return _s().beacon;
    }

    function volatilityDefaults() external view returns (VolatilityDefaults memory) {
        return _s().vol;
    }

    function allPools() external view returns (address[] memory) {
        return _s().pools;
    }

    function poolCount() external view returns (uint256) {
        return _s().pools.length;
    }

    function isPool(address pool) external view returns (bool) {
        return _s().isPool[pool];
    }

    function poolsForPair(address tokenA, address tokenB) external view returns (address[] memory) {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return _s().pairPools[_pairKey(t0, t1)];
    }

    function _pairKey(address t0, address t1) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(t0, t1));
    }
}
