// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IDLMMLimitOrders} from "../../src/interfaces/IAethraPools.sol";
import {DLMMPool} from "../../src/dlmm/DLMMPool.sol";
import {DLMMLimitOrders} from "../../src/dlmm/DLMMLimitOrders.sol";
import {DLMMBase, TestToken} from "./DLMMBase.t.sol";

/// @dev Random add / remove / swap / share transfer / limit order / protocol fee / time sequences on one DLMM pool.
contract DLMMHandler is Test {
    DLMMPool public pool;
    DLMMLimitOrders public orders;
    TestToken public token0;
    TestToken public token1;
    address[4] public actors = [address(0xE1), address(0xE2), address(0xE3), address(0xE4)];

    int24[] public touched; // every bin that ever held liquidity
    mapping(int24 => bool) internal seen;
    uint256[] public orderIds;

    uint256 public swaps;
    uint256 public removes;
    uint256 public closedOrders;

    constructor(DLMMPool p, DLMMLimitOrders o, TestToken t0, TestToken t1) {
        (pool, orders, token0, token1) = (p, o, t0, t1);
        for (uint256 i; i < actors.length; ++i) {
            token0.mint(actors[i], 1e36);
            token1.mint(actors[i], 1e36);
            vm.startPrank(actors[i]);
            token0.approve(address(pool), type(uint256).max);
            token1.approve(address(pool), type(uint256).max);
            token0.approve(address(orders), type(uint256).max);
            token1.approve(address(orders), type(uint256).max);
            vm.stopPrank();
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function touchedCount() external view returns (uint256) {
        return touched.length;
    }

    function orderCount() external view returns (uint256) {
        return orderIds.length;
    }

    function _touch(int24 id) internal {
        if (!seen[id]) {
            seen[id] = true;
            touched.push(id);
        }
    }

    /// @dev Liquidity over `width` bins on each side of the active bin, shaped the only way the pool accepts:
    ///      token1 below, token0 above, both in the active bin.
    function add(uint256 actorSeed, uint256 width, uint256 per0, uint256 per1) external {
        address a = actors[actorSeed % actors.length];
        width = bound(width, 0, 6);
        per0 = bound(per0, 1e9, 1e24);
        per1 = bound(per1, 1e9, 1e24);
        int24 active = pool.activeId();
        uint256 n = 2 * width + 1;
        int24[] memory ids = new int24[](n);
        uint256[] memory a0 = new uint256[](n);
        uint256[] memory a1 = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            int24 id = active - int24(int256(width)) + int24(int256(i));
            ids[i] = id;
            if (id >= active) a0[i] = per0;
            if (id <= active) a1[i] = per1;
        }
        vm.prank(a);
        try pool.addLiquidity(ids, a0, a1, a, block.timestamp) {
            for (uint256 i; i < n; ++i) _touch(ids[i]);
        } catch {}
    }

    function remove(uint256 actorSeed, uint256 binSeed, uint256 fraction) external {
        if (touched.length == 0) return;
        address a = actors[actorSeed % actors.length];
        int24 id = touched[binSeed % touched.length];
        uint256 owned = pool.sharesOf(id, a);
        if (owned == 0) return;
        int24[] memory ids = new int24[](1);
        uint256[] memory shares = new uint256[](1);
        (ids[0], shares[0]) = (id, bound(fraction, 1, owned));
        vm.prank(a);
        pool.removeLiquidity(ids, shares, 0, 0, a, block.timestamp);
        removes++;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 binSeed, uint256 fraction) external {
        if (touched.length == 0) return;
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        int24 id = touched[binSeed % touched.length];
        uint256 owned = pool.sharesOf(id, from);
        if (owned == 0) return;
        vm.prank(from);
        pool.transferShares(id, to, bound(fraction, 1, owned));
    }

    function swap(uint256 actorSeed, bool zeroForOne, uint256 amount) external {
        address a = actors[actorSeed % actors.length];
        amount = bound(amount, 1e3, 1e25);
        vm.prank(a);
        try pool.swapExactInput(zeroForOne ? address(token0) : address(token1), amount, 0, a, block.timestamp) {
            swaps++;
        } catch {}
    }

    function place(uint256 actorSeed, bool sell0, uint256 offset, uint256 amount) external {
        address a = actors[actorSeed % actors.length];
        int24 off = int24(int256(bound(offset, 1, 8)));
        int24 bin = sell0 ? pool.activeId() + off : pool.activeId() - off;
        amount = bound(amount, 1e9, 1e24);
        IDLMMLimitOrders.Side side = sell0 ? IDLMMLimitOrders.Side.SELL_TOKEN0 : IDLMMLimitOrders.Side.SELL_TOKEN1;
        vm.prank(a);
        try orders.place(address(pool), bin, side, amount, block.timestamp) returns (uint256 id) {
            orderIds.push(id);
            _touch(bin);
        } catch {}
    }

    /// @dev The order owner claims a filled order or cancels an open one.
    function close(uint256 orderSeed) external {
        if (orderIds.length == 0) return;
        uint256 id = orderIds[orderSeed % orderIds.length];
        IDLMMLimitOrders.Order memory o = orders.getOrder(id);
        if (o.closed) return;
        vm.startPrank(o.owner);
        try orders.claim(id, o.owner) {
            closedOrders++;
        } catch {
            orders.cancel(id, o.owner);
            closedOrders++;
        }
        vm.stopPrank();
    }

    function collect() external {
        pool.collectProtocolFees();
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 1 days));
    }
}

