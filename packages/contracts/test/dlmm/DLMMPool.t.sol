// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedPointMathLib as FPM} from "solady/utils/FixedPointMathLib.sol";
import {IAethraPool} from "../../src/interfaces/IAethraPools.sol";
import {IAethraHub, Venue} from "../../src/interfaces/IAethraHub.sol";
import {DLMMPool} from "../../src/dlmm/DLMMPool.sol";
import {VolatilityFee} from "../../src/libraries/VolatilityFee.sol";
import {DLMMBase} from "./DLMMBase.t.sol";

contract DLMMPoolTest is DLMMBase {
    uint256 constant ONE = 1 << 128;

    function _sum(DLMMPool p) internal view returns (uint256 s0, uint256 s1) {
        (, uint128[] memory r0, uint128[] memory r1) = p.getBins(-100_000, 100_000, 10_000);
        for (uint256 i; i < r0.length; ++i) {
            s0 += r0[i];
            s1 += r1[i];
        }
    }

    function _assertSolvent(DLMMPool p) internal view {
        (uint256 s0, uint256 s1) = _sum(p);
        (uint128 f0, uint128 f1) = p.protocolFees();
        assertGe(token0.balanceOf(address(p)), s0 + f0, "solvent0");
        assertGe(token1.balanceOf(address(p)), s1 + f1, "solvent1");
    }

    // ------------------------------------------------------------------ init

    function test_initialState() public view {
        assertEq(pool.token0(), address(token0));
        assertEq(pool.token1(), address(token1));
        assertEq(pool.binStepBps(), STEP);
        assertEq(pool.activeId(), 0);
        assertEq(pool.currentFee(), BASE_FEE);
        assertEq(pool.factory(), address(factory));
        assertEq(pool.priceX128(0), ONE);
        IAethraHub.PoolInfo memory info = hub.pool(bytes32(uint256(uint160(address(pool)))));
        assertEq(uint8(info.venue), uint8(Venue.DLMM));
        assertEq(info.pool, address(pool));
        assertEq(info.token0, address(token0));
        assertEq(info.creator, address(this));
    }

    function test_cannotReinitialize() public {
        VolatilityFee.Params memory p;
        vm.expectRevert();
        pool.initialize(address(hub), address(token0), address(token1), STEP, 0, p);
    }

    // ------------------------------------------------------------------ liquidity

    function test_addLiquiditySideRules() public {
        vm.startPrank(lp);
        vm.expectRevert(abi.encodeWithSelector(DLMMPool.InvalidBin.selector, int24(1)));
        pool.addLiquidity(_one(1), _oneU(0), _oneU(1e18), lp, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(DLMMPool.InvalidBin.selector, int24(-1)));
        pool.addLiquidity(_one(-1), _oneU(1e18), _oneU(0), lp, block.timestamp);
        vm.expectRevert(IAethraPool.ZeroAmount.selector);
        pool.addLiquidity(_one(0), _oneU(0), _oneU(0), lp, block.timestamp);
        vm.expectRevert(DLMMPool.LengthMismatch.selector);
        pool.addLiquidity(_one(0), new uint256[](2), _oneU(0), lp, block.timestamp);
        vm.expectRevert(IAethraPool.Expired.selector);
        pool.addLiquidity(_one(0), _oneU(1), _oneU(1), lp, block.timestamp - 1);
        vm.stopPrank();
    }

    function test_firstDepositLocksMinimum() public {
        uint256 s = _add(pool, lp, 0, 1e18, 2e18);
        assertEq(s, 3e18 - pool.MIN_SHARES());
        (uint128 r0, uint128 r1, uint256 total) = pool.getBin(0);
        assertEq(r0, 1e18);
        assertEq(r1, 2e18);
        assertEq(total, 3e18);
        assertEq(pool.sharesOf(0, lp), s);

        // a dust first deposit cannot mint shares
        vm.prank(lp);
        vm.expectRevert(IAethraPool.ZeroAmount.selector);
        pool.addLiquidity(_one(5), _oneU(900), _oneU(0), lp, block.timestamp);
    }

    function test_valueBasedShares() public {
        // bin 4: price = 1.0025^4; token0 only
        uint256 s = _add(pool, lp, 4, 1e18, 0);
        uint256 price = pool.priceX128(4);
        assertEq(s, FPM.fullMulDiv(price, 1e18, ONE) - 1000);
        // second depositor gets proportional shares
        uint256 s2 = _add(pool, trader, 4, 5e17, 0);
        (,, uint256 total) = pool.getBin(4);
        assertApproxEqAbs(s2, (total - s2) / 2, 2);
    }

    function test_addRemoveRoundTrip() public {
        uint256 b0 = token0.balanceOf(lp);
        uint256 b1 = token1.balanceOf(lp);
        uint256[] memory shares = _seed(pool, lp, 5, 1e18);
        int24[] memory ids = new int24[](11);
        for (uint256 i; i < 11; ++i) ids[i] = int24(int256(i)) - 5;
        vm.prank(lp);
        (uint256 a0, uint256 a1) = pool.removeLiquidity(ids, shares, 0, 0, lp, block.timestamp);
        // everything back except the locked minimum dust
        assertLe(a0, 6e18);
        assertLe(a1, 6e18);
        assertApproxEqAbs(a0, 6e18, 11 * 1000);
        assertApproxEqAbs(a1, 6e18, 11 * 1000);
        assertEq(token0.balanceOf(lp), b0 - 6e18 + a0);
        assertEq(token1.balanceOf(lp), b1 - 6e18 + a1);
        assertEq(pool.sharesOf(0, lp), 0);
        // bins stay initialised by the locked shares
        (,, uint256 total) = pool.getBin(0);
        assertEq(total, 1000);
    }

    function testFuzz_roundTripNoValueCreation(uint96 x0, uint96 y0, uint96 x, uint96 y, int8 activeShift) public {
        vm.assume(uint256(x0) + y0 > 1e6);
        vm.assume(uint256(x) + y > 0);
        int24 active = int24(activeShift);
        DLMMPool p = _createPool(10, active, BASE_FEE, MAX_FEE);
        _approve(p, lp);
        _approve(p, trader);
        _add(p, lp, active, x0, y0);

        uint256 price = p.priceX128(active);
        vm.prank(trader);
        try p.addLiquidity(_one(active), _oneU(x), _oneU(y), trader, block.timestamp) returns (uint256[] memory s) {
            vm.prank(trader);
            (uint256 a0, uint256 a1) = p.removeLiquidity(_one(active), s, 0, 0, trader, block.timestamp);
            uint256 valueIn = FPM.fullMulDiv(price, x, ONE) + y;
            uint256 valueOut = FPM.fullMulDiv(price, a0, ONE) + a1;
            assertLe(valueOut, valueIn + 1, "value created");
        } catch (bytes memory err) {
            // only dust deposits may fail
            assertEq(bytes4(err), IAethraPool.ZeroAmount.selector);
        }
    }

    function test_removeLiquidityChecks() public {
        uint256 s = _add(pool, lp, 0, 1e18, 1e18);
        vm.startPrank(lp);
        vm.expectRevert(DLMMPool.InsufficientShares.selector);
        pool.removeLiquidity(_one(0), _oneU(s + 1), 0, 0, lp, block.timestamp);
        vm.expectRevert(IAethraPool.Slippage.selector);
        pool.removeLiquidity(_one(0), _oneU(s), 1e18, 0, lp, block.timestamp);
        vm.expectRevert(IAethraPool.Expired.selector);
        pool.removeLiquidity(_one(0), _oneU(s), 0, 0, lp, block.timestamp - 1);
        vm.expectRevert(IAethraPool.ZeroAmount.selector);
        pool.removeLiquidity(_one(0), _oneU(0), 0, 0, lp, block.timestamp);
        vm.stopPrank();
    }

    function test_transferShares() public {
        uint256 s = _add(pool, lp, 0, 1e18, 1e18);
        vm.prank(lp);
        pool.transferShares(0, trader, s / 2);
        assertEq(pool.sharesOf(0, trader), s / 2);
        assertEq(pool.sharesOf(0, lp), s - s / 2);
        vm.prank(lp);
        vm.expectRevert(DLMMPool.InsufficientShares.selector);
        pool.transferShares(0, trader, s);
        vm.prank(trader);
        (uint256 a0, uint256 a1) = pool.removeLiquidity(_one(0), _oneU(s / 2), 0, 0, trader, block.timestamp);
        assertApproxEqAbs(a0, 5e17, 1000);
        assertApproxEqAbs(a1, 5e17, 1000);
    }

    function test_compositionFeeOnActiveBin() public {
        _add(pool, lp, 0, 10e18, 10e18);
        // deposit only token0 into the active bin then withdraw pro-rata: an implicit swap that pays the fee
        uint256 s = _add(pool, trader, 0, 2e18, 0);
        vm.prank(trader);
        (uint256 a0, uint256 a1) = pool.removeLiquidity(_one(0), _oneU(s), 0, 0, trader, block.timestamp);
        uint256 valueOut = a0 + a1; // price 1
        // ~0.91e18 implicitly swapped at 0.30%; the depositor recaptures its own share of the fee
        assertLt(valueOut, 2e18 - 2e15);
        assertGt(valueOut, 2e18 - 3e15);
    }

    // ------------------------------------------------------------------ swaps

    function test_swapToken0InMovesDown() public {
        _seed(pool, lp, 10, 1e18);
        (uint256 q,) = pool.quoteExactInput(address(token0), 3.5e18);
        uint256 b1 = token1.balanceOf(trader);
        uint256 out = _swap(pool, trader, true, 3.5e18);
        assertEq(out, q);
        assertEq(token1.balanceOf(trader) - b1, out);
        assertEq(pool.activeId(), -3);
        // bins 0..-2 were fully converted into token0, bin -3 is mixed
        (uint128 r0, uint128 r1,) = pool.getBin(-1);
        assertGt(r0, 0);
        assertEq(r1, 0);
        (r0, r1,) = pool.getBin(-3);
        assertGt(r0, 0);
        assertGt(r1, 0);
        // output close to 3.5e18 minus fees, price below 1
        assertLt(out, 3.5e18);
        assertGt(out, 3.4e18);
        _assertSolvent(pool);
    }

    function test_swapToken1InMovesUp() public {
        _seed(pool, lp, 10, 1e18);
        (uint256 q,) = pool.quoteExactInput(address(token1), 5.2e18);
        uint256 out = _swap(pool, trader, false, 5.2e18);
        assertEq(out, q);
        assertEq(pool.activeId(), 5);
        (uint128 r0, uint128 r1,) = pool.getBin(3);
        assertEq(r0, 0);
        assertGt(r1, 0);
        assertLt(out, 5.2e18);
        _assertSolvent(pool);
    }

    function test_swapSkipsEmptyBins() public {
        _add(pool, lp, 0, 1e18, 1e18);
        _add(pool, lp, -500, 0, 1e18);
        _add(pool, lp, 7_000, 1e18, 0);
        uint256 out = _swap(pool, trader, true, 1.5e18);
        assertEq(pool.activeId(), -500);
        assertGt(out, 1e18);
        out = _swap(pool, trader, false, 3e18);
        assertEq(pool.activeId(), 7_000);
        _assertSolvent(pool);
    }

    function testFuzz_quoteMatchesSwap(uint96 amountIn, bool zeroForOne, uint8 n) public {
        n = uint8(bound(n, 1, 40));
        _seed(pool, lp, int24(uint24(n)), 1e18);
        uint256 amt = bound(amountIn, 1, uint256(n) * 1e18);
        (uint256 q,) = pool.quoteExactInput(zeroForOne ? address(token0) : address(token1), amt);
        if (q == 0) {
            vm.prank(trader);
            try pool.swapExactInput(zeroForOne ? address(token0) : address(token1), amt, 0, trader, block.timestamp)
            returns (uint256 out) {
                assertEq(out, 0);
            } catch (bytes memory err) {
                assertEq(bytes4(err), DLMMPool.InsufficientLiquidity.selector);
            }
            return;
        }
        uint256 out = _swap(pool, trader, zeroForOne, amt);
        assertEq(out, q);
        _assertSolvent(pool);
    }

    function test_roundTripSwapLoses() public {
        _seed(pool, lp, 20, 1e18);
        uint256 out = _swap(pool, trader, true, 4e18);
        uint256 back = _swap(pool, trader, false, out);
        assertLt(back, 4e18);
    }

    // ------------------------------------------------------------------ fees

    function test_feesSplitBetweenLpsAndProtocol() public {
        _add(pool, lp, 0, 0, 10e18);
        uint256 amt = 1e18;
        uint256 out = _swap(pool, trader, true, amt);
        uint256 fee = FPM.fullMulDivUp(amt, BASE_FEE, 1e6);
        uint256 pFee = fee * 2000 / 10_000;
        assertEq(out, amt - fee); // price 1
        (uint128 f0, uint128 f1) = pool.protocolFees();
        assertEq(f0, pFee);
        assertEq(f1, 0);
        (uint128 r0, uint128 r1,) = pool.getBin(0);
        assertEq(r0, amt - pFee); // LP fee compounds in the bin
        assertEq(r1, 10e18 - out);

        // LP withdraws and earns the LP fee
        uint256 s = pool.sharesOf(0, lp);
        vm.prank(lp);
        (uint256 a0, uint256 a1) = pool.removeLiquidity(_one(0), _oneU(s), 0, 0, lp, block.timestamp);
        assertGt(a0 + a1, 10e18 - 1000);

        // protocol fees go to buyback
        (uint256 c0, uint256 c1) = pool.collectProtocolFees();
        assertEq(c0, pFee);
        assertEq(c1, 0);
        assertEq(token0.balanceOf(buyback), pFee);
        (f0,) = pool.protocolFees();
        assertEq(f0, 0);
    }

    function test_protocolFeesAccrueWithoutBuyback() public {
        vm.prank(owner);
        hub.setFeeConfig(address(0), address(0), 1000);
        _seed(pool, lp, 3, 1e18);
        _swap(pool, trader, false, 1e18);
        (, uint128 f1) = pool.protocolFees();
        assertGt(f1, 0);
        (uint256 c0, uint256 c1) = pool.collectProtocolFees();
        assertEq(c0 + c1, 0);
        (, uint128 f1b) = pool.protocolFees();
        assertEq(f1b, f1);
        vm.prank(owner);
        hub.setFeeConfig(buyback, address(0), 1000);
        pool.collectProtocolFees();
        assertEq(token1.balanceOf(buyback), f1);
    }

    function test_zeroProtocolShare() public {
        vm.prank(owner);
        hub.setFeeConfig(buyback, address(0), 0);
        _seed(pool, lp, 3, 1e18);
        _swap(pool, trader, true, 1e18);
        (uint128 f0,) = pool.protocolFees();
        assertEq(f0, 0);
    }

    function test_dynamicFeeRisesAndDecays() public {
        _seed(pool, lp, 30, 1e18);
        assertEq(pool.currentFee(), BASE_FEE);
        _swap(pool, trader, true, 10e18); // crosses ~10 bins
        uint24 hot = pool.currentFee();
        assertGt(hot, BASE_FEE);
        assertLe(hot, MAX_FEE);

        // a second swap in the same burst pays at least as much
        (, uint24 quoted) = pool.quoteExactInput(address(token0), 1e18);
        assertEq(quoted, hot);

        // after the filter period the reference decays by half, after the decay period it resets
        vm.warp(block.timestamp + 31);
        uint24 warm = pool.currentFee();
        assertLt(warm, hot);
        assertGt(warm, BASE_FEE);
        vm.warp(block.timestamp + 601);
        assertEq(pool.currentFee(), BASE_FEE);
    }

    function test_volatileSwapPaysMoreFee() public {
        _seed(pool, lp, 30, 1e18);
        _swap(pool, trader, true, 5e18);
        // a follow-up swap in the same burst pays the raised fee
        (uint256 q,) = pool.quoteExactInput(address(token0), 1e18);
        vm.warp(block.timestamp + 1000);
        (uint256 qCalm,) = pool.quoteExactInput(address(token0), 1e18);
        assertGt(qCalm, q); // lower fee after decay => more output
    }

    // ------------------------------------------------------------------ reverts

    function test_swapReverts() public {
        _seed(pool, lp, 3, 1e18);
        vm.startPrank(trader);
        vm.expectRevert(IAethraPool.Expired.selector);
        pool.swapExactInput(address(token0), 1e18, 0, trader, block.timestamp - 1);
        vm.expectRevert(IAethraPool.ZeroAmount.selector);
        pool.swapExactInput(address(token0), 0, 0, trader, block.timestamp);
        vm.expectRevert(IAethraPool.InvalidToken.selector);
        pool.swapExactInput(address(0xdead), 1e18, 0, trader, block.timestamp);
        (uint256 q,) = pool.quoteExactInput(address(token0), 1e18);
        vm.expectRevert(IAethraPool.Slippage.selector);
        pool.swapExactInput(address(token0), 1e18, q + 1, trader, block.timestamp);
        vm.expectRevert(DLMMPool.InsufficientLiquidity.selector);
        pool.swapExactInput(address(token0), 100e18, 0, trader, block.timestamp);
        vm.stopPrank();
        (uint256 q2,) = pool.quoteExactInput(address(token0), 100e18);
        assertEq(q2, 0);
        vm.expectRevert(IAethraPool.InvalidToken.selector);
        pool.quoteExactInput(address(0xdead), 1);
    }

    function test_maxBinsPerSwap() public {
        uint256 len = 200;
        int24[] memory ids = new int24[](len);
        uint256[] memory a0 = new uint256[](len);
        uint256[] memory a1 = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            ids[i] = -int24(int256(i));
            a1[i] = 1e15;
        }
        vm.prank(lp);
        pool.addLiquidity(ids, a0, a1, lp, block.timestamp);
        // token0 cost per bin grows by 0.25% per bin: ~259e15 drains all 200 bins, 160e15 needs ~134 bins
        // (above the per-swap cap) and 85e15 about 78 bins
        (uint256 q,) = pool.quoteExactInput(address(token0), 160e15);
        assertEq(q, 0);
        vm.prank(trader);
        vm.expectRevert(DLMMPool.InsufficientLiquidity.selector);
        pool.swapExactInput(address(token0), 160e15, 0, trader, block.timestamp);
        // below the cap is fine
        uint256 gasBefore = gasleft();
        _swap(pool, trader, true, 85e15);
        emit log_named_uint("gas for ~78-bin swap", gasBefore - gasleft());
        assertLt(pool.activeId(), -70);
    }

    // ------------------------------------------------------------------ views

    function test_getBins() public {
        _seed(pool, lp, 3, 1e18);
        _add(pool, lp, 100, 1e18, 0);
        (int24[] memory ids, uint128[] memory r0, uint128[] memory r1) = pool.getBins(-10, 200, 100);
        assertEq(ids.length, 8);
        assertEq(ids[0], -3);
        assertEq(ids[7], 100);
        assertEq(r0[7], 1e18);
        assertEq(r1[0], 1e18);
        (ids,,) = pool.getBins(-10, 200, 2);
        assertEq(ids.length, 2);
        assertEq(ids[1], -2);
        (ids,,) = pool.getBins(1, 3, 100);
        assertEq(ids.length, 3);
        (ids,,) = pool.getBins(5, 1, 100);
        assertEq(ids.length, 0);
        (ids,,) = pool.getBins(100, 100, 100);
        assertEq(ids.length, 1);
    }

    function test_setFeeParamsOnlyFactory() public {
        VolatilityFee.Params memory p = pool.feeParams();
        vm.expectRevert(DLMMPool.NotFactory.selector);
        pool.setFeeParams(p);
        p.baseFee = 500;
        vm.prank(owner);
        factory.setPoolFeeParams(address(pool), p);
        assertEq(pool.currentFee(), 500);
        p.baseFee = p.maxFee + 1;
        vm.prank(owner);
        vm.expectRevert(VolatilityFee.InvalidParams.selector);
        factory.setPoolFeeParams(address(pool), p);
    }

    function _approve(DLMMPool p, address who) internal {
        vm.startPrank(who);
        token0.approve(address(p), type(uint256).max);
        token1.approve(address(p), type(uint256).max);
        vm.stopPrank();
    }
}
