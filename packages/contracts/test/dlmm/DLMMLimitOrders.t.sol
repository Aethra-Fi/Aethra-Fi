// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IDLMMLimitOrders} from "../../src/interfaces/IAethraPools.sol";
import {DLMMLimitOrders} from "../../src/dlmm/DLMMLimitOrders.sol";
import {DLMMPool} from "../../src/dlmm/DLMMPool.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DLMMBase} from "./DLMMBase.t.sol";

contract DLMMLimitOrdersV2 is DLMMLimitOrders {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract DLMMLimitOrdersTest is DLMMBase {
    address maker = address(0x3333);
    address keeper = address(0x4444);

    function setUp() public override {
        super.setUp();
        _fund(maker, 1e30);
        _seed(pool, lp, 5, 10e18);
    }

    function _place(int24 bin, IDLMMLimitOrders.Side side, uint256 amt) internal returns (uint256 id) {
        vm.prank(maker);
        id = orders.place(address(pool), bin, side, amt, block.timestamp);
    }

    /// @dev Push the active bin up (buy token0 with token1) until it is above `bin`.
    function _pushUpPast(int24 bin) internal {
        while (pool.activeId() <= bin) _swap(pool, trader, false, 5e18);
    }

    function _pushDownPast(int24 bin) internal {
        while (pool.activeId() >= bin) _swap(pool, trader, true, 5e18);
    }

    function test_placeSellToken0() public {
        int24 bin = pool.activeId() + 2;
        uint256 balBefore = token0.balanceOf(maker);
        uint256 id = _place(bin, IDLMMLimitOrders.Side.SELL_TOKEN0, 3e18);
        assertEq(id, 1);
        assertEq(token0.balanceOf(maker), balBefore - 3e18);
        IDLMMLimitOrders.Order memory o = orders.getOrder(id);
        assertEq(o.owner, maker);
        assertEq(o.pool, address(pool));
        assertEq(o.binId, bin);
        assertEq(o.amountIn, 3e18);
        assertGt(o.shares, 0);
        assertEq(uint8(orders.status(id)), uint8(IDLMMLimitOrders.Status.OPEN));
        assertEq(pool.sharesOf(bin, address(orders)), o.shares);
        assertEq(orders.ordersOf(maker).length, 1);
        (uint256 v0, uint256 v1) = orders.orderValue(id);
        assertApproxEqAbs(v0, 3e18, 1e6);
        assertEq(v1, 0);
    }

    function test_placeRejects() public {
        int24 active = pool.activeId();
        vm.startPrank(maker);
        vm.expectRevert(DLMMLimitOrders.InvalidBin.selector);
        orders.place(address(pool), active, IDLMMLimitOrders.Side.SELL_TOKEN0, 1e18, block.timestamp);
        vm.expectRevert(DLMMLimitOrders.InvalidBin.selector);
        orders.place(address(pool), active + 1, IDLMMLimitOrders.Side.SELL_TOKEN1, 1e18, block.timestamp);
        vm.expectRevert(DLMMLimitOrders.ZeroAmount.selector);
        orders.place(address(pool), active + 1, IDLMMLimitOrders.Side.SELL_TOKEN0, 0, block.timestamp);
        vm.expectRevert(DLMMLimitOrders.Expired.selector);
        orders.place(address(pool), active + 1, IDLMMLimitOrders.Side.SELL_TOKEN0, 1e18, block.timestamp - 1);
        vm.expectRevert(DLMMLimitOrders.UnknownPool.selector);
        orders.place(address(0xdead), active + 1, IDLMMLimitOrders.Side.SELL_TOKEN0, 1e18, block.timestamp);
        vm.stopPrank();
    }

    function test_sellToken0FillsAndClaims() public {
        int24 bin = pool.activeId() + 2;
        uint256 id = _place(bin, IDLMMLimitOrders.Side.SELL_TOKEN0, 3e18);
        vm.expectRevert(DLMMLimitOrders.NotFilled.selector);
        vm.prank(maker);
        orders.claim(id, maker);

        _pushUpPast(bin);
        assertEq(uint8(orders.status(id)), uint8(IDLMMLimitOrders.Status.FILLED));
        (uint256 v0, uint256 v1) = orders.orderValue(id);
        assertEq(v0, 0);
        // filled at a price above 1 (bin above active at start) plus fees, so more token1 than token0 sold
        assertGt(v1, 3e18);

        uint256 bal1 = token1.balanceOf(maker);
        vm.prank(maker);
        (uint256 a0, uint256 a1) = orders.claim(id, maker);
        assertEq(a0, 0);
        assertEq(a1, v1);
        assertEq(token1.balanceOf(maker), bal1 + a1);
        assertEq(uint8(orders.status(id)), uint8(IDLMMLimitOrders.Status.CLOSED));
        vm.prank(maker);
        vm.expectRevert(DLMMLimitOrders.OrderClosed.selector);
        orders.claim(id, maker);
    }

    function test_sellToken1FillsViaKeeper() public {
        int24 bin = pool.activeId() - 2;
        uint256 id = _place(bin, IDLMMLimitOrders.Side.SELL_TOKEN1, 2e18);
        _pushDownPast(bin);
        assertEq(uint8(orders.status(id)), uint8(IDLMMLimitOrders.Status.FILLED));
        uint256 bal0 = token0.balanceOf(maker);
        vm.prank(keeper);
        (uint256 a0, uint256 a1) = orders.claimFor(id);
        assertGt(a0, 2e18);
        assertEq(a1, 0);
        // proceeds go to the owner, never the keeper
        assertEq(token0.balanceOf(maker), bal0 + a0);
        assertEq(token0.balanceOf(keeper), 0);
    }

    function test_claimForRejectsUnfilled() public {
        uint256 id = _place(pool.activeId() + 3, IDLMMLimitOrders.Side.SELL_TOKEN0, 1e18);
        vm.prank(keeper);
        vm.expectRevert(DLMMLimitOrders.NotFilled.selector);
        orders.claimFor(id);
    }

    function test_partialWhenActive() public {
        int24 bin = pool.activeId() + 1;
        uint256 id = _place(bin, IDLMMLimitOrders.Side.SELL_TOKEN0, 3e18);
        while (pool.activeId() < bin) _swap(pool, trader, false, 1e18);
        if (pool.activeId() == bin) {
            assertEq(uint8(orders.status(id)), uint8(IDLMMLimitOrders.Status.PARTIAL));
        }
    }

    function test_cancelReturnsInput() public {
        uint256 id = _place(pool.activeId() + 3, IDLMMLimitOrders.Side.SELL_TOKEN0, 3e18);
        vm.prank(keeper);
        vm.expectRevert(DLMMLimitOrders.NotOrderOwner.selector);
        orders.cancel(id, keeper);
        uint256 bal0 = token0.balanceOf(maker);
        vm.prank(maker);
        (uint256 a0, uint256 a1) = orders.cancel(id, maker);
        assertApproxEqAbs(a0, 3e18, 1e6);
        assertEq(a1, 0);
        assertEq(token0.balanceOf(maker), bal0 + a0);
        assertEq(uint8(orders.status(id)), uint8(IDLMMLimitOrders.Status.CLOSED));
    }

    function test_unknownOrder() public {
        assertEq(uint8(orders.status(99)), uint8(IDLMMLimitOrders.Status.NONE));
        vm.expectRevert(DLMMLimitOrders.UnknownOrder.selector);
        orders.claimFor(99);
    }

    function test_upgradeOnlyOwnerKeepsOrders() public {
        uint256 id = _place(pool.activeId() + 2, IDLMMLimitOrders.Side.SELL_TOKEN0, 1e18);
        address impl = address(new DLMMLimitOrdersV2());
        vm.expectRevert();
        orders.upgradeToAndCall(impl, "");
        vm.prank(owner);
        orders.upgradeToAndCall(impl, "");
        assertEq(DLMMLimitOrdersV2(address(orders)).version(), 2);
        assertEq(orders.getOrder(id).owner, maker);
        assertEq(orders.factory(), address(factory));
    }

    function testFuzz_cancelNeverLosesInput(uint96 amt, uint8 offset) public {
        uint256 amount = bound(uint256(amt), 1e9, 1e24);
        int24 bin = pool.activeId() + 1 + int24(uint24(bound(offset, 0, 50)));
        uint256 id = _place(bin, IDLMMLimitOrders.Side.SELL_TOKEN0, amount);
        vm.prank(maker);
        (uint256 a0,) = orders.cancel(id, maker);
        // the first deposit into an empty bin locks MIN_SHARES worth of dust, nothing more
        assertLe(a0, amount);
        assertGe(a0, amount - amount / 1e6 - 1e6);
    }
    /// @dev v1.1 gate: two makers share a bin, the bin fills, both claim. Neither claim exceeds what its deposit is worth
    ///      at the bin price plus the most fees the bin could earn, each gets at least the limit price, and together they
    ///      never take more than the bin holds.
    function testFuzz_claimNeverExceedsDeposit(uint96 amtA, uint96 amtB, uint8 offset) public {
        address other = address(0x5555);
        _fund(other, 1e30);
        uint256 a = bound(uint256(amtA), 1e12, 1e22);
        uint256 b = bound(uint256(amtB), 1e12, 1e22);
        int24 bin = pool.activeId() + 1 + int24(uint24(bound(offset, 0, 3))); // inside the seeded range, no dust lock
        uint256 idA = _place(bin, IDLMMLimitOrders.Side.SELL_TOKEN0, a);
        vm.prank(other);
        uint256 idB = orders.place(address(pool), bin, IDLMMLimitOrders.Side.SELL_TOKEN0, b, block.timestamp);

        _pushUpPast(bin);
        (, uint128 reserve1,) = pool.getBin(bin);
        uint256 price = pool.priceX128(bin);

        vm.prank(maker);
        (uint256 a0A, uint256 a1A) = orders.claim(idA, maker);
        vm.prank(other);
        (uint256 a0B, uint256 a1B) = orders.claim(idB, other);

        assertEq(a0A + a0B, 0, "filled orders pay token1 only");
        assertLe(a1A + a1B, reserve1, "claims exceed the bin");
        _assertFair(a, a1A, price);
        _assertFair(b, a1B, price);
        assertEq(token1.balanceOf(address(orders)), 0, "orders contract kept proceeds");
    }

    function _assertFair(uint256 amountIn, uint256 out, uint256 price) internal pure {
        uint256 atPrice = Math.mulDiv(amountIn, price, 1 << 128);
        assertLe(out, atPrice + Math.mulDiv(atPrice, MAX_FEE, 1e6) + 1e6, "claim above deposit value");
        assertGe(out + atPrice / 1e6 + 1e6, atPrice, "claim below the limit price");
    }
}