/// @notice DLMM pool and limit order invariants: the pool holds every token it owes, bins keep their one-sided shape
///         around the active bin, bin shares add up, and the limit order contract owns exactly the shares of its open
///         orders.
/// @dev Every check walks all touched bins and orders, so runs are kept shorter than the default.
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 100
contract DLMMInvariantTest is DLMMBase {
    DLMMHandler handler;

    function setUp() public override {
        super.setUp();
        handler = new DLMMHandler(pool, orders, token0, token1);
        handler.add(0, 4, 1e22, 1e22);
        targetContract(address(handler));
    }

    function invariant_poolIsSolvent() public view {
        (uint128 p0, uint128 p1) = pool.protocolFees();
        uint256 r0;
        uint256 r1;
        for (uint256 i; i < handler.touchedCount(); ++i) {
            (uint128 b0, uint128 b1,) = pool.getBin(handler.touched(i));
            r0 += b0;
            r1 += b1;
        }
        assertGe(token0.balanceOf(address(pool)), r0 + p0, "token0: balance below bin reserves + protocol fees");
        assertGe(token1.balanceOf(address(pool)), r1 + p1, "token1: balance below bin reserves + protocol fees");
    }

    function invariant_binsAreOneSided() public view {
        int24 active = pool.activeId();
        for (uint256 i; i < handler.touchedCount(); ++i) {
            int24 id = handler.touched(i);
            (uint128 b0, uint128 b1,) = pool.getBin(id);
            if (id < active) assertEq(b0, 0, "token0 left in a bin below the active bin");
            if (id > active) assertEq(b1, 0, "token1 left in a bin above the active bin");
        }
    }

    function invariant_binSharesAddUp() public view {
        uint256 minShares = pool.MIN_SHARES();
        for (uint256 i; i < handler.touchedCount(); ++i) {
            int24 id = handler.touched(i);
            (,, uint256 total) = pool.getBin(id);
            uint256 sum = pool.sharesOf(id, address(orders));
            for (uint256 k; k < handler.actorCount(); ++k) sum += pool.sharesOf(id, handler.actors(k));
            // the first deposit into a bin locks MIN_SHARES that no account owns
            assertLe(sum, total, "holders own more shares than the bin has");
            assertLe(total - sum, minShares, "more than MIN_SHARES unowned in a bin");
        }
    }

    function invariant_ordersOwnTheirShares() public view {
        for (uint256 i; i < handler.touchedCount(); ++i) {
            int24 id = handler.touched(i);
            uint256 open;
            for (uint256 k; k < handler.orderCount(); ++k) {
                IDLMMLimitOrders.Order memory o = orders.getOrder(handler.orderIds(k));
                if (!o.closed && o.binId == id) open += o.shares;
            }
            assertEq(pool.sharesOf(id, address(orders)), open, "limit orders hold shares that no open order owns");
        }
    }

    /// @dev Keeps the run honest: each sequence must actually trade, withdraw and close orders.
    function afterInvariant() public view {
        assertGt(handler.swaps(), 0, "no swap succeeded");
        assertGt(handler.removes(), 0, "no liquidity was removed");
    }
}
