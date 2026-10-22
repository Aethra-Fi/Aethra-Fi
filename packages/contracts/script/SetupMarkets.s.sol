// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {AethraHub} from "../src/core/AethraHub.sol";
import {AethraPositions} from "../src/periphery/AethraPositions.sol";
import {IAethraPositions} from "../src/interfaces/IAethraPeriphery.sol";
import {AssetClass} from "../src/interfaces/IAethraHub.sol";
import {FaucetToken} from "../src/mocks/FaucetToken.sol";
import {MockPriceFeed} from "../src/mocks/MockPriceFeed.sol";

interface IWETH {
    function deposit() external payable;
}

/// @notice Localhost/testnet only: faucet test tokens, mock oracles, asset registration and seeded v4 pools.
///         Never run against mainnet.
contract SetupMarkets is Script {
    address internal constant DEPLOYER = 0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C;
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    int24 internal constant SPACING = 10;

    struct Stock {
        string symbol;
        string name;
        int256 price8; // USD, 8 decimals (mock)
    }

    string internal network;
    string internal path;
    string internal json;
    AethraHub internal hub;
    AethraPositions internal positions;
    address internal hook;
    address internal weth;
    FaucetToken internal ausd;

    function run() external {
        network = vm.envOr("NETWORK", string("local"));
        require(keccak256(bytes(network)) != keccak256("mainnet"), "SetupMarkets: never on mainnet");
        require(msg.sender == DEPLOYER, "SetupMarkets: sender must be the deployer");
        path = string.concat(vm.projectRoot(), "/../sdk/src/addresses/", network, ".json");
        json = vm.readFile(path);
        hub = AethraHub(vm.parseJsonAddress(json, ".hub"));
        positions = AethraPositions(vm.parseJsonAddress(json, ".positions"));
        hook = vm.parseJsonAddress(json, ".hook");
        weth = vm.parseJsonAddress(json, ".weth");
        uint256 seedWeth = vm.envOr("SEED_WETH", uint256(0.02 ether));

        vm.startBroadcast();

        // --- test stable + oracles for canonical assets
        ausd = new FaucetToken("Aethra Test USD", "aUSD", 6, 10_000e6, DEPLOYER);
        MockPriceFeed ethFeed = new MockPriceFeed(DEPLOYER, 8, "ETH / USD (mock)", 2400e8);
        MockPriceFeed usdFeed = new MockPriceFeed(DEPLOYER, 8, "aUSD / USD (mock)", 1e8);
        hub.setAsset(weth, AssetClass.CANONICAL, true, address(ethFeed), 0);
        hub.setAsset(address(ausd), AssetClass.CANONICAL, true, address(usdFeed), 0);
        _token("aUSD", address(ausd), "Aethra Test USD", 6, "test");
        _token("WETH", weth, "Wrapped Ether", 18, "canonical");
        _oracle("WETH", address(ethFeed));
        _oracle("aUSD", address(usdFeed));

        // --- faucet test stocks (mock oracle, 1 day staleness so a stale feed halts the pool)
        Stock[3] memory stocks = [
            Stock("aTSLA", "Aethra Test Tesla", 250e8),
            Stock("aNVDA", "Aethra Test NVIDIA", 180e8),
            Stock("aAAPL", "Aethra Test Apple", 230e8)
        ];
        FaucetToken[3] memory st;
        for (uint256 i; i < stocks.length; i++) {
            st[i] = new FaucetToken(stocks[i].name, stocks[i].symbol, 18, 10e18, DEPLOYER);
            MockPriceFeed f = new MockPriceFeed(DEPLOYER, 8, string.concat(stocks[i].symbol, " / USD (mock)"), stocks[i].price8);
            hub.setAsset(address(st[i]), AssetClass.STOCK, true, address(f), 1 days);
            _token(stocks[i].symbol, address(st[i]), stocks[i].name, 18, "stock");
            _oracle(stocks[i].symbol, address(f));
        }

        // --- existing Robinhood testnet stock tokens get mock feeds too (pools can be created by anyone)
        if (block.chainid == 46_630 || block.chainid == 31_337) _registerChainStocks();

        // --- seed v4 pools (Aethra hook, dynamic fee flag)
        IWETH(weth).deposit{value: seedWeth}();
        ausd.mint(DEPLOYER, 1_000_000e6);
        IERC20(weth).approve(address(positions), type(uint256).max);
        ausd.approve(address(positions), type(uint256).max);
        _pool(weth, address(ausd), 2400e18, 18, 6, seedWeth, seedWeth * 2400 / 1e12);
        for (uint256 i; i < st.length; i++) {
            st[i].mint(DEPLOYER, 1_000e18);
            st[i].approve(address(positions), type(uint256).max);
            uint256 px = uint256(stocks[i].price8) * 1e10;
            _pool(address(st[i]), address(ausd), px, 18, 6, 20e18, 20 * px / 1e12);
        }

        vm.stopBroadcast();

        console2.log("aUSD", address(ausd));
    }

    function _registerChainStocks() internal {
        address[5] memory t = [
            0x5884aD2f920c162CFBbACc88C9C51AA75eC09E02, // AMZN
            0xC9f9c86933092BbbfFF3CCb4b105A4A94bf3Bd4E, // TSLA
            0x71178BAc73cBeb415514eB542a8995b82669778d, // AMD
            0x1FBE1a0e43594b3455993B5dE5Fd0A7A266298d0, // PLTR
            0x3b8262A63d25f0477c4DDE23F83cfe22Cb768C93 // NFLX
        ];
        string[5] memory sym = ["AMZN", "TSLA", "AMD", "PLTR", "NFLX"];
        int256[5] memory px = [int256(220e8), 250e8, 160e8, 150e8, 1200e8];
        for (uint256 i; i < 5; i++) {
            if (t[i].code.length == 0) continue;
            MockPriceFeed f = new MockPriceFeed(DEPLOYER, 8, string.concat(sym[i], " / USD (mock)"), px[i]);
            hub.setAsset(t[i], AssetClass.STOCK, true, address(f), 1 days);
            _token(sym[i], t[i], sym[i], 18, "stock");
            _oracle(sym[i], address(f));
        }
    }

    /// @dev Create (if needed) and seed a full-range position. priceE18 = token `a` priced in token `b`.
    function _pool(address a, address b, uint256 priceE18, uint8 decA, uint8 decB, uint256 amtA, uint256 amtB) internal {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        PoolKey memory key = PoolKey(Currency.wrap(t0), Currency.wrap(t1), LPFeeLibrary.DYNAMIC_FEE_FLAG, SPACING, IHooks(hook));
        (uint256 p, uint8 d0, uint8 d1, uint256 a0, uint256 a1) =
            a == t0 ? (priceE18, decA, decB, amtA, amtB) : (1e36 / priceE18, decB, decA, amtB, amtA);
        uint160 sqrtP = _sqrtPrice(p, d0, d1);
        IPoolManager(POOL_MANAGER).initialize(key, sqrtP);
        int24 lo = TickMath.minUsableTick(SPACING);
        int24 hi = TickMath.maxUsableTick(SPACING);
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP, TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), a0, a1
        );
        positions.mint(IAethraPositions.MintParams(key, lo, hi, liq, a0 + 1, a1 + 1, DEPLOYER, block.timestamp + 1 hours));
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

    function _token(string memory key, address a, string memory name, uint8 dec, string memory kind) internal {
        string memory obj = key;
        vm.serializeAddress(obj, "address", a);
        vm.serializeString(obj, "symbol", key);
        vm.serializeString(obj, "name", name);
        vm.serializeUint(obj, "decimals", dec);
        string memory out = vm.serializeString(obj, "kind", kind);
        json = vm.serializeString("tokens", key, out);
        vm.writeJson(json, path, ".tokens");
        json = vm.readFile(path);
    }

    function _oracle(string memory key, address feed) internal {
        string memory out = vm.serializeAddress("oracles", key, feed);
        vm.writeJson(out, path, ".oracles");
        json = vm.readFile(path);
    }
}
