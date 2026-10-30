// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {AethraHub} from "../../src/core/AethraHub.sol";
import {IAethraHub} from "../../src/interfaces/IAethraHub.sol";
import {IDAMMFactory, IAethraPool} from "../../src/interfaces/IAethraPools.sol";
import {DAMMPool} from "../../src/damm/DAMMPool.sol";
import {DAMMFactory} from "../../src/damm/DAMMFactory.sol";
import {VolatilityFee} from "../../src/libraries/VolatilityFee.sol";
import {MockERC20} from "./MockERC20.sol";

contract DAMMPoolV2 is DAMMPool {
    constructor(IAethraHub h) DAMMPool(h) {}

    function version() external pure returns (uint256) {
        return 2;
    }
}

contract DAMMFactoryV2 is DAMMFactory {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract DAMMTest is Test {
    AethraHub hub;
    UpgradeableBeacon beacon;
    DAMMFactory factory;
    MockERC20 token0;
    MockERC20 token1;
    DAMMPool pool;

    address owner = address(0xA11CE);
    address buyback = address(0xB0B);
    address lp = address(0x1111);
    address trader = address(0x2222);

    uint160 constant SQRT_1 = 79228162514264337593543950336; // price 1
    uint24 constant BASE_FEE = 3000;
    uint24 constant MAX_FEE = 50_000;

    function setUp() public {
        hub = AethraHub(address(new ERC1967Proxy(address(new AethraHub()), abi.encodeCall(AethraHub.initialize, (owner)))));
        beacon = new UpgradeableBeacon(address(new DAMMPool(IAethraHub(address(hub)))), owner);
        factory = DAMMFactory(
            address(
                new ERC1967Proxy(
                    address(new DAMMFactory()),
                    abi.encodeCall(DAMMFactory.initialize, (owner, IAethraHub(address(hub)), address(beacon)))
                )
            )
        );
        vm.startPrank(owner);
        hub.setRegistrar(address(factory), true);
        hub.setFeeConfig(buyback, address(0x7EA5), 2000);
        vm.stopPrank();

        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        pool = _create(SQRT_1, 0, 0, 0, 0);
        _fund(lp);
        _fund(trader);
    }

    function _create(uint160 sqrtP, uint160 lower, uint160 upper, uint24 launchStart, uint32 launchDur)
        internal
        returns (DAMMPool)
    {
        return DAMMPool(
            factory.createPool(
                IDAMMFactory.CreateParams(
                    address(token0), address(token1), sqrtP, lower, upper, BASE_FEE, MAX_FEE, launchStart, launchDur
                )
            )
        );
    }

    function _fund(address who) internal {
        token0.mint(who, 1e30);
        token1.mint(who, 1e30);
    }

    function _approve(address who, DAMMPool p) internal {
        vm.startPrank(who);
        token0.approve(address(p), type(uint256).max);
        token1.approve(address(p), type(uint256).max);
        vm.stopPrank();
    }

    function _add(DAMMPool p, address who, uint256 a0, uint256 a1) internal returns (uint256 shares) {
        _approve(who, p);
        vm.prank(who);
        (shares,,) = p.addLiquidity(a0, a1, 0, who, block.timestamp);
    }

    function _swap(DAMMPool p, address who, bool zeroForOne, uint256 amt) internal returns (uint256) {
        _approve(who, p);
        vm.prank(who);
        return p.swapExactInput(zeroForOne ? address(token0) : address(token1), amt, 0, who, block.timestamp);
    }

    // ------------------------------------------------------------------ factory

    function test_createRegisters() public view {
        assertEq(factory.poolCount(), 1);
        assertTrue(factory.isPool(address(pool)));
        assertEq(factory.poolsForPair(address(token1), address(token0))[0], address(pool));
        assertEq(pool.factory(), address(factory));
        assertEq(pool.token0(), address(token0));
        assertEq(pool.sqrtPriceLowerX96(), TickMath.MIN_SQRT_PRICE);
        assertEq(pool.sqrtPriceUpperX96(), factory.FULL_RANGE_UPPER());
        IAethraHub.PoolInfo memory info = hub.pool(bytes32(uint256(uint160(address(pool)))));
        assertEq(info.pool, address(pool));
        assertEq(info.creator, address(this));
    }

    function test_createRejects() public {
        vm.expectRevert(DAMMFactory.InvalidTokens.selector);
        factory.createPool(IDAMMFactory.CreateParams(address(token0), address(token0), SQRT_1, 0, 0, BASE_FEE, MAX_FEE, 0, 0));
        vm.expectRevert(DAMMFactory.InvalidRange.selector);
        factory.createPool(
            IDAMMFactory.CreateParams(address(token0), address(token1), SQRT_1 * 2, 0, SQRT_1, BASE_FEE, MAX_FEE, 0, 0)
        );
        vm.expectRevert(DAMMFactory.InvalidFee.selector);
        factory.createPool(IDAMMFactory.CreateParams(address(token0), address(token1), SQRT_1, 0, 0, BASE_FEE, MAX_FEE, 100_000, 0));
        vm.expectRevert(VolatilityFee.InvalidParams.selector);
        factory.createPool(IDAMMFactory.CreateParams(address(token0), address(token1), SQRT_1, 0, 0, MAX_FEE + 1, MAX_FEE, 0, 0));
    }

    function test_cannotInitializeTwice() public {
        VolatilityFee.Params memory p;
        vm.expectRevert();
        pool.initialize(address(token0), address(token1), SQRT_1, 1, 2, p, 0, 0);
    }

    // ------------------------------------------------------------------ liquidity

    function test_firstDepositLocksMinimum() public {
        uint256 shares = _add(pool, lp, 100e18, 100e18);
        assertEq(shares, pool.liquidity() - pool.MIN_LIQUIDITY());
        (uint256 r0, uint256 r1) = pool.reserves();
        assertApproxEqAbs(r0, 100e18, 1);
        assertApproxEqAbs(r1, 100e18, 1);
        assertEq(pool.sharesOf(lp), shares);
    }

    function test_removeReturnsProportionalReserves() public {
        uint256 shares = _add(pool, lp, 100e18, 100e18);
        vm.prank(lp);
        (uint256 a0, uint256 a1) = pool.removeLiquidity(shares / 2, 0, 0, lp, block.timestamp);
        assertApproxEqRel(a0, 50e18, 1e12);
        assertApproxEqRel(a1, 50e18, 1e12);
        assertEq(pool.sharesOf(lp), shares - shares / 2);
        vm.prank(lp);
        vm.expectRevert(DAMMPool.InsufficientShares.selector);
        pool.removeLiquidity(shares, 0, 0, lp, block.timestamp);
    }

    // ------------------------------------------------------------------ swaps & fees

    function test_swapPaysFeesToLpAndProtocol() public {
        _add(pool, lp, 1000e18, 1000e18);
        (uint256 q,) = pool.quoteExactInput(address(token0), 10e18);
        uint256 out = _swap(pool, trader, true, 10e18);
        assertEq(out, q);
        // 0.3% fee + price impact on a 1000/1000 pool
        assertLt(out, 10e18 * 997 / 1000);
        assertGt(out, 9.8e18);

        (uint256 pf0,) = pool.protocolFees();
        assertApproxEqRel(pf0, 10e18 * 3000 / 1e6 * 2000 / 10_000, 1e15);
        (uint256 f0, uint256 f1) = pool.claimableFees(lp);
        assertApproxEqRel(f0, 10e18 * 3000 / 1e6 * 8000 / 10_000, 1e15);
        assertEq(f1, 0);

        vm.prank(lp);
        (uint256 c0,) = pool.claimFees(lp);
        assertEq(c0, f0);
        (f0,) = pool.claimableFees(lp);
        assertEq(f0, 0);

        pool.collectProtocolFees();
        assertEq(token0.balanceOf(buyback), pf0);
    }

    function test_swapRejects() public {
        _add(pool, lp, 10e18, 10e18);
        _approve(trader, pool);
        vm.startPrank(trader);
        vm.expectRevert(IAethraPool.InvalidToken.selector);
        pool.swapExactInput(address(0xdead), 1e18, 0, trader, block.timestamp);
        vm.expectRevert(IAethraPool.ZeroAmount.selector);
        pool.swapExactInput(address(token0), 0, 0, trader, block.timestamp);
        vm.expectRevert(IAethraPool.Expired.selector);
        pool.swapExactInput(address(token0), 1e18, 0, trader, block.timestamp - 1);
        vm.expectRevert(IAethraPool.Slippage.selector);
        pool.swapExactInput(address(token0), 1e18, 1e18, trader, block.timestamp);
        vm.stopPrank();
    }

    function test_boundedRangeRunsOut() public {
        // range [0.25, 4]: selling far more than the range holds hits the edge
        DAMMPool p = _create(SQRT_1, SQRT_1 / 2, SQRT_1 * 2, 0, 0);
        _add(p, lp, 10e18, 10e18);
        _approve(trader, p);
        vm.prank(trader);
        vm.expectRevert(DAMMPool.InsufficientLiquidity.selector);
        p.swapExactInput(address(token0), 1000e18, 0, trader, block.timestamp);
    }

    function test_oneSidedLaunch() public {
        // price at the lower edge: only token0 can be deposited; buyers push the price up
        DAMMPool p = _create(SQRT_1, SQRT_1, SQRT_1 * 4, 0, 0);
        _approve(lp, p);
        vm.prank(lp);
        (, uint256 a0, uint256 a1) = p.addLiquidity(1000e18, 1000e18, 0, lp, block.timestamp);
        assertGt(a0, 0);
        assertEq(a1, 0);
        uint256 out = _swap(p, trader, false, 10e18);
        assertGt(out, 0);
        assertGt(p.sqrtPriceX96(), SQRT_1);
    }

    function test_launchFeeDecays() public {
        uint24 start = uint24(VolatilityFee.MAX_FEE_PIPS);
        uint256 t0 = block.timestamp;
        DAMMPool p = _create(SQRT_1, 0, 0, start, 1 hours);
        assertEq(p.currentFee(), start);
        vm.warp(t0 + 30 minutes);
        assertEq(p.currentFee(), start - (start - BASE_FEE) / 2);
        vm.warp(t0 + 1 hours);
        assertEq(p.currentFee(), BASE_FEE);
    }

    function test_volatilityRaisesFee() public {
        _add(pool, lp, 1000e18, 1000e18);
        uint24 before = pool.currentFee();
        _swap(pool, trader, true, 300e18);
        assertGt(pool.currentFee(), before);
        assertLe(pool.currentFee(), MAX_FEE);
    }

    // ------------------------------------------------------------------ upgrades

    function test_beaconUpgradeKeepsState() public {
        _add(pool, lp, 100e18, 100e18);
        _swap(pool, trader, true, 1e18);
        uint160 sqrtP = pool.sqrtPriceX96();
        address impl = address(new DAMMPoolV2(IAethraHub(address(hub))));
        vm.expectRevert();
        beacon.upgradeTo(impl);
        vm.prank(owner);
        beacon.upgradeTo(impl);
        assertEq(DAMMPoolV2(address(pool)).version(), 2);
        assertEq(pool.sqrtPriceX96(), sqrtP);
        _swap(pool, trader, false, 1e18);
    }

    function test_factoryUpgradeOnlyOwner() public {
        address impl = address(new DAMMFactoryV2());
        vm.expectRevert();
        factory.upgradeToAndCall(impl, "");
        vm.prank(owner);
        factory.upgradeToAndCall(impl, "");
        assertEq(DAMMFactoryV2(address(factory)).version(), 2);
        assertEq(factory.poolCount(), 1);
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_roundTripNeverProfits(uint96 amt, bool zeroForOne) public {
        _add(pool, lp, 1000e18, 1000e18);
        uint256 amountIn = bound(uint256(amt), 1e6, 500e18);
        uint256 out = _swap(pool, trader, zeroForOne, amountIn);
        uint256 back = _swap(pool, trader, !zeroForOne, out);
        assertLe(back, amountIn);
    }

    function testFuzz_addRemoveNeverProfits(uint96 x, uint96 y) public {
        _fund(address(this));
        _add(pool, address(this), 1000e18, 1000e18);
        uint256 a = bound(uint256(x), 1e9, 1e24);
        uint256 b = bound(uint256(y), 1e9, 1e24);
        uint256 bal0 = token0.balanceOf(lp);
        uint256 bal1 = token1.balanceOf(lp);
        uint256 shares = _add(pool, lp, a, b);
        vm.prank(lp);
        pool.removeLiquidity(shares, 0, 0, lp, block.timestamp);
        assertLe(token0.balanceOf(lp), bal0);
        assertLe(token1.balanceOf(lp), bal1);
    }
}
