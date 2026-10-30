// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {AethraHub} from "../../src/core/AethraHub.sol";
import {IAethraHub, Venue} from "../../src/interfaces/IAethraHub.sol";
import {IAethraLaunchpad} from "../../src/interfaces/IAethraPools.sol";
import {IAethraPositions} from "../../src/interfaces/IAethraPeriphery.sol";
import {AethraLaunchpad} from "../../src/launchpad/AethraLaunchpad.sol";
import {LaunchToken} from "../../src/launchpad/LaunchToken.sol";
import {MockWETH, MockPoolManager, MockPositions} from "./mocks/LaunchpadMocks.sol";

contract AethraLaunchpadV2 is AethraLaunchpad {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract AethraLaunchpadTest is Test {
    AethraHub hub;
    AethraLaunchpad lp;
    MockWETH weth;
    MockPoolManager pm;
    MockPositions positions;

    address owner = address(0xA11CE);
    address buyback = address(0xB0B);
    address creator = address(0xC1);
    address trader = address(0x2222);
    address hook = address(0x4444);

    function setUp() public {
        hub = AethraHub(address(new ERC1967Proxy(address(new AethraHub()), abi.encodeCall(AethraHub.initialize, (owner)))));
        weth = new MockWETH();
        pm = new MockPoolManager();
        positions = new MockPositions(pm);
        lp = AethraLaunchpad(
            payable(
                address(
                    new ERC1967Proxy(
                        address(new AethraLaunchpad()),
                        abi.encodeCall(
                            AethraLaunchpad.initialize,
                            (
                                owner,
                                IAethraHub(address(hub)),
                                address(weth),
                                address(new LaunchToken()),
                                address(pm),
                                address(positions),
                                hook
                            )
                        )
                    )
                )
            )
        );
        vm.startPrank(owner);
        hub.setRegistrar(address(lp), true);
        hub.setFeeConfig(buyback, address(0x7EA5), 2000);
        vm.stopPrank();
        _wethFor(trader, 100e18);
        _wethFor(creator, 100e18);
    }

    function _wethFor(address who, uint256 amt) internal {
        vm.deal(who, amt);
        vm.startPrank(who);
        weth.deposit{value: amt}();
        weth.approve(address(lp), type(uint256).max);
        vm.stopPrank();
    }

    function _create() internal returns (address token) {
        vm.prank(creator);
        token = lp.create("Moon", "MOON", "ipfs://meta", 0);
    }

    function _buy(address token, address who, uint256 wethIn) internal returns (uint256) {
        vm.prank(who);
        return lp.swapExactInput(token, address(weth), wethIn, 0, who, block.timestamp);
    }

    function _sell(address token, address who, uint256 amt) internal returns (uint256) {
        vm.startPrank(who);
        IERC20(token).approve(address(lp), amt);
        uint256 out = lp.swapExactInput(token, token, amt, 0, who, block.timestamp);
        vm.stopPrank();
        return out;
    }

    // ------------------------------------------------------------------ create

    function test_createRegistersLaunch() public {
        address token = _create();
        IAethraLaunchpad.Launch memory l = lp.launch(token);
        assertEq(l.token, token);
        assertEq(l.creator, creator);
        assertEq(l.realToken, 800_000_000e18);
        assertEq(l.virtualToken, 273_000_000e18);
        assertEq(l.virtualWeth, 1.5e18);
        assertEq(IERC20(token).balanceOf(address(lp)), 1_000_000_000e18);
        assertEq(LaunchToken(token).symbol(), "MOON");
        assertEq(lp.launchCount(), 1);
        IAethraHub.PoolInfo memory info = hub.pool(bytes32(uint256(uint160(token))));
        assertEq(uint8(info.venue), uint8(Venue.LAUNCH));
        assertEq(info.pool, address(lp));
        assertEq(info.creator, creator);
        // clones cannot be re-initialized
        vm.expectRevert(LaunchToken.AlreadyInitialized.selector);
        LaunchToken(token).initialize("x", "x", address(this));
    }

    function test_createWithEthBuyRefundsNothingBelowThreshold() public {
        vm.deal(creator, 1e18);
        vm.prank(creator);
        address token = lp.create{value: 1e18}("Moon", "MOON", "", 0);
        assertGt(IERC20(token).balanceOf(creator), 0);
        assertEq(creator.balance, 0);
        assertEq(weth.balanceOf(buyback), 0.01e18); // 1% trade fee
        assertEq(lp.launch(token).realWeth, 0.99e18);
    }

    function test_createWithEthOverThresholdGraduatesAndRefunds() public {
        vm.deal(creator, 20e18);
        vm.prank(creator);
        address token = lp.create{value: 20e18}("Moon", "MOON", "", 0);
        assertTrue(lp.launch(token).graduated);
        assertGt(creator.balance, 15e18); // unused ETH refunded
        assertEq(IERC20(token).balanceOf(creator), 800_000_000e18);
    }

    function test_createBadValue() public {
        vm.deal(creator, 1e18);
        vm.prank(creator);
        vm.expectRevert(AethraLaunchpad.BadValue.selector);
        lp.create{value: 1e18}("Moon", "MOON", "", 2e18);
    }

    // ------------------------------------------------------------------ trading

    function test_buyAndSellMatchQuotes() public {
        address token = _create();
        uint256 q = lp.quoteExactInput(token, address(weth), 1e18);
        uint256 p0 = lp.spotPrice(token);
        uint256 got = _buy(token, trader, 1e18);
        assertEq(got, q);
        assertGt(lp.spotPrice(token), p0);

        uint256 qs = lp.quoteExactInput(token, token, got);
        uint256 back = _sell(token, trader, got);
        assertEq(back, qs);
        assertLt(back, 1e18); // fees on both legs
        assertGt(back, 0.97e18);
    }

    function test_tradeRejects() public {
        address token = _create();
        vm.startPrank(trader);
        vm.expectRevert(IAethraLaunchpad.Expired.selector);
        lp.swapExactInput(token, address(weth), 1e18, 0, trader, block.timestamp - 1);
        vm.expectRevert(AethraLaunchpad.ZeroAmount.selector);
        lp.swapExactInput(token, address(weth), 0, 0, trader, block.timestamp);
        vm.expectRevert(IAethraLaunchpad.UnknownLaunch.selector);
        lp.swapExactInput(address(0xdead), address(weth), 1e18, 0, trader, block.timestamp);
        vm.expectRevert(AethraLaunchpad.InvalidToken.selector);
        lp.swapExactInput(token, address(0xdead), 1e18, 0, trader, block.timestamp);
        vm.expectRevert(IAethraLaunchpad.Slippage.selector);
        lp.swapExactInput(token, address(weth), 1e18, type(uint256).max, trader, block.timestamp);
        vm.stopPrank();
        vm.expectRevert(AethraLaunchpad.NotReady.selector);
        lp.graduate(token);
    }

    // ------------------------------------------------------------------ graduation

    function test_buyOutClampsAndGraduates() public {
        address token = _create();
        uint256 threshold = lp.graduationThreshold();
        assertApproxEqRel(threshold, 4.3956e18, 1e15);
        (uint256 used,,) = lp.quoteBuy(token, 50e18);
        assertLt(used, 50e18);

        uint256 balBefore = weth.balanceOf(trader);
        uint256 got = _buy(token, trader, 50e18);
        assertEq(got, 800_000_000e18);
        assertEq(balBefore - weth.balanceOf(trader), used);

        IAethraLaunchpad.Launch memory l = lp.launch(token);
        assertTrue(l.graduated);
        assertEq(l.positionId, 1);
        assertGe(l.realWeth, threshold);

        // pool initialized at the final curve price with the Aethra hook and a permanent lock
        (PoolKey memory key, uint160 sqrtP) = pm.lastInit();
        assertEq(address(key.hooks), hook);
        assertEq(key.tickSpacing, 60);
        assertGt(sqrtP, TickMath.MIN_SQRT_PRICE);
        IAethraPositions.Lock memory lock = positions.getLock(1);
        assertEq(lock.end, type(uint64).max);
        assertEq(positions.ownerOf(1), address(lp));
        // the reserved tokens go into the pool at the final curve price; the WETH they don't pair with goes to buyback
        (uint256 wethLiq, uint256 tokenLiq) =
            address(weth) < token ? (positions.lastAmount0(), positions.lastAmount1()) : (positions.lastAmount1(), positions.lastAmount0());
        assertApproxEqRel(tokenLiq, 200_000_000e18, 1e12);
        assertApproxEqRel(wethLiq, 200_000_000e18 * lp.spotPrice(token) / 1e18, 1e12);
        assertLe(wethLiq, l.realWeth);
        assertEq(IERC20(token).balanceOf(address(lp)), 0);
        assertEq(weth.balanceOf(address(lp)), 0);

        vm.expectRevert(IAethraLaunchpad.AlreadyGraduated.selector);
        _buy(token, trader, 1e18);
        assertEq(lp.quoteExactInput(token, address(weth), 1e18), 0);
    }

    function test_graduationUsesExistingPoolPrice() public {
        address token = _create();
        PoolKey memory key = lp.poolKeyFor(token);
        uint160 squatted = TickMath.getSqrtPriceAtTick(0);
        pm.initialize(key, squatted);
        _buy(token, trader, 50e18);
        assertTrue(lp.launch(token).graduated);
        assertEq(pm.initCount(), 1);
    }

    function test_collectGraduatedFeesSplit() public {
        address token = _create();
        vm.expectRevert(AethraLaunchpad.NotGraduated.selector);
        lp.collectGraduatedFees(token);
        _buy(token, trader, 50e18);
        // seed fees on the locked position and fund the mock with them
        (uint256 fw, uint256 ft) = (1e18, 1000e18);
        _wethFor(address(positions), fw);
        vm.prank(trader);
        IERC20(token).transfer(address(positions), ft);
        bool wethIs0 = address(weth) < token;
        positions.seedFees(1, wethIs0 ? fw : ft, wethIs0 ? ft : fw);

        uint256 bbBefore = weth.balanceOf(buyback);
        uint256 bbTokenBefore = IERC20(token).balanceOf(buyback);
        (uint256 wc, uint256 tc, uint256 wp, uint256 tp) = lp.collectGraduatedFees(token);
        assertEq(wc, fw / 2); // creatorFeeBps 5000
        assertEq(tc, ft / 2);
        assertEq(wp, fw - fw / 2);
        assertEq(tp, ft - ft / 2);
        assertEq(weth.balanceOf(creator), 100e18 + wc);
        assertEq(weth.balanceOf(buyback) - bbBefore, wp);
        assertEq(IERC20(token).balanceOf(buyback) - bbTokenBefore, tp);
    }

    // ------------------------------------------------------------------ admin

    function test_adminConfig() public {
        vm.expectRevert();
        lp.setFeeConfig(0, 0, 0);
        vm.startPrank(owner);
        vm.expectRevert(AethraLaunchpad.InvalidConfig.selector);
        lp.setFeeConfig(50_001, 0, 0);
        vm.expectRevert(AethraLaunchpad.InvalidConfig.selector);
        lp.setCurveConfig(1e18, 100e18, 100e18);
        vm.expectRevert(AethraLaunchpad.InvalidConfig.selector);
        lp.setCurveConfig(1e18, 2_000_000_000e18, 1_000_000_000e18);
        lp.setCurveConfig(1e18, 1_100_000_000e18, 900_000_000e18);
        assertEq(lp.config().curveSupply, 900_000_000e18);
        vm.stopPrank();
    }

    function test_graduationTargetsLockAfterFirstGraduation() public {
        vm.prank(owner);
        lp.setGraduationTargets(address(pm), address(positions), address(0x5555));
        address token = _create();
        _buy(token, trader, 50e18);
        vm.startPrank(owner);
        vm.expectRevert(AethraLaunchpad.PositionsLocked.selector);
        lp.setGraduationTargets(address(pm), address(0x1), hook);
        lp.setGraduationTargets(address(pm), address(positions), hook); // hook alone may change
        vm.stopPrank();
    }

    function test_upgradeKeepsLaunches() public {
        address token = _create();
        address impl = address(new AethraLaunchpadV2());
        vm.expectRevert();
        lp.upgradeToAndCall(impl, "");
        vm.prank(owner);
        lp.upgradeToAndCall(impl, "");
        assertEq(AethraLaunchpadV2(payable(address(lp))).version(), 2);
        assertEq(lp.launch(token).creator, creator);
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_roundTripNeverProfits(uint96 wethIn) public {
        address token = _create();
        uint256 amt = bound(uint256(wethIn), 1e9, 4e18);
        uint256 got = _buy(token, trader, amt);
        uint256 back = _sell(token, trader, got);
        assertLt(back, amt);
    }

    function testFuzz_curveInvariantHolds(uint96 a, uint96 b, uint96 c) public {
        address token = _create();
        IAethraLaunchpad.Launch memory l = lp.launch(token);
        uint256 k0 = (uint256(l.virtualWeth) + l.realWeth) * (uint256(l.virtualToken) + l.realToken);
        _buy(token, trader, bound(uint256(a), 1e9, 2e18));
        uint256 got = _buy(token, trader, bound(uint256(b), 1e9, 2e18));
        _sell(token, trader, bound(uint256(c), 1e15, got));
        l = lp.launch(token);
        uint256 k1 = (uint256(l.virtualWeth) + l.realWeth) * (uint256(l.virtualToken) + l.realToken);
        assertGe(k1, k0);
        // the contract always holds the WETH it owes sellers
        assertGe(weth.balanceOf(address(lp)), l.realWeth);
    }
}
