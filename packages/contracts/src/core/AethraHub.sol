// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IAethraHub, Venue, AssetClass} from "../interfaces/IAethraHub.sol";
import {IAggregatorV3, IMarketSession} from "../interfaces/IOracle.sol";

/// @title AethraHub
/// @notice Asset + oracle + pool registry and protocol fee configuration. UUPS proxy, ERC-7201 storage.
contract AethraHub is IAethraHub, UUPSUpgradeable, Ownable2StepUpgradeable {
    uint16 internal constant MAX_PROTOCOL_SHARE_BPS = 5000;

    /// @custom:storage-location erc7201:aethra.storage.Hub
    struct HubStorage {
        mapping(address => Asset) assets;
        address[] assetList;
        mapping(bytes32 => PoolInfo) pools;
        bytes32[] poolList;
        mapping(address => bool) registrars;
        mapping(address => bool) operators;
        address buyback;
        address treasury;
        uint16 protocolFeeShareBps;
    }

    // keccak256(abi.encode(uint256(keccak256("aethra.storage.Hub")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant HUB_STORAGE = 0x172bfd0e12fc136e45bb6cf48227066a6a1a133fa2aab9ab3e089c53eb58fe00;

    function _s() private pure returns (HubStorage storage $) {
        assembly {
            $.slot := HUB_STORAGE
        }
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_) external initializer {
        __Ownable_init(owner_);
        _s().operators[owner_] = true;
        emit OperatorSet(owner_, true);
    }

    modifier onlyOperator() {
        if (!_s().operators[msg.sender] && msg.sender != owner()) revert NotOperator();
        _;
    }

    // ------------------------------------------------------------------ assets & oracles

    function setAsset(address token, AssetClass class, bool enabled, address oracle, uint32 maxStaleness)
        external
        onlyOperator
    {
        HubStorage storage $ = _s();
        if ($.assets[token].class == AssetClass.NONE) $.assetList.push(token);
        $.assets[token] = Asset(class, enabled, oracle, maxStaleness);
        emit AssetSet(token, class, enabled, oracle, maxStaleness);
    }

    function asset(address token) external view returns (Asset memory) {
        return _s().assets[token];
    }

    function assetCount() external view returns (uint256) {
        return _s().assetList.length;
    }

    function assetAt(uint256 i) external view returns (address) {
        return _s().assetList[i];
    }

    function getPrice(address token) external view returns (uint256 priceE18) {
        Asset memory a = _s().assets[token];
        if (a.oracle == address(0)) revert NoOracle();
        (uint256 p, uint256 updatedAt) = _read(a.oracle);
        if (p == 0) revert BadPrice();
        if (a.maxStaleness != 0 && block.timestamp > updatedAt + a.maxStaleness) revert StalePrice();
        return p;
    }

    function tryGetPrice(address token) external view returns (uint256 priceE18, bool fresh, bool marketOpen) {
        Asset memory a = _s().assets[token];
        if (a.oracle == address(0)) return (0, false, false);
        try this.readOracle(a.oracle) returns (uint256 p, uint256 updatedAt) {
            priceE18 = p;
            fresh = p != 0 && (a.maxStaleness == 0 || block.timestamp <= updatedAt + a.maxStaleness);
        } catch {
            return (0, false, false);
        }
        marketOpen = true;
        try IMarketSession(a.oracle).isMarketOpen() returns (bool open) {
            marketOpen = open;
        } catch {}
    }

    /// @dev External wrapper so tryGetPrice can catch reverts from misbehaving oracles.
    function readOracle(address oracle) external view returns (uint256 priceE18, uint256 updatedAt) {
        return _read(oracle);
    }

    function _read(address oracle) internal view returns (uint256 priceE18, uint256 updatedAt) {
        (, int256 answer,, uint256 upd,) = IAggregatorV3(oracle).latestRoundData();
        if (answer <= 0) return (0, upd);
        uint8 dec = IAggregatorV3(oracle).decimals();
        uint256 u = uint256(answer);
        priceE18 = dec <= 18 ? u * 10 ** (18 - dec) : u / 10 ** (dec - 18);
        updatedAt = upd;
    }

    // ------------------------------------------------------------------ pools

    function registerPool(bytes32 poolId, Venue venue, address pool_, address token0, address token1, address creator)
        external
    {
        HubStorage storage $ = _s();
        if (!$.registrars[msg.sender]) revert NotRegistrar();
        if ($.pools[poolId].venue != Venue.NONE) revert PoolExists();
        $.pools[poolId] = PoolInfo(venue, pool_, token0, token1, creator, uint64(block.timestamp), true);
        $.poolList.push(poolId);
        emit PoolRegistered(poolId, venue, pool_, token0, token1, creator);
    }

    function setPoolEnabled(bytes32 poolId, bool enabled) external onlyOperator {
        HubStorage storage $ = _s();
        if ($.pools[poolId].venue == Venue.NONE) revert UnknownPool();
        $.pools[poolId].enabled = enabled;
        emit PoolEnabled(poolId, enabled);
    }

    function pool(bytes32 poolId) external view returns (PoolInfo memory) {
        return _s().pools[poolId];
    }

    function poolCount() external view returns (uint256) {
        return _s().poolList.length;
    }

    function poolIdAt(uint256 i) external view returns (bytes32) {
        return _s().poolList[i];
    }

    function isPoolEnabled(bytes32 poolId) external view returns (bool) {
        return _s().pools[poolId].enabled;
    }

    // ------------------------------------------------------------------ roles

    function setRegistrar(address registrar, bool allowed) external onlyOwner {
        _s().registrars[registrar] = allowed;
        emit RegistrarSet(registrar, allowed);
    }

    function setOperator(address operator, bool allowed) external onlyOwner {
        _s().operators[operator] = allowed;
        emit OperatorSet(operator, allowed);
    }

    function isRegistrar(address a) external view returns (bool) {
        return _s().registrars[a];
    }

    function isOperator(address a) external view returns (bool) {
        return _s().operators[a] || a == owner();
    }

    // ------------------------------------------------------------------ protocol fees

    function setFeeConfig(address buyback_, address treasury_, uint16 protocolFeeShareBps_) external onlyOwner {
        if (protocolFeeShareBps_ > MAX_PROTOCOL_SHARE_BPS) revert InvalidBps();
        HubStorage storage $ = _s();
        ($.buyback, $.treasury, $.protocolFeeShareBps) = (buyback_, treasury_, protocolFeeShareBps_);
        emit FeeConfigSet(buyback_, treasury_, protocolFeeShareBps_);
    }

    function buyback() external view returns (address) {
        return _s().buyback;
    }

    function treasury() external view returns (address) {
        return _s().treasury;
    }

    function protocolFeeShareBps() external view returns (uint16) {
        return _s().protocolFeeShareBps;
    }

    function owner() public view override(IAethraHub, OwnableUpgradeable) returns (address) {
        return super.owner();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
