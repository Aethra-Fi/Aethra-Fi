// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AethraFixture, TestToken} from "../utils/AethraFixture.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {AethraRouter} from "../../src/periphery/AethraRouter.sol";
import {AethraHub} from "../../src/core/AethraHub.sol";
import {IAethraHub} from "../../src/interfaces/IAethraHub.sol";
import {AethraHook} from "../../src/hooks/AethraHook.sol";
import {IAethraRouter} from "../../src/interfaces/IAethraPeriphery.sol";
import {Venue, AssetClass} from "../../src/interfaces/IAethraHub.sol";
import {MockPriceFeed} from "../../src/mocks/MockPriceFeed.sol";

/// @dev Attacker-controlled "launchpad". Returns whatever amountOut it likes and moves no tokens.
contract FakeLaunchpad {
    uint256 public lie;

    constructor(uint256 lie_) {
        lie = lie_;
    }

    function swapExactInput(address, address, uint256, uint256, address, uint256) external view returns (uint256) {
        return lie;
    }
}

/// @notice Regression tests for the router / hook security review (2026-10-30): R-1..R-3, H-1, H-2 and the stock-pool guard.
contract RouterHookAuditTest is AethraFixture {
    using PoolIdLibrary for PoolKey;

    PoolKey internal ethUsd;
    PoolKey internal stockUsd;
    address internal attacker = makeAddr("attacker");
    address internal enabledPoolAsAddress = makeAddr("registeredDlmmPool");

    function setUp() public {
        setUpAethra();
        ethUsd = keyFor(address(weth), address(usd), 10);
        stockUsd = keyFor(address(stock), address(usd), 10);
        manager.initialize(ethUsd, _sqrt(address(weth), address(usd), 2400e18));
        manager.initialize(stockUsd, _sqrt(address(stock), address(usd), 250e18));
        mintFullRange(alice, ethUsd, _a(ethUsd, address(weth), 100e18, 240_000e6), _b(ethUsd, address(weth), 100e18, 240_000e6));

        // a DLMM/DAMM pool is registered in the hub under id == its own address; that is all the LAUNCH hop checks
        vm.prank(owner);
        hub.setRegistrar(address(this), true);
        hub.registerPool(
            bytes32(uint256(uint160(enabledPoolAsAddress))), Venue.DLMM, enabledPoolAsAddress, address(weth), address(usd), alice
        );

        weth.mint(attacker, 10e18);
        vm.prank(attacker);
        weth.approve(address(router), type(uint256).max);
    }

    // ---- helpers
    function _sqrt(address base, address quote, uint256 priceUsdE18) internal view returns (uint160) {
        PoolKey memory k = keyFor(base, quote, 10);
        bool baseIs0 = Currency.unwrap(k.currency0) == base;
        uint256 p = baseIs0 ? priceUsdE18 : 1e36 / priceUsdE18;
        return sqrtPriceFor(p, TestToken(Currency.unwrap(k.currency0)).decimals(), TestToken(Currency.unwrap(k.currency1)).decimals());
    }

    function _a(PoolKey memory k, address base, uint256 baseAmt, uint256 usdAmt) internal pure returns (uint256) {
        return Currency.unwrap(k.currency0) == base ? baseAmt : usdAmt;
    }

    function _b(PoolKey memory k, address base, uint256 baseAmt, uint256 usdAmt) internal pure returns (uint256) {
        return Currency.unwrap(k.currency0) == base ? usdAmt : baseAmt;
    }

    function _fakeHop(address fake, address tIn, address tOut) internal view returns (IAethraRouter.Hop memory) {
        return IAethraRouter.Hop(Venue.LAUNCH, fake, tIn, tOut, abi.encode(enabledPoolAsAddress));
    }

    // =============================================================== ROUTER

    /// R-1: a hop must name the exact contract the hub registered for that id and venue. A DLMM pool's id is its own
    /// address, so it used to satisfy the LAUNCH check for any attacker-supplied `hop.pool`.
    function test_fakeLaunchHopIsRejected() public {
        usd.mint(address(router), 5_000e6); // stray balance held by the router
        FakeLaunchpad fake = new FakeLaunchpad(5_000e6);

        IAethraRouter.Hop[] memory h = new IAethraRouter.Hop[](2);
        h[0] = _fakeHop(address(fake), address(weth), address(usd));
        h[1] = v4Hop(ethUsd, address(usd), address(weth));

        vm.prank(attacker);
        vm.expectRevert(AethraRouter.PoolNotEnabled.selector);
        router.swap(h, 1, 0, attacker, block.timestamp, false);
        assertEq(usd.balanceOf(address(router)), 5_000e6, "stray balance untouched");
    }

    /// R-2: the spoofed RouteExecuted event can no longer be produced.
    function test_fakeHopCannotSpoofRouteEvent() public {
        FakeLaunchpad fake = new FakeLaunchpad(1_000_000_000e6);
        IAethraRouter.Hop[] memory h = new IAethraRouter.Hop[](1);
        h[0] = _fakeHop(address(fake), address(weth), address(usd));
        vm.prank(attacker);
        vm.expectRevert(AethraRouter.PoolNotEnabled.selector);
        router.swap(h, 1, 0, attacker, block.timestamp, false);
        vm.expectRevert(AethraRouter.PoolNotEnabled.selector);
        router.quote(h, 1);
    }

    /// R-1: a registered id used with the wrong venue is rejected too.
    function test_wrongVenueForRegisteredPoolIsRejected() public {
        FakeLaunchpad fake = new FakeLaunchpad(1);
        IAethraRouter.Hop[] memory h = new IAethraRouter.Hop[](1);
        // enabledPoolAsAddress is registered as DLMM with pool == itself; naming the fake as pool or venue fails
        h[0] = IAethraRouter.Hop(Venue.DAMM, enabledPoolAsAddress, address(weth), address(usd), "");
        vm.prank(attacker);
        vm.expectRevert(AethraRouter.PoolNotEnabled.selector);
        router.swap(h, 1, 0, attacker, block.timestamp, false);
        h[0] = IAethraRouter.Hop(Venue.DLMM, address(fake), address(weth), address(usd), "");
        vm.prank(attacker);
        vm.expectRevert(AethraRouter.PoolNotEnabled.selector);
        router.swap(h, 1, 0, attacker, block.timestamp, false);
    }

    /// R-3: a hop through a properly registered pool leaves no allowance behind.
    function test_noDanglingAllowanceAfterRegisteredHop() public {
        FakeLaunchpad fake = new FakeLaunchpad(1);
        address launchToken = makeAddr("launchToken");
        hub.registerPool(bytes32(uint256(uint160(launchToken))), Venue.LAUNCH, address(fake), address(weth), launchToken, alice);

        IAethraRouter.Hop[] memory h = new IAethraRouter.Hop[](1);
        h[0] = IAethraRouter.Hop(Venue.LAUNCH, address(fake), address(weth), launchToken, abi.encode(launchToken));
        vm.prank(attacker);
        router.swap(h, 1e18, 0, attacker, block.timestamp, false);
        assertEq(weth.allowance(address(router), address(fake)), 0);
    }

    function test_ok_slippageChecksFinalOutput() public {
        IAethraRouter.Hop[] memory h = new IAethraRouter.Hop[](1);
        h[0] = v4Hop(ethUsd, address(weth), address(usd));
        vm.prank(attacker);
        vm.expectRevert(IAethraRouter.Slippage.selector);
        router.swap(h, 1e18, type(uint256).max, attacker, block.timestamp, false);
    }

    // =============================================================== HOOK

    /// H-1: an ORACLE-mode pool cannot start away from the oracle.
    function test_oraclePoolMustStartInsideOracleBand() public {
        PoolKey memory k = keyFor(address(stock), address(usd), 60);
        uint160 skewed = _sqrt(address(stock), address(usd), 1000e18); // oracle says 250
        uint160 inBand = _sqrt(address(stock), address(usd), 252e18); // inside the 5% band
        vm.expectRevert(); // hook revert is wrapped by the PoolManager
        manager.initialize(k, skewed);

        manager.initialize(k, inBand);
        AethraHook.PoolView memory v = hook.poolView(k);
        assertEq(uint8(v.mode), uint8(AethraHook.Mode.ORACLE));
        assertLt(v.deviationBps, 500);
    }

    /// Stock-pool guard: a STOCK asset registered without oracle (enabled=false) cannot be pooled yet, at any price.
    function test_stockWithoutOracleCannotBePooled() public {
        TestToken pending = new TestToken("Pending Stock", "pSTK", 18);
        vm.prank(owner);
        hub.setAsset(address(pending), AssetClass.STOCK, false, address(0), 0);
        PoolKey memory k = keyFor(address(pending), address(usd), 10);
        uint160 price = _sqrt(address(pending), address(usd), 100e18);
        vm.expectRevert();
        manager.initialize(k, price);

        // an oracle without enabling the asset is still refused
        MockPriceFeed feed = new MockPriceFeed(owner, 8, "P/USD", 100e8);
        vm.prank(owner);
        hub.setAsset(address(pending), AssetClass.STOCK, false, address(feed), 1 days);
        vm.expectRevert();
        manager.initialize(k, price);

        // once enabled and priced, the pool opens
        vm.prank(owner);
        hub.setAsset(address(pending), AssetClass.STOCK, true, address(feed), 1 days);
        manager.initialize(k, price);
        assertEq(uint8(hook.poolView(k).mode), uint8(AethraHook.Mode.ORACLE));
    }

    /// H-2: an oracle needs a finite staleness window.
    function test_zeroStalenessWithOracleIsRejected() public {
        MockPriceFeed feed = new MockPriceFeed(owner, 8, "X/USD", 100e8);
        TestToken t = new TestToken("X", "X", 18);
        vm.startPrank(owner);
        vm.expectRevert(IAethraHub.InvalidStaleness.selector);
        hub.setAsset(address(t), AssetClass.STOCK, true, address(feed), 0);
        hub.setAsset(address(t), AssetClass.STOCK, false, address(0), 0); // no oracle: 0 is fine
        vm.stopPrank();
    }

    /// Stale oracle halts every swap of a stock pool (fail-closed). Documented for ops, not a bug.
    function test_ok_staleOracleFailsClosed() public {
        mintFullRange(alice, stockUsd, _a(stockUsd, address(stock), 1000e18, 250_000e6), _b(stockUsd, address(stock), 1000e18, 250_000e6));
        vm.warp(block.timestamp + 2 days);
        IAethraRouter.Hop[] memory h = new IAethraRouter.Hop[](1);
        h[0] = v4Hop(stockUsd, address(usd), address(stock));
        (uint256 q,) = router.quote(h, 1000e6);
        assertEq(q, 0, "quote reports no route");
    }
}
