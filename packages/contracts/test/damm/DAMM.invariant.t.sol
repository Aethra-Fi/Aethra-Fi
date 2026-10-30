// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {AethraHub} from "../../src/core/AethraHub.sol";
import {IAethraHub} from "../../src/interfaces/IAethraHub.sol";
import {IDAMMFactory} from "../../src/interfaces/IAethraPools.sol";
import {DAMMPool} from "../../src/damm/DAMMPool.sol";
import {DAMMFactory} from "../../src/damm/DAMMFactory.sol";
import {MockERC20} from "./MockERC20.sol";

/// @dev Random add / remove / swap / fee claim / protocol fee collection / time sequences on one DAMM pool.
contract DAMMHandler is Test {
    DAMMPool public pool;
    MockERC20 public token0;
    MockERC20 public token1;
    address[4] public actors = [address(0xD1), address(0xD2), address(0xD3), address(0xD4)];

    uint256 public swaps;
    uint256 public removes;
    uint256 public claims;

    constructor(DAMMPool p, MockERC20 t0, MockERC20 t1) {
        (pool, token0, token1) = (p, t0, t1);
        for (uint256 i; i < actors.length; ++i) {
            token0.mint(actors[i], 1e36);
            token1.mint(actors[i], 1e36);
            vm.startPrank(actors[i]);
            token0.approve(address(pool), type(uint256).max);
            token1.approve(address(pool), type(uint256).max);
            vm.stopPrank();
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function add(uint256 actorSeed, uint256 a0, uint256 a1) external {
        address a = actors[actorSeed % actors.length];
        a0 = bound(a0, 1e6, 1e27);
        a1 = bound(a1, 1e6, 1e27);
        vm.prank(a);
        try pool.addLiquidity(a0, a1, 0, a, block.timestamp) {} catch {}
    }

    function remove(uint256 actorSeed, uint256 fraction) external {
        address a = actors[actorSeed % actors.length];
        uint256 owned = pool.sharesOf(a);
        if (owned == 0) return;
        uint256 s = bound(fraction, 1, owned);
        vm.prank(a);
        pool.removeLiquidity(s, 0, 0, a, block.timestamp);
        removes++;
    }

    function swap(uint256 actorSeed, bool zeroForOne, uint256 amount) external {
        address a = actors[actorSeed % actors.length];
        amount = bound(amount, 1e3, 1e26);
        vm.prank(a);
        try pool.swapExactInput(zeroForOne ? address(token0) : address(token1), amount, 0, a, block.timestamp) {
            swaps++;
        } catch {}
    }

    function claim(uint256 actorSeed) external {
        address a = actors[actorSeed % actors.length];
        vm.prank(a);
        pool.claimFees(a);
        claims++;
    }

    function collect() external {
        pool.collectProtocolFees();
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 2 days));
    }
}

/// @notice DAMM pool invariants: the pool always holds enough tokens for every claim on it, shares add up, and the
///         price stays inside the pool's range with reserves that back the liquidity curve.
contract DAMMInvariantTest is Test {
    uint160 constant Q96 = 79228162514264337593543950336; // sqrt price 1
    uint128 constant MIN_LIQUIDITY = 1000;

    DAMMPool pool;
    MockERC20 token0;
    MockERC20 token1;
    DAMMHandler handler;

    function setUp() public {
        address owner = address(0xA11CE);
        AethraHub hub =
            AethraHub(address(new ERC1967Proxy(address(new AethraHub()), abi.encodeCall(AethraHub.initialize, (owner)))));
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(new DAMMPool(IAethraHub(address(hub)))), owner);
        DAMMFactory factory = DAMMFactory(
            address(
                new ERC1967Proxy(
                    address(new DAMMFactory()), abi.encodeCall(DAMMFactory.initialize, (owner, IAethraHub(address(hub)), address(beacon)))
                )
            )
        );
        vm.startPrank(owner);
        hub.setRegistrar(address(factory), true);
        hub.setFeeConfig(address(0xB0B), address(0x7EA5), 2000); // 20% protocol share, so protocol fees accrue
        vm.stopPrank();

        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        // concentrated range [0.25, 4] so swaps reach both edges
        pool = DAMMPool(
            factory.createPool(
                IDAMMFactory.CreateParams(address(token0), address(token1), Q96, Q96 / 2, Q96 * 2, 3000, 50_000, 30_000, 1 days)
            )
        );

        handler = new DAMMHandler(pool, token0, token1);
        // seed so the first random add is not the only liquidity
        handler.add(0, 1e24, 1e24);
        targetContract(address(handler));
    }

    function invariant_poolIsSolvent() public view {
        (uint256 r0, uint256 r1) = pool.reserves();
        (uint256 p0, uint256 p1) = pool.protocolFees();
        uint256 owed0;
        uint256 owed1;
        for (uint256 i; i < handler.actorCount(); ++i) {
            (uint256 f0, uint256 f1) = pool.claimableFees(handler.actors(i));
            owed0 += f0;
            owed1 += f1;
        }
        assertGe(token0.balanceOf(address(pool)), r0 + p0 + owed0, "token0: balance below reserves + fees owed");
        assertGe(token1.balanceOf(address(pool)), r1 + p1 + owed1, "token1: balance below reserves + fees owed");
    }

    function invariant_sharesAddUp() public view {
        uint256 sum;
        for (uint256 i; i < handler.actorCount(); ++i) sum += pool.sharesOf(handler.actors(i));
        uint128 total = pool.liquidity();
        // the first deposit locks MIN_LIQUIDITY that no account owns
        assertEq(sum + (total == 0 ? 0 : MIN_LIQUIDITY), total, "shares do not add up to liquidity");
    }

    function invariant_priceInRange() public view {
        uint160 p = pool.sqrtPriceX96();
        assertGe(p, pool.sqrtPriceLowerX96(), "price below range");
        assertLe(p, pool.sqrtPriceUpperX96(), "price above range");
    }

    function invariant_reservesBackTheCurve() public view {
        uint160 p = pool.sqrtPriceX96();
        uint128 l = pool.liquidity();
        (uint256 r0, uint256 r1) = pool.reserves();
        // tokens needed to move the price to each edge with the current liquidity (rounded down = owed to traders)
        uint256 need0 = SqrtPriceMath.getAmount0Delta(p, pool.sqrtPriceUpperX96(), l, false);
        uint256 need1 = SqrtPriceMath.getAmount1Delta(pool.sqrtPriceLowerX96(), p, l, false);
        assertGe(r0, need0, "reserve0 cannot pay out the curve");
        assertGe(r1, need1, "reserve1 cannot pay out the curve");
    }

    /// @dev Keeps the run honest: each sequence must actually trade and withdraw, not only revert inside try/catch.
    function afterInvariant() public view {
        assertGt(handler.swaps(), 0, "no swap succeeded");
        assertGt(handler.removes(), 0, "no liquidity was removed");
    }
}
