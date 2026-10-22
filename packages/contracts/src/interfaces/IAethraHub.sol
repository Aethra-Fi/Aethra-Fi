// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Venue identifiers shared by the hub, router, indexer and SDK.
enum Venue {
    NONE,
    V4, // Uniswap v4 pool with the Aethra hook
    DLMM, // Aethra discrete-bin pool
    DAMM, // Aethra dynamic single-range AMM
    LAUNCH // Aethra launchpad bonding curve (pre-graduation)
}

enum AssetClass {
    NONE,
    CANONICAL, // WETH, USD stables
    STOCK, // tokenized equities (oracle guarded)
    LAUNCH, // launchpad tokens
    RWA
}

/// @notice Central registry + configuration for Aethra Fi. One proxy, owned by the deployer.
interface IAethraHub {
    struct Asset {
        AssetClass class;
        bool enabled;
        address oracle; // Chainlink-style aggregator (latestRoundData + decimals), optional
        uint32 maxStaleness; // seconds; 0 = never stale
    }

    struct PoolInfo {
        Venue venue;
        address pool; // DLMM/DAMM pool address, launchpad address, or the v4 hook
        address token0;
        address token1;
        address creator;
        uint64 createdAt;
        bool enabled;
    }

    event AssetSet(address indexed token, AssetClass class, bool enabled, address oracle, uint32 maxStaleness);
    event PoolRegistered(
        bytes32 indexed poolId, Venue indexed venue, address pool, address token0, address token1, address creator
    );
    event PoolEnabled(bytes32 indexed poolId, bool enabled);
    event RegistrarSet(address indexed registrar, bool allowed);
    event OperatorSet(address indexed operator, bool allowed);
    event FeeConfigSet(address buyback, address treasury, uint16 protocolFeeShareBps);

    error NotRegistrar();
    error NotOperator();
    error PoolExists();
    error UnknownPool();
    error InvalidBps();
    error NoOracle();
    error StalePrice();
    error BadPrice();

    // --- assets & oracles
    function setAsset(address token, AssetClass class, bool enabled, address oracle, uint32 maxStaleness) external;
    function asset(address token) external view returns (Asset memory);
    function assetCount() external view returns (uint256);
    function assetAt(uint256 i) external view returns (address);
    /// @return priceE18 USD price scaled to 1e18; reverts if no oracle, stale, or non-positive.
    function getPrice(address token) external view returns (uint256 priceE18);
    /// @return priceE18 USD price (0 if unavailable) and whether it is fresh / market open.
    function tryGetPrice(address token) external view returns (uint256 priceE18, bool fresh, bool marketOpen);

    // --- pools
    function registerPool(bytes32 poolId, Venue venue, address pool, address token0, address token1, address creator)
        external;
    function setPoolEnabled(bytes32 poolId, bool enabled) external;
    function pool(bytes32 poolId) external view returns (PoolInfo memory);
    function poolCount() external view returns (uint256);
    function poolIdAt(uint256 i) external view returns (bytes32);
    function isPoolEnabled(bytes32 poolId) external view returns (bool);

    // --- roles
    function setRegistrar(address registrar, bool allowed) external;
    function setOperator(address operator, bool allowed) external;
    function isRegistrar(address a) external view returns (bool);
    function isOperator(address a) external view returns (bool);

    // --- protocol fees
    function setFeeConfig(address buyback, address treasury, uint16 protocolFeeShareBps) external;
    function buyback() external view returns (address);
    function treasury() external view returns (address);
    /// @notice Share of LP fees (bps of the fee) routed to buyback by DLMM/DAMM pools and the v4 hook.
    function protocolFeeShareBps() external view returns (uint16);

    function owner() external view returns (address);
}
