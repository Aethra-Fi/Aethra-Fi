// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AethraFixture, TestToken} from "../utils/AethraFixture.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {AethraHook} from "../../src/hooks/AethraHook.sol";
import {AethraRouter} from "../../src/periphery/AethraRouter.sol";
import {AethraPositions} from "../../src/periphery/AethraPositions.sol";
import {IAethraPositions, IAethraRouter} from "../../src/interfaces/IAethraPeriphery.sol";
import {IAethraHub, Venue} from "../../src/interfaces/IAethraHub.sol";
import {MockPriceFeed} from "../../src/mocks/MockPriceFeed.sol";

contract HookV2 is AethraHook {
    constructor(IPoolManager m) AethraHook(m) {}

    function version() external pure returns (uint256) {
        return 2;
    }
}

contract CoreV4Test is AethraFixture {
    using PoolIdLibrary for PoolKey;

    PoolKey internal ethUsd; // dynamic mode
    PoolKey internal stockUsd; // oracle mode

    function setUp() public {
        setUpAethra();
        ethUsd = keyFor(address(weth), address(usd), 10);
        stockUsd = keyFor(address(stock), address(usd), 10);
        _init(ethUsd, address(weth), 2400e18);
        _init(stockUsd, address(stock), 250e18);
        _seed(ethUsd, address(weth), 100e18, 240_000e6);
        _seed(stockUsd, address(stock), 1000e18, 250_000e6);
    }

    function _init(PoolKey memory key, address base, uint256 priceUsdE18) internal {
        // price as token1 per token0 in human units
        bool baseIs0 = Currency.unwrap(key.currency0) == base;
        uint256 p = baseIs0 ? priceUsdE18 : 1e36 / priceUsdE18;
        uint8 d0 = TestToken(Currency.unwrap(key.currency0)).decimals();
        uint8 d1 = TestToken(Currency.unwrap(key.currency1)).decimals();
        manager.initialize(key, sqrtPriceFor(p, d0, d1));
    }

    function _seed(PoolKey memory key, address base, uint256 baseAmt, uint256 usdAmt) internal returns (uint256 id) {
        bool baseIs0 = Currency.unwrap(key.currency0) == base;
        (id,) = mintFullRange(alice, key, baseIs0 ? baseAmt : usdAmt, baseIs0 ? usdAmt : baseAmt);
    }

    function _hops1(PoolKey memory key, address tin, address tout) internal pure returns (IAethraRouter.Hop[] memory h) {
        h = new IAethraRouter.Hop[](1);
        h[0] = v4Hop(key, tin, tout);
    }

    // ------------------------------------------------------------------ registration & modes

    function test_poolsRegisteredWithModes() public view {
        assertEq(hub.poolCount(), 2);
        IAethraHub.PoolInfo memory info = hub.pool(PoolId.unwrap(ethUsd.toId()));
        assertEq(uint8(info.venue), uint8(Venue.V4));
        assertEq(info.pool, address(hook));
        assertEq(uint8(hook.poolConfig(ethUsd.toId()).mode), uint8(AethraHook.Mode.DYNAMIC));
        assertEq(uint8(hook.poolConfig(stockUsd.toId()).mode), uint8(AethraHook.Mode.ORACLE));
    }

    function test_rejectsStaticFeePools() public {
        PoolKey memory k = ethUsd;
        k.fee = 3000;
        vm.expectRevert();
        manager.initialize(k, TickMath.getSqrtPriceAtTick(0));
    }

    function test_onlyLaunchpadInitializesLaunchTokenPools() public {
        TestToken launched = new TestToken("Launched", "LNCH", 18);
        address launchpad = makeAddr("launchpad");
        vm.prank(owner);
        hub.setRegistrar(address(this), true);
        hub.registerPool(
            bytes32(uint256(uint160(address(launched)))), Venue.LAUNCH, launchpad, address(weth), address(launched), alice
        );
        PoolKey memory k = keyFor(address(weth), address(launched), 60);
        // a front-runner cannot pre-initialize the graduation pool at a skewed price
        vm.expectRevert();
        manager.initialize(k, TickMath.getSqrtPriceAtTick(50_000));
        vm.prank(launchpad);
        manager.initialize(k, TickMath.getSqrtPriceAtTick(0));
    }

    function test_onlyPositionsCanAddLiquidity() public {
        // a direct modifyLiquidity through a foreign router must be rejected by beforeAddLiquidity
        Adder adder = new Adder(manager);
        weth.mint(address(adder), 10e18);
        usd.mint(address(adder), 100_000e6);
        vm.expectRevert();
        adder.add(ethUsd);
    }

    // ------------------------------------------------------------------ swaps & quotes

    function test_swapExactInMatchesQuote() public {
        IAethraRouter.Hop[] memory h = _hops1(ethUsd, address(weth), address(usd));
        (uint256 q,) = router.quote(h, 1e18);
        assertGt(q, 2300e6);
        assertLt(q, 2400e6);
        uint256 before = usd.balanceOf(bob);
        vm.prank(bob);
        uint256 out = router.swap(h, 1e18, q, bob, block.timestamp, false);
        assertEq(out, q);
        assertEq(usd.balanceOf(bob) - before, q);
    }

    function test_swapWithEthAndUnwrap() public {
        vm.deal(bob, 10 ether);
        IAethraRouter.Hop[] memory h = _hops1(ethUsd, address(weth), address(usd));
        vm.prank(bob);
        uint256 out = router.swap{value: 1 ether}(h, 1 ether, 0, bob, block.timestamp, false);
        assertGt(out, 0);

        IAethraRouter.Hop[] memory back = _hops1(ethUsd, address(usd), address(weth));
        uint256 ethBefore = bob.balance;
        vm.prank(bob);
        uint256 ethOut = router.swap(back, 1000e6, 0, bob, block.timestamp, true);
        assertEq(bob.balance - ethBefore, ethOut);
    }

    function test_multiHopViaUsd() public {
        IAethraRouter.Hop[] memory h = new IAethraRouter.Hop[](2);
        h[0] = v4Hop(ethUsd, address(weth), address(usd));
        h[1] = v4Hop(stockUsd, address(usd), address(stock));
        (uint256 q, uint256[] memory hops) = router.quote(h, 1e18);
        assertEq(hops.length, 2);
        // 1 ETH ≈ 2400 USD ≈ 9.6 TSLA (minus fees)
        assertGt(q, 9e18);
        vm.prank(bob);
        uint256 out = router.swap(h, 1e18, q * 99 / 100, bob, block.timestamp, false);
        assertEq(out, q);
    }

    function test_slippageAndDeadline() public {
        IAethraRouter.Hop[] memory h = _hops1(ethUsd, address(weth), address(usd));
        (uint256 q,) = router.quote(h, 1e18);
        vm.prank(bob);
        vm.expectRevert(IAethraRouter.Slippage.selector);
        router.swap(h, 1e18, q + 1, bob, block.timestamp, false);
        vm.prank(bob);
        vm.expectRevert(IAethraRouter.Expired.selector);
        router.swap(h, 1e18, 0, bob, block.timestamp - 1, false);
    }

    function test_badRouteChaining() public {
        IAethraRouter.Hop[] memory h = new IAethraRouter.Hop[](2);
        h[0] = v4Hop(ethUsd, address(weth), address(usd));
        h[1] = v4Hop(ethUsd, address(weth), address(usd));
        vm.prank(bob);
        vm.expectRevert(IAethraRouter.BadRoute.selector);
        router.swap(h, 1e18, 0, bob, block.timestamp, false);
    }

    function test_disabledPoolCannotSwap() public {
        vm.prank(owner);
        hub.setPoolEnabled(PoolId.unwrap(ethUsd.toId()), false);
        IAethraRouter.Hop[] memory h = _hops1(ethUsd, address(weth), address(usd));
        (uint256 q,) = router.quote(h, 1e18);
        assertEq(q, 0);
        vm.prank(bob);
        vm.expectRevert();
        router.swap(h, 1e18, 0, bob, block.timestamp, false);
    }

    // ------------------------------------------------------------------ dynamic fee

    function test_dynamicFeeRisesWithVolatilityAndDecays() public {
        uint24 calm = hook.poolView(ethUsd).feeZeroForOne;
        assertEq(calm, 500);
        IAethraRouter.Hop[] memory h = _hops1(ethUsd, address(weth), address(usd));
        vm.startPrank(bob);
        router.swap(h, 20e18, 0, bob, block.timestamp, false); // big move
        vm.stopPrank();
        uint24 hot = hook.poolView(ethUsd).feeZeroForOne;
        assertGt(hot, calm);
        vm.warp(block.timestamp + 1 hours);
        assertEq(hook.poolView(ethUsd).feeZeroForOne, calm);
    }

    // ------------------------------------------------------------------ protocol fee

    function test_protocolFeeAccruesAndSweepsToBuyback() public {
        IAethraRouter.Hop[] memory h = _hops1(ethUsd, address(weth), address(usd));
        vm.prank(bob);
        router.swap(h, 5e18, 0, bob, block.timestamp, false);
        // exact-in WETH -> USD: protocol share is taken on the output currency (USD)
        uint256 accrued = hook.protocolFees(Currency.wrap(address(usd)));
        assertGt(accrued, 0);
        uint256 swept = hook.collectProtocolFees(Currency.wrap(address(usd)));
        assertEq(swept, accrued);
        assertEq(usd.balanceOf(buybackSink), accrued);
        assertEq(hook.protocolFees(Currency.wrap(address(usd))), 0);
    }

    // ------------------------------------------------------------------ oracle guard

    function test_oracleGuardTowardOraclePaysBase() public {
        // push pool price above oracle by buying stock, then selling stock (toward oracle) pays base fee
        bool stockIs0 = Currency.unwrap(stockUsd.currency0) == address(stock);
        IAethraRouter.Hop[] memory buy = _hops1(stockUsd, address(usd), address(stock));
        vm.prank(bob);
        router.swap(buy, 5000e6, 0, bob, block.timestamp, false);
        AethraHook.PoolView memory v = hook.poolView(stockUsd);
        assertGt(v.deviationBps, 0);
        uint24 sellFee = stockIs0 ? v.feeZeroForOne : v.feeOneForZero;
        uint24 buyFee = stockIs0 ? v.feeOneForZero : v.feeZeroForOne;
        assertEq(sellFee, 3000);
        assertGt(buyFee, sellFee);
    }

    function test_circuitBreakerBlocksDeviationIncreasingSwap() public {
        IAethraRouter.Hop[] memory buy = _hops1(stockUsd, address(usd), address(stock));
        // a swap that would push the pool more than 5% above the oracle reverts
        vm.prank(bob);
        vm.expectRevert();
        router.swap(buy, 100_000e6, 0, bob, block.timestamp, false);
        // a modest one is fine
        vm.prank(bob);
        router.swap(buy, 2_000e6, 0, bob, block.timestamp, false);
    }

    function test_oracleMoveTripsBreakerButArbitrageAllowed() public {
        // oracle jumps +10%: pool is now 10% below oracle; buying stock (toward oracle) is allowed,
        // selling stock (away) is blocked
        MockPriceFeed feed = MockPriceFeed(hub.asset(address(stock)).oracle);
        vm.prank(owner);
        feed.setPrice(275e8);
        AethraHook.PoolView memory v = hook.poolView(stockUsd);
        assertTrue(v.breakerTripped);
        IAethraRouter.Hop[] memory sell = _hops1(stockUsd, address(stock), address(usd));
        vm.prank(bob);
        vm.expectRevert();
        router.swap(sell, 1e18, 0, bob, block.timestamp, false);
        IAethraRouter.Hop[] memory buy = _hops1(stockUsd, address(usd), address(stock));
        vm.prank(bob);
        router.swap(buy, 10_000e6, 0, bob, block.timestamp, false);
    }

    function test_staleOracleHaltsStockPool() public {
        vm.warp(block.timestamp + 2 days);
        IAethraRouter.Hop[] memory buy = _hops1(stockUsd, address(usd), address(stock));
        vm.prank(bob);
        vm.expectRevert();
        router.swap(buy, 100e6, 0, bob, block.timestamp, false);
        // dynamic pools without an oracle dependency keep trading (WETH feed is stale too, but unused)
        IAethraRouter.Hop[] memory h = _hops1(ethUsd, address(weth), address(usd));
        vm.prank(bob);
        router.swap(h, 1e17, 0, bob, block.timestamp, false);
    }

    function test_closedMarketMultipliesFee() public {
        MockPriceFeed feed = MockPriceFeed(hub.asset(address(stock)).oracle);
        uint24 openFee = hook.poolView(stockUsd).feeZeroForOne;
        vm.prank(owner);
        feed.setPriceAndSession(250e8, false);
        AethraHook.PoolView memory v = hook.poolView(stockUsd);
        assertFalse(v.marketOpen);
        assertEq(v.feeZeroForOne, openFee * 2);
    }

    // ------------------------------------------------------------------ positions

    function test_positionLifecycle() public {
        (uint256 id, uint128 liq) = mintFullRange(bob, ethUsd, 1e18, 2400e6);
        assertEq(positions.ownerOf(id), bob);
        assertEq(positions.getPosition(id).liquidity, liq);
        (uint256 a0, uint256 a1) = positions.positionAmounts(id);
        assertGt(a0 + a1, 0);

        // generate fees
        IAethraRouter.Hop[] memory h = _hops1(ethUsd, address(weth), address(usd));
        vm.prank(alice);
        router.swap(h, 10e18, 0, alice, block.timestamp, false);

        vm.prank(bob);
        (uint256 f0, uint256 f1) = positions.collect(id, bob);
        assertGt(f0 + f1, 0);

        vm.prank(bob);
        positions.decreaseLiquidity(id, liq, 0, 0, bob, block.timestamp);
        assertEq(positions.getPosition(id).liquidity, 0);
        vm.prank(bob);
        positions.burn(id);
        vm.expectRevert();
        positions.ownerOf(id);
    }

    function test_onlyOwnerCanDecrease() public {
        (uint256 id, uint128 liq) = mintFullRange(bob, ethUsd, 1e18, 2400e6);
        vm.prank(alice);
        vm.expectRevert(IAethraPositions.NotOwnerOrApproved.selector);
        positions.decreaseLiquidity(id, liq, 0, 0, alice, block.timestamp);
    }

    function test_permanentLock() public {
        (uint256 id, uint128 liq) = mintFullRange(bob, ethUsd, 1e18, 2400e6);
        vm.prank(bob);
        positions.lock(id, type(uint64).max, type(uint64).max);
        assertEq(positions.withdrawable(id), 0);
        vm.warp(block.timestamp + 3650 days);
        vm.prank(bob);
        vm.expectRevert(IAethraPositions.LockedLiquidity.selector);
        positions.decreaseLiquidity(id, liq, 0, 0, bob, block.timestamp);
        // fees remain collectable
        vm.prank(bob);
        positions.collect(id, bob);
    }

    function test_vestingLock() public {
        (uint256 id, uint128 liq) = mintFullRange(bob, ethUsd, 1e18, 2400e6);
        uint64 cliff = uint64(block.timestamp + 10 days);
        uint64 end = uint64(block.timestamp + 110 days);
        vm.prank(bob);
        positions.lock(id, cliff, end);
        assertEq(positions.withdrawable(id), 0);
        vm.warp(cliff + 50 days); // halfway
        uint128 w = positions.withdrawable(id);
        assertApproxEqRel(w, liq / 2, 0.001e18);
        vm.prank(bob);
        positions.decreaseLiquidity(id, w, 0, 0, bob, block.timestamp);
        assertEq(positions.withdrawable(id), 0);
        vm.warp(end);
        assertEq(positions.withdrawable(id), liq - w);

        // weaker re-lock is rejected while active
        vm.warp(cliff + 60 days);
        vm.prank(bob);
        vm.expectRevert(IAethraPositions.InvalidLock.selector);
        positions.lock(id, cliff, end - 1);
    }

    function testFuzz_vestingNeverExceedsLiquidity(uint32 dt, uint32 len) public {
        (uint256 id, uint128 liq) = mintFullRange(bob, ethUsd, 1e18, 2400e6);
        len = uint32(bound(len, 1, 400 days));
        vm.prank(bob);
        positions.lock(id, uint64(block.timestamp), uint64(block.timestamp + len));
        vm.warp(block.timestamp + dt);
        assertLe(positions.withdrawable(id), liq);
    }

    // ------------------------------------------------------------------ upgrades

    function test_hookUpgradeKeepsPoolState() public {
        AethraHook.PoolConfig memory before = hook.poolConfig(ethUsd.toId());
        address impl = address(new HookV2(manager));
        vm.prank(owner);
        hook.upgradeToAndCall(impl, "");
        assertEq(HookV2(address(hook)).version(), 2);
        AethraHook.PoolConfig memory afterUp = hook.poolConfig(ethUsd.toId());
        assertEq(uint8(afterUp.mode), uint8(before.mode));
        assertEq(afterUp.fee.baseFee, before.fee.baseFee);
        // swaps still work through the upgraded hook
        IAethraRouter.Hop[] memory h = _hops1(ethUsd, address(weth), address(usd));
        vm.prank(bob);
        router.swap(h, 1e17, 0, bob, block.timestamp, false);
    }

    function test_routerAndPositionsUpgradeOnlyOwner() public {
        address r2 = address(new AethraRouter(manager, address(weth)));
        vm.expectRevert();
        router.upgradeToAndCall(r2, "");
        vm.prank(owner);
        router.upgradeToAndCall(r2, "");

        address p2 = address(new AethraPositions(manager));
        vm.expectRevert();
        positions.upgradeToAndCall(p2, "");
        vm.prank(owner);
        positions.upgradeToAndCall(p2, "");
        assertEq(positions.name(), "Aethra Liquidity Position");
    }

    function testFuzz_swapRoundTripLoses(uint96 amt) public {
        uint256 amountIn = bound(uint256(amt), 1e15, 5e18);
        IAethraRouter.Hop[] memory h = _hops1(ethUsd, address(weth), address(usd));
        IAethraRouter.Hop[] memory back = _hops1(ethUsd, address(usd), address(weth));
        vm.startPrank(bob);
        uint256 mid = router.swap(h, amountIn, 0, bob, block.timestamp, false);
        uint256 end = router.swap(back, mid, 0, bob, block.timestamp, false);
        vm.stopPrank();
        assertLt(end, amountIn);
    }
}

/// @dev Minimal foreign liquidity adder used to prove the hook rejects non-Aethra LP managers.
contract Adder {
    IPoolManager internal immutable m;

    constructor(IPoolManager m_) {
        m = m_;
    }

    function add(PoolKey memory key) external {
        m.unlock(abi.encode(key));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        PoolKey memory key = abi.decode(data, (PoolKey));
        m.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(-600, 600, 1e12, 0), "");
        return "";
    }
}
