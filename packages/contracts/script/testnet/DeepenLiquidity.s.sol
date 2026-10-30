// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {AethraHub} from "../../src/core/AethraHub.sol";
import {AethraPositions} from "../../src/periphery/AethraPositions.sol";
import {IAethraPositions} from "../../src/interfaces/IAethraPeriphery.sol";
import {IAethraHub, AssetClass} from "../../src/interfaces/IAethraHub.sol";
import {IDLMMFactory, IDAMMFactory} from "../../src/interfaces/IAethraPools.sol";
import {DLMMPool} from "../../src/dlmm/DLMMPool.sol";
import {DAMMPool} from "../../src/damm/DAMMPool.sol";
import {BinMath} from "../../src/dlmm/BinMath.sol";
import {FaucetToken} from "../../src/mocks/FaucetToken.sol";
import {MockPriceFeed} from "../../src/mocks/MockPriceFeed.sol";

interface IWETH {
    function deposit() external payable;
}

/// @notice Testnet only. Makes the testnet markets usable after SetupMarkets:
///         1. refreshes every mock price feed and gives stock feeds a long staleness window (they are only
///            updated by hand, so a 1 day window halted every stock pool a day after seeding),
///         2. deepens the seeded v4 pools (WETH/aUSD with SEED_WETH, stock pools with minted test tokens),
///         3. opens the first DLMM pool (aTSLA/aUSD, 21 bins, so limit orders have a market) and two DAMM pools.
/// @dev Idempotent for pool creation: existing DLMM/DAMM pools get more liquidity instead of a second pool.
///      NETWORK=testnet forge script script/testnet/DeepenLiquidity.s.sol --rpc-url testnet --account deployer \
///        --sender $DEPLOYER_ADDRESS --broadcast --slow
contract DeepenLiquidity is Script {
    using StateLibrary for IPoolManager;

    address internal constant DEPLOYER = 0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C;
    IPoolManager internal constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    int24 internal constant SPACING = 10;
    uint32 internal constant MOCK_STALENESS = 365 days;
    uint16 internal constant BIN_STEP = 25;

    struct Market {
        string symbol;
        uint256 usdE8; // mock price, USD with 8 decimals
        uint256 v4Amount; // token amount added to the v4 pool
    }

    string internal json;
    AethraHub internal hub;
    AethraPositions internal positions;
    address internal hook;
    address internal weth;
    address internal ausd;
    uint256 internal deadline;

    function run() external {
        string memory network = vm.envOr("NETWORK", string("testnet"));
        require(keccak256(bytes(network)) != keccak256("mainnet"), "DeepenLiquidity: never on mainnet");
        require(msg.sender == DEPLOYER, "DeepenLiquidity: sender must be the deployer");
        json = vm.readFile(string.concat(vm.projectRoot(), "/../sdk/src/addresses/", network, ".json"));
        hub = AethraHub(vm.parseJsonAddress(json, ".hub"));
        positions = AethraPositions(vm.parseJsonAddress(json, ".positions"));
        hook = vm.parseJsonAddress(json, ".hook");
        weth = vm.parseJsonAddress(json, ".weth");
        ausd = _tok("aUSD");
        uint256 seedWeth = vm.envOr("SEED_WETH", uint256(0.003 ether));
        deadline = block.timestamp + 1 hours;

        Market[3] memory stocks = [Market("aTSLA", 250e8, 400e18), Market("aNVDA", 180e8, 400e18), Market("aAAPL", 230e8, 400e18)];

        vm.startBroadcast();

        // 1. fresh mock prices, long staleness for every mock-fed asset
        _refresh("WETH", weth, 2400e8, AssetClass.CANONICAL);
        _refresh("aUSD", ausd, 1e8, AssetClass.CANONICAL);
        for (uint256 i; i < stocks.length; i++) _refresh(stocks[i].symbol, _tok(stocks[i].symbol), int256(stocks[i].usdE8), AssetClass.STOCK);
        string[5] memory chainStocks = ["AMZN", "TSLA", "AMD", "PLTR", "NFLX"];
        for (uint256 i; i < chainStocks.length; i++) {
            address feed = vm.parseJsonAddress(json, string.concat(".oracles.", chainStocks[i]));
            (, int256 px,,,) = MockPriceFeed(feed).latestRoundData();
            _refresh(chainStocks[i], _tok(chainStocks[i]), px, AssetClass.STOCK);
        }

        // 2. deeper v4 pools
        FaucetToken(ausd).mint(DEPLOYER, 2_000_000e6);
        _approve(ausd, address(positions));
        if (seedWeth > 0) {
            IWETH(weth).deposit{value: seedWeth}();
            _approve(weth, address(positions));
            _v4Add(weth, ausd, seedWeth, seedWeth * 2400 / 1e12);
        }
        for (uint256 i; i < stocks.length; i++) {
            address t = _tok(stocks[i].symbol);
            uint256 usd6 = stocks[i].v4Amount * stocks[i].usdE8 / 1e20;
            FaucetToken(t).mint(DEPLOYER, 1_000e18);
            _approve(t, address(positions));
            _v4Add(t, ausd, stocks[i].v4Amount, usd6);
        }

        // 3. DLMM aTSLA/aUSD and DAMM aNVDA/aUSD, aAAPL/aUSD
        address dlmm = _dlmm(_tok("aTSLA"), 250e8, 20e18, 5_000e6);
        address dammNvda = _damm(_tok("aNVDA"), 180e8, 200e18, 36_000e6);
        address dammAapl = _damm(_tok("aAAPL"), 230e8, 200e18, 46_000e6);

        vm.stopBroadcast();

        console2.log("DLMM aTSLA/aUSD", dlmm);
        console2.log("DAMM aNVDA/aUSD", dammNvda);
        console2.log("DAMM aAAPL/aUSD", dammAapl);
    }

    // ------------------------------------------------------------------ oracles

    function _refresh(string memory symbol, address token, int256 price8, AssetClass class) internal {
        address feed = vm.parseJsonAddress(json, string.concat(".oracles.", symbol));
        MockPriceFeed(feed).setPrice(price8);
        hub.setAsset(token, class, true, feed, MOCK_STALENESS);
    }

    // ------------------------------------------------------------------ v4

    /// @dev Full-range position at the pool's current price, sized so neither amount is exceeded.
    function _v4Add(address a, address b, uint256 amtA, uint256 amtB) internal {
        (address t0, address t1, uint256 a0, uint256 a1) = a < b ? (a, b, amtA, amtB) : (b, a, amtB, amtA);
        PoolKey memory key = PoolKey(Currency.wrap(t0), Currency.wrap(t1), LPFeeLibrary.DYNAMIC_FEE_FLAG, SPACING, IHooks(hook));
        (uint160 sqrtP,,,) = PM.getSlot0(key.toId());
        require(sqrtP != 0, "DeepenLiquidity: v4 pool missing");
        int24 lo = TickMath.minUsableTick(SPACING);
        int24 hi = TickMath.maxUsableTick(SPACING);
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(sqrtP, TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), a0, a1);
        positions.mint(IAethraPositions.MintParams(key, lo, hi, liq, a0 + 1, a1 + 1, DEPLOYER, deadline));
    }

    // ------------------------------------------------------------------ DLMM

    /// @dev 21 bins around the oracle price: 10 bins of token1 below, the active bin with both, 10 of token0 above.
    function _dlmm(address stock, uint256 usdE8, uint256 stockPerBin, uint256 usdPerBin) internal returns (address pool) {
        IDLMMFactory f = IDLMMFactory(vm.parseJsonAddress(json, ".dlmmFactory"));
        (address t0, address t1) = stock < ausd ? (stock, ausd) : (ausd, stock);
        // raw price of token0 in token1, Q128.128
        uint256 priceX128 = t0 == stock ? usdE8 * 1e6 * BinMath.ONE / 1e8 / 1e18 : 1e18 * 1e8 * BinMath.ONE / usdE8 / 1e6;
        int24 active = _binFor(priceX128);
        pool = f.getPool(t0, t1, BIN_STEP);
        if (pool == address(0)) {
            pool = f.createPool(IDLMMFactory.CreateParams(t0, t1, BIN_STEP, active, 3000, 50_000));
        } else {
            active = DLMMPool(pool).activeId();
        }
        FaucetToken(stock).mint(DEPLOYER, stockPerBin * 11);
        _approve(stock, pool);
        _approve(ausd, pool);
        (uint256 per0, uint256 per1) = t0 == stock ? (stockPerBin, usdPerBin) : (usdPerBin, stockPerBin);
        int24[] memory ids = new int24[](21);
        uint256[] memory a0 = new uint256[](21);
        uint256[] memory a1 = new uint256[](21);
        for (uint256 i; i < 21; i++) {
            int24 id = active - 10 + int24(int256(i));
            ids[i] = id;
            if (id >= active) a0[i] = per0;
            if (id <= active) a1[i] = per1;
        }
        DLMMPool(pool).addLiquidity(ids, a0, a1, DEPLOYER, deadline);
    }

    /// @dev Largest bin id whose price is at or below `priceX128` (binary search; bin price grows with the id).
    function _binFor(uint256 priceX128) internal pure returns (int24) {
        int24 lo = -20_000;
        int24 hi = 20_000;
        while (lo < hi) {
            int24 mid = lo + (hi - lo + 1) / 2;
            if (BinMath.getPriceX128(mid, BIN_STEP) <= priceX128) lo = mid;
            else hi = mid - 1;
        }
        return lo;
    }

    // ------------------------------------------------------------------ DAMM

    /// @dev Full-range DAMM pool at the oracle price, created once; later runs add to the first pool of the pair.
    function _damm(address stock, uint256 usdE8, uint256 stockAmt, uint256 usdAmt) internal returns (address pool) {
        IDAMMFactory f = IDAMMFactory(vm.parseJsonAddress(json, ".dammFactory"));
        (address t0, address t1) = stock < ausd ? (stock, ausd) : (ausd, stock);
        address[] memory existing = f.poolsForPair(t0, t1);
        if (existing.length == 0) {
            // price of token0 in token1 (human units, 1e18 scaled), then the raw sqrt price
            uint256 pE18 = t0 == stock ? usdE8 * 1e10 : 1e36 / (usdE8 * 1e10);
            (uint8 d0, uint8 d1) = t0 == stock ? (18, 6) : (6, 18);
            pool = f.createPool(IDAMMFactory.CreateParams(t0, t1, _sqrtPrice(pE18, d0, d1), 0, 0, 3000, 50_000, 0, 0));
        } else {
            pool = existing[0];
        }
        FaucetToken(stock).mint(DEPLOYER, stockAmt);
        _approve(stock, pool);
        _approve(ausd, pool);
        (uint256 a0, uint256 a1) = t0 == stock ? (stockAmt, usdAmt) : (usdAmt, stockAmt);
        DAMMPool(pool).addLiquidity(a0, a1, 0, DEPLOYER, deadline);
    }

    // ------------------------------------------------------------------ helpers

    function _tok(string memory symbol) internal view returns (address) {
        return vm.parseJsonAddress(json, string.concat(".tokens.", symbol, ".address"));
    }

    function _approve(address token, address spender) internal {
        if (IERC20(token).allowance(DEPLOYER, spender) < type(uint128).max) IERC20(token).approve(spender, type(uint256).max);
    }

    function _sqrtPrice(uint256 priceE18, uint8 d0, uint8 d1) internal pure returns (uint160) {
        uint256 rawX192 = priceE18 * (10 ** d1) * (1 << 96) / (10 ** d0) / 1e18 * (1 << 96);
        return uint160(_sqrt(rawX192));
    }

    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = x;
        uint256 y = (x >> 1) + 1;
        while (y < z) {
            z = y;
            y = (x / y + y) >> 1;
        }
    }
}
