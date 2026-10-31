// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {IAethraHub, Venue, AssetClass} from "../../src/interfaces/IAethraHub.sol";
import {IAethraRouter, IAethraPositions} from "../../src/interfaces/IAethraPeriphery.sol";

/// @notice v1.2 opening rehearsal against the live mainnet deployment: the deployer opens stock pools exactly as
///         `scripts/mainnet-v12.sh open` does (Chainlink feeds for TSLA, NVDA, AAPL, WETH and USDG), an LP opens and
///         seeds a TSLA/USDG pool at the oracle price, the router swaps both ways, the circuit breaker refuses a skewed
///         opening, and a stale feed halts swaps while liquidity can still be withdrawn.
///         Opt-in because it needs the network:  FORK_MAINNET=1 forge test --match-path test/fork/MainnetV12.t.sol -vv
contract MainnetV12Test is Test {
    address constant DEPLOYER = 0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C;
    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address constant LP = address(0x1111A);
    address constant USER = address(0xA11CE5);
    int24 constant SPACING = 10;

    // Robinhood stock tokens ("• Robinhood Token") and their Chainlink feed proxies, checked on-chain 2026-10-31
    address constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant TSLA_FEED = 0x4A1166a659A55625345e9515b32adECea5547C38;
    address constant NVDA_FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    address constant AAPL_FEED = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;
    address constant WETH_FEED = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    address constant USDG_FEED = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;
    // staleness windows of scripts/mainnet-v12.sh: longer than each feed's longest observed gap
    uint32 constant STOCK_STALENESS = 1 days; // stock feeds update 24/5, up to ~14h overnight
    uint32 constant WETH_STALENESS = 1 days;
    uint32 constant USDG_STALENESS = 2 days; // heartbeat is 24h

    IAethraHub hub;
    IAethraRouter router;
    IAethraPositions positions;
    address weth;
    address usdg;
    address hook;

    function setUp() public {
        if (!vm.envOr("FORK_MAINNET", false)) return;
        vm.createSelectFork("mainnet");
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/../sdk/src/addresses/mainnet.json"));
        hub = IAethraHub(vm.parseJsonAddress(json, ".hub"));
        router = IAethraRouter(vm.parseJsonAddress(json, ".router"));
        positions = IAethraPositions(vm.parseJsonAddress(json, ".positions"));
        hook = vm.parseJsonAddress(json, ".hook");
        weth = vm.parseJsonAddress(json, ".weth");
        usdg = vm.parseJsonAddress(json, ".tokens.USDG.address");
    }

    /// @dev what `scripts/mainnet-v12.sh open` sends
    function _open() internal {
        vm.startPrank(DEPLOYER);
        hub.setAsset(weth, AssetClass.CANONICAL, true, WETH_FEED, WETH_STALENESS);
        hub.setAsset(usdg, AssetClass.CANONICAL, true, USDG_FEED, USDG_STALENESS);
        hub.setAsset(TSLA, AssetClass.STOCK, true, TSLA_FEED, STOCK_STALENESS);
        hub.setAsset(NVDA, AssetClass.STOCK, true, NVDA_FEED, STOCK_STALENESS);
        hub.setAsset(AAPL, AssetClass.STOCK, true, AAPL_FEED, STOCK_STALENESS);
        vm.stopPrank();
    }

    function _key(address stock) internal view returns (PoolKey memory) {
        (address t0, address t1) = stock < usdg ? (stock, usdg) : (usdg, stock);
        return PoolKey(Currency.wrap(t0), Currency.wrap(t1), LPFeeLibrary.DYNAMIC_FEE_FLAG, SPACING, IHooks(hook));
    }

    /// @dev opening sqrt price of the stock/USDG pool at `bps` of the oracle price (both tokens have fixed decimals: 18 and 6)
    function _sqrtPrice(address stock, uint256 bps) internal view returns (uint160) {
        uint256 priceE18 = hub.getPrice(stock) * 1e18 / hub.getPrice(usdg) * bps / 10_000; // USDG per stock, human units
        // raw USDG units per raw stock unit = priceE18 * 10^6 / 10^18 / 1e18
        uint256 ratioX192 = stock < usdg
            ? FullMath.mulDiv(priceE18 * 1e6, 1 << 192, 1e36)
            : FullMath.mulDiv(1e36, 1 << 192, priceE18 * 1e6); // token1 = stock: invert
        return uint160(_sqrt(ratioX192));
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

    /// @dev opens the pool at the oracle price and seeds `stockAmt` of the stock with the matching USDG, full range
    function _seed(address stock, uint256 stockAmt) internal returns (PoolKey memory key, uint256 tokenId) {
        key = _key(stock);
        uint160 sqrtP = _sqrtPrice(stock, 10_000);
        uint256 usdgAmt = stockAmt * hub.getPrice(stock) / hub.getPrice(usdg) / 1e12;
        deal(stock, LP, stockAmt);
        deal(usdg, LP, usdgAmt);
        PM.initialize(key, sqrtP);
        int24 lo = TickMath.minUsableTick(SPACING);
        int24 hi = TickMath.maxUsableTick(SPACING);
        (uint256 amt0, uint256 amt1) = stock < usdg ? (stockAmt, usdgAmt) : (usdgAmt, stockAmt);
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP, TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), amt0, amt1
        );
        vm.startPrank(LP);
        IERC20(stock).approve(address(positions), stockAmt);
        IERC20(usdg).approve(address(positions), usdgAmt);
        (tokenId,,) = positions.mint(
            IAethraPositions.MintParams(key, lo, hi, liq, amt0, amt1, LP, block.timestamp + 30 minutes)
        );
        vm.stopPrank();
    }

    function test_closedTodayThenOpenAndTrade() public {
        vm.skip(!vm.envOr("FORK_MAINNET", false));

        // locked today: stock assets are STOCK, disabled, no oracle, so a pool cannot start
        assertFalse(hub.asset(TSLA).enabled, "TSLA already open");
        assertEq(hub.asset(TSLA).oracle, address(0), "TSLA already has a feed");
        vm.expectRevert();
        PM.initialize(_key(TSLA), 79228162514264337593543950336);

        _open();
        assertTrue(hub.asset(TSLA).enabled && hub.asset(NVDA).enabled && hub.asset(AAPL).enabled, "stocks not enabled");
        // every feed answers: fresh and a sane human-unit price
        for (uint256 i; i < 5; i++) {
            address t = [TSLA, NVDA, AAPL, weth, usdg][i];
            (uint256 p, bool live,) = hub.tryGetPrice(t);
            assertTrue(live, "feed not fresh");
            assertGt(p, 0.9e18, "feed price too low");
        }
        assertApproxEqRel(hub.getPrice(usdg), 1e18, 0.01e18, "USDG not near $1");

        // an opening price 10% off the oracle is refused (breaker band is 5%)
        uint160 skewed = _sqrtPrice(TSLA, 11_000); // computed first: expectRevert binds to the next external call
        vm.expectRevert();
        PM.initialize(_key(TSLA), skewed);

        // open and seed at the oracle price; 1 TSLA is about $400, so the pool holds about $40k
        (PoolKey memory key, uint256 tokenId) = _seed(TSLA, 50e18);
        IAethraHub.PoolInfo memory info = hub.pool(bytes32(_poolId(key)));
        assertEq(uint8(info.venue), uint8(Venue.V4), "pool not registered as v4");
        assertTrue(info.enabled, "pool not enabled");

        // swap USDG -> TSLA and back; quote equals the executed amount
        IAethraRouter.Hop[] memory buy = new IAethraRouter.Hop[](1);
        buy[0] = IAethraRouter.Hop(Venue.V4, address(0), usdg, TSLA, abi.encode(key));
        uint256 usdgIn = 100e6;
        (uint256 quoted,) = router.quote(buy, usdgIn);
        uint256 fair = usdgIn * 1e12 * 1e18 / (hub.getPrice(TSLA) * 1e18 / hub.getPrice(usdg));
        assertGt(quoted, fair * 95 / 100, "quote too far below the oracle price");
        assertLt(quoted, fair, "quote above the oracle price");
        deal(usdg, USER, usdgIn);
        vm.startPrank(USER);
        IERC20(usdg).approve(address(router), usdgIn);
        uint256 got = router.swap(buy, usdgIn, quoted * 99 / 100, USER, block.timestamp, false);
        assertEq(got, quoted, "swap paid a different amount than quoted");
        assertEq(IERC20(TSLA).balanceOf(USER), got, "user did not receive TSLA");

        IAethraRouter.Hop[] memory sell = new IAethraRouter.Hop[](1);
        sell[0] = IAethraRouter.Hop(Venue.V4, address(0), TSLA, usdg, abi.encode(key));
        IERC20(TSLA).approve(address(router), got);
        uint256 back = router.swap(sell, got, 0, USER, block.timestamp, false);
        vm.stopPrank();
        assertGt(back, usdgIn * 95 / 100, "round trip lost more than fees and impact");

        // a stale feed halts the pool (fail closed) but liquidity can always be withdrawn
        vm.warp(block.timestamp + 3 days);
        (, bool fresh,) = hub.tryGetPrice(TSLA);
        assertFalse(fresh, "feed still fresh after 3 days");
        vm.prank(USER);
        vm.expectRevert();
        router.swap(buy, 1e6, 0, USER, block.timestamp, false);
        IAethraPositions.Position memory pos = positions.getPosition(tokenId);
        vm.prank(LP);
        (uint256 a0, uint256 a1) = positions.decreaseLiquidity(tokenId, pos.liquidity, 0, 0, LP, block.timestamp);
        assertGt(a0, 0, "no token0 withdrawn");
        assertGt(a1, 0, "no token1 withdrawn");
    }

    function test_nvdaAndAaplOpenAtTheirOraclePrice() public {
        vm.skip(!vm.envOr("FORK_MAINNET", false));
        _open();
        _seed(NVDA, 10e18);
        _seed(AAPL, 10e18);
        assertEq(uint8(hub.pool(bytes32(_poolId(_key(NVDA)))).venue), uint8(Venue.V4));
        assertEq(uint8(hub.pool(bytes32(_poolId(_key(AAPL)))).venue), uint8(Venue.V4));
    }

    /// @dev setting feeds on WETH and USDG must not disturb a canonical (non-stock) pool
    function test_canonicalPoolStillTradesAfterOpen() public {
        vm.skip(!vm.envOr("FORK_MAINNET", false));
        _open();
        PoolKey memory key =
            PoolKey(Currency.wrap(weth), Currency.wrap(usdg), LPFeeLibrary.DYNAMIC_FEE_FLAG, SPACING, IHooks(hook));
        uint256 priceE18 = hub.getPrice(weth) * 1e18 / hub.getPrice(usdg);
        uint160 sqrtP = uint160(_sqrt(FullMath.mulDiv(priceE18 * 1e6, 1 << 192, 1e36)));
        PM.initialize(key, sqrtP);
        uint256 wethAmt = 0.01 ether;
        uint256 usdgAmt = wethAmt * priceE18 / 1e18 / 1e12;
        deal(weth, LP, wethAmt);
        deal(usdg, LP, usdgAmt);
        int24 lo = TickMath.minUsableTick(SPACING);
        int24 hi = TickMath.maxUsableTick(SPACING);
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP, TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), wethAmt, usdgAmt
        );
        vm.startPrank(LP);
        IERC20(weth).approve(address(positions), wethAmt);
        IERC20(usdg).approve(address(positions), usdgAmt);
        positions.mint(IAethraPositions.MintParams(key, lo, hi, liq, wethAmt, usdgAmt, LP, block.timestamp + 30 minutes));
        vm.stopPrank();

        // a week later the feeds are long stale, and the DYNAMIC pool still swaps
        vm.warp(block.timestamp + 7 days);
        IAethraRouter.Hop[] memory h = new IAethraRouter.Hop[](1);
        h[0] = IAethraRouter.Hop(Venue.V4, address(0), weth, usdg, abi.encode(key));
        deal(weth, USER, 0.0005 ether);
        vm.startPrank(USER);
        IERC20(weth).approve(address(router), 0.0005 ether);
        uint256 out = router.swap(h, 0.0005 ether, 0, USER, block.timestamp, false);
        vm.stopPrank();
        assertGt(out, 0, "canonical pool did not swap");
    }

    function _poolId(PoolKey memory key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }
}
