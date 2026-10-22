// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {IDLMMFactory} from "../interfaces/IAethraPools.sol";
import {IAethraHub, Venue} from "../interfaces/IAethraHub.sol";
import {VolatilityFee} from "../libraries/VolatilityFee.sol";
import {DLMMPool} from "./DLMMPool.sol";

/// @title DLMMFactory
/// @notice Permissionless creation of DLMM pools as BeaconProxy instances of one DLMMPool implementation.
///         Pools are registered in the AethraHub (this factory must be a hub registrar).
/// @dev UUPS proxy with ERC-7201 storage. The beacon is deployed separately and owned by the protocol owner,
///      so upgrading the beacon upgrades every pool at once.
contract DLMMFactory is IDLMMFactory, UUPSUpgradeable, Ownable2StepUpgradeable {
    struct VolatilityDefaults {
        uint16 filterPeriod;
        uint16 decayPeriod;
        uint16 reductionBps;
        uint24 control;
        uint24 maxAccumulator;
    }

    /// @custom:storage-location erc7201:aethra.storage.DLMMFactory
    struct FactoryStorage {
        address hub;
        address beacon;
        VolatilityDefaults defaults;
        mapping(uint16 => bool) binSteps;
        mapping(bytes32 => address) pools;
        mapping(address => bool) isPool;
        address[] poolList;
    }

    // keccak256(abi.encode(uint256(keccak256("aethra.storage.DLMMFactory")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant FACTORY_STORAGE = 0xa143fc678f8385ef85c08953ee7bf431bce54af2053ab746c4de3f73f5be1600;

    event BinStepSet(uint16 binStepBps, bool allowed);
    event VolatilityDefaultsSet(VolatilityDefaults defaults);

    error IdenticalTokens();
    error ZeroAddress();
    error BinStepNotAllowed();
    error PoolExists();
    error UnknownPool();

    function _s() private pure returns (FactoryStorage storage $) {
        assembly ("memory-safe") {
            $.slot := FACTORY_STORAGE
        }
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, address hub_, address beacon_) external initializer {
        if (hub_ == address(0) || beacon_ == address(0)) revert ZeroAddress();
        __Ownable_init(owner_);
        FactoryStorage storage $ = _s();
        ($.hub, $.beacon) = (hub_, beacon_);
        uint16[6] memory steps = [uint16(1), 5, 10, 25, 50, 100];
        for (uint256 i; i < 6; ++i) {
            $.binSteps[steps[i]] = true;
            emit BinStepSet(steps[i], true);
        }
        _setDefaults(VolatilityDefaults({filterPeriod: 30, decayPeriod: 600, reductionBps: 5000, control: 40_000, maxAccumulator: 350_000}));
    }

    // ------------------------------------------------------------------ pools

    function createPool(CreateParams calldata p) external returns (address pool) {
        if (p.tokenA == p.tokenB) revert IdenticalTokens();
        (address t0, address t1) = p.tokenA < p.tokenB ? (p.tokenA, p.tokenB) : (p.tokenB, p.tokenA);
        if (t0 == address(0)) revert ZeroAddress();
        FactoryStorage storage $ = _s();
        if (!$.binSteps[p.binStepBps]) revert BinStepNotAllowed();
        bytes32 key = _key(t0, t1, p.binStepBps);
        if ($.pools[key] != address(0)) revert PoolExists();

        VolatilityDefaults memory d = $.defaults;
        VolatilityFee.Params memory params = VolatilityFee.Params({
            baseFee: p.baseFee,
            maxFee: p.maxFee,
            filterPeriod: d.filterPeriod,
            decayPeriod: d.decayPeriod,
            reductionBps: d.reductionBps,
            control: d.control,
            maxAccumulator: d.maxAccumulator,
            stepBps: p.binStepBps
        });
        address hub_ = $.hub;
        pool = address(
            new BeaconProxy{salt: key}(
                $.beacon, abi.encodeCall(DLMMPool.initialize, (hub_, t0, t1, p.binStepBps, p.activeId, params))
            )
        );
        $.pools[key] = pool;
        $.isPool[pool] = true;
        $.poolList.push(pool);
        IAethraHub(hub_).registerPool(bytes32(uint256(uint160(pool))), Venue.DLMM, pool, t0, t1, msg.sender);
        emit PoolCreated(pool, t0, t1, p.binStepBps, p.activeId, msg.sender);
    }

    function getPool(address tokenA, address tokenB, uint16 binStepBps) external view returns (address) {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return _s().pools[_key(t0, t1, binStepBps)];
    }

    function allPools() external view returns (address[] memory) {
        return _s().poolList;
    }

    function poolCount() external view returns (uint256) {
        return _s().poolList.length;
    }

    function isPool(address pool) external view returns (bool) {
        return _s().isPool[pool];
    }

    function hub() external view returns (address) {
        return _s().hub;
    }

    function beacon() external view returns (address) {
        return _s().beacon;
    }

    function isBinStepAllowed(uint16 binStepBps) external view returns (bool) {
        return _s().binSteps[binStepBps];
    }

    function volatilityDefaults() external view returns (VolatilityDefaults memory) {
        return _s().defaults;
    }

    function _key(address t0, address t1, uint16 step) private pure returns (bytes32) {
        return keccak256(abi.encode(t0, t1, step));
    }

    // ------------------------------------------------------------------ admin

    function setBinStep(uint16 binStepBps, bool allowed) external onlyOwner {
        if (binStepBps == 0 || binStepBps > 10_000) revert BinStepNotAllowed();
        _s().binSteps[binStepBps] = allowed;
        emit BinStepSet(binStepBps, allowed);
    }

    function setVolatilityDefaults(VolatilityDefaults calldata d) external onlyOwner {
        _setDefaults(d);
    }

    /// @notice Replace one pool's dynamic fee parameters (stepBps is forced to the pool's bin step).
    function setPoolFeeParams(address pool, VolatilityFee.Params calldata params) external onlyOwner {
        if (!_s().isPool[pool]) revert UnknownPool();
        DLMMPool(pool).setFeeParams(params);
    }

    function _setDefaults(VolatilityDefaults memory d) private {
        if (d.reductionBps > 10_000 || d.filterPeriod > d.decayPeriod) revert VolatilityFee.InvalidParams();
        _s().defaults = d;
        emit VolatilityDefaultsSet(d);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
