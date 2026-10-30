// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAethraHub, Venue} from "../../src/interfaces/IAethraHub.sol";
import {IAethraRouter} from "../../src/interfaces/IAethraPeriphery.sol";
import {
    IDLMMFactory, IDLMMPool, IDLMMLimitOrders, IDAMMFactory, IDAMMPool
} from "../../src/interfaces/IAethraPools.sol";

/// @notice v1.1 opening rehearsal against the live mainnet deployment: the deployer opens DLMM, DAMM and limit orders
///         exactly as `scripts/mainnet-v11.sh open` does, an LP creates and fills a WETH/USDG pool on each venue, and the
///         router quotes and swaps through them at the pools' own prices. A limit order is placed, filled and claimed.
///         Opt-in because it needs the network:  FORK_MAINNET=1 forge test --match-path test/fork/MainnetV11.t.sol -vv
contract MainnetV11Test is Test {
    address constant DEPLOYER = 0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C;
    address constant LP = address(0x1111A);
    address constant USER = address(0xA11CE5);
    uint256 constant PRICE6 = 2242_580000; // $2,242.58 per ETH (CoinGecko, 2026-10-31)
    // token0 = WETH, token1 = USDG; raw price 2.24258e-9 USDG units per wei
    int24 constant DLMM_ACTIVE = -7976; // log(2.24258e-9) / log(1.0025), bin step 25
    uint160 constant DAMM_SQRT = 3751919883172275516604416; // sqrt(2.24258e-9) * 2^96

    IAethraHub hub;
    IAethraRouter router;
    IDLMMFactory dlmmFactory;
    IDLMMLimitOrders orders;
    IDAMMFactory dammFactory;
    address weth;
    address usdg;

    function setUp() public {
        if (!vm.envOr("FORK_MAINNET", false)) return;
        vm.createSelectFork("mainnet");
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/../sdk/src/addresses/mainnet.json"));
        hub = IAethraHub(vm.parseJsonAddress(json, ".hub"));
        router = IAethraRouter(vm.parseJsonAddress(json, ".router"));
        dlmmFactory = IDLMMFactory(vm.parseJsonAddress(json, ".dlmmFactory"));
        orders = IDLMMLimitOrders(vm.parseJsonAddress(json, ".dlmmLimitOrders"));
        dammFactory = IDAMMFactory(vm.parseJsonAddress(json, ".dammFactory"));
        weth = vm.parseJsonAddress(json, ".weth");
        usdg = vm.parseJsonAddress(json, ".tokens.USDG.address");
        require(weth < usdg, "token order changed");
    }

    function test_openThenRouteThroughDlmmAndDamm() public {
        vm.skip(!vm.envOr("FORK_MAINNET", false));

        // locked today: creating a pool reverts at hub.registerPool
        assertFalse(hub.isRegistrar(address(dlmmFactory)), "DLMM already open");
        assertFalse(hub.isRegistrar(address(dammFactory)), "DAMM already open");
        vm.expectRevert();
        dlmmFactory.createPool(IDLMMFactory.CreateParams(weth, usdg, 25, DLMM_ACTIVE, 3000, 50_000));

        // what `scripts/mainnet-v11.sh open` sends
        vm.startPrank(DEPLOYER);
        hub.setRegistrar(address(dlmmFactory), true);
        hub.setRegistrar(address(dammFactory), true);
        vm.stopPrank();

        IDLMMPool dlmm = _seedDlmm();
        IDAMMPool damm = _seedDamm();
        assertEq(uint8(hub.pool(bytes32(uint256(uint160(address(dlmm))))).venue), uint8(Venue.DLMM), "DLMM not in hub");
        assertEq(uint8(hub.pool(bytes32(uint256(uint160(address(damm))))).venue), uint8(Venue.DAMM), "DAMM not in hub");

        uint256 ethIn = 0.0002 ether;
        uint256 fair = ethIn * PRICE6 / 1e18;
        vm.deal(USER, 1 ether);

        // single hop on each venue: the router quotes what the pool quotes, and pays it
        IAethraRouter.Hop[] memory viaDlmm = _hop(Venue.DLMM, address(dlmm), weth, usdg);
        IAethraRouter.Hop[] memory viaDamm = _hop(Venue.DAMM, address(damm), weth, usdg);
        (uint256 poolDlmm,) = dlmm.quoteExactInput(weth, ethIn);
        (uint256 poolDamm,) = damm.quoteExactInput(weth, ethIn);
        (uint256 qDlmm,) = router.quote(viaDlmm, ethIn);
        (uint256 qDamm,) = router.quote(viaDamm, ethIn);
        assertEq(qDlmm, poolDlmm, "router quote differs from the DLMM pool");
        assertEq(qDamm, poolDamm, "router quote differs from the DAMM pool");
        for (uint256 i; i < 2; ++i) {
            uint256 q = i == 0 ? qDlmm : qDamm;
            // 0.3% fee plus impact: 0.0002 ETH is 4% of the DAMM pool and drains the active DLMM bin
            assertGt(q, fair * 95 / 100, "quote too far below the market price");
            assertLt(q, fair * 101 / 100, "quote above the market price");
        }

        vm.prank(USER);
        uint256 got = router.swap{value: ethIn}(viaDlmm, ethIn, qDlmm * 99 / 100, USER, block.timestamp, false);
        assertEq(got, qDlmm, "DLMM swap paid a different amount than quoted");
        vm.prank(USER);
        got = router.swap{value: ethIn}(viaDamm, ethIn, qDamm * 99 / 100, USER, block.timestamp, false);
        assertEq(got, qDamm, "DAMM swap paid a different amount than quoted");

        // two hops across venues: USDG -> WETH on DAMM, WETH -> USDG on DLMM
        uint256 usdgIn = IERC20(usdg).balanceOf(USER);
        IAethraRouter.Hop[] memory both = new IAethraRouter.Hop[](2);
        both[0] = _hop(Venue.DAMM, address(damm), usdg, weth)[0];
        both[1] = _hop(Venue.DLMM, address(dlmm), weth, usdg)[0];
        (uint256 q2, uint256[] memory hops) = router.quote(both, usdgIn);
        assertEq(hops.length, 2);
        (uint256 mid,) = damm.quoteExactInput(usdg, usdgIn);
        assertEq(hops[0], mid, "first hop differs from the DAMM pool");
        vm.startPrank(USER);
        IERC20(usdg).approve(address(router), usdgIn);
        got = router.swap(both, usdgIn, q2, USER, block.timestamp, false);
        vm.stopPrank();
        assertEq(got, q2, "two-hop swap paid a different amount than quoted");
        assertGt(got, usdgIn * 95 / 100, "round trip lost more than fees and impact");

        _limitOrderFills(dlmm);
    }

    function _limitOrderFills(IDLMMPool dlmm) internal {
        int24 bin = dlmm.activeId() + 2;
        uint256 amount = 0.0005 ether;
        deal(weth, USER, amount);
        vm.startPrank(USER);
        IERC20(weth).approve(address(orders), amount);
        uint256 id = orders.place(address(dlmm), bin, IDLMMLimitOrders.Side.SELL_TOKEN0, amount, block.timestamp);
        vm.stopPrank();
        assertEq(uint8(orders.status(id)), uint8(IDLMMLimitOrders.Status.OPEN));

        // buyers push the price up through the order's bin
        address buyer = address(0xB0B5);
        deal(usdg, buyer, 1_000e6);
        vm.startPrank(buyer);
        IERC20(usdg).approve(address(router), type(uint256).max);
        while (dlmm.activeId() <= bin) {
            router.swap(_hop(Venue.DLMM, address(dlmm), usdg, weth), 2e6, 0, buyer, block.timestamp, false);
        }
        vm.stopPrank();
        assertEq(uint8(orders.status(id)), uint8(IDLMMLimitOrders.Status.FILLED));

        uint256 before = IERC20(usdg).balanceOf(USER);
        vm.prank(USER);
        (uint256 a0, uint256 a1) = orders.claim(id, USER);
        assertEq(a0, 0);
        // sold above the starting price, so at least the market value of the deposit
        assertGe(a1, amount * PRICE6 / 1e18, "limit order filled below its price");
        assertEq(IERC20(usdg).balanceOf(USER), before + a1);
    }

    /// @dev 0.002 WETH and its USDG value, spread over 5 bins each side of the active bin.
    function _seedDlmm() internal returns (IDLMMPool pool) {
        pool = IDLMMPool(dlmmFactory.createPool(IDLMMFactory.CreateParams(weth, usdg, 25, DLMM_ACTIVE, 3000, 50_000)));
        uint256 perBin0 = 0.0002 ether;
        uint256 perBin1 = perBin0 * PRICE6 / 1e18;
        int24[] memory ids = new int24[](11);
        uint256[] memory a0 = new uint256[](11);
        uint256[] memory a1 = new uint256[](11);
        for (uint256 i; i < 11; ++i) {
            int24 id = DLMM_ACTIVE - 5 + int24(int256(i));
            ids[i] = id;
            if (id >= DLMM_ACTIVE) a0[i] = perBin0;
            if (id <= DLMM_ACTIVE) a1[i] = perBin1;
        }
        _fundLp(address(pool), 0.01 ether, 25e6);
        vm.prank(LP);
        pool.addLiquidity(ids, a0, a1, LP, block.timestamp);
    }

    function _seedDamm() internal returns (IDAMMPool pool) {
        pool = IDAMMPool(
            dammFactory.createPool(IDAMMFactory.CreateParams(weth, usdg, DAMM_SQRT, 0, 0, 3000, 50_000, 0, 0))
        );
        uint256 eth = 0.005 ether;
        _fundLp(address(pool), eth, eth * PRICE6 / 1e18);
        vm.prank(LP);
        pool.addLiquidity(eth, eth * PRICE6 / 1e18, 0, LP, block.timestamp);
        (uint256 r0, uint256 r1) = pool.reserves();
        assertGt(r0, 0);
        assertGt(r1, 0);
    }

    function _fundLp(address pool, uint256 wethAmt, uint256 usdgAmt) internal {
        deal(weth, LP, wethAmt);
        deal(usdg, LP, usdgAmt);
        vm.startPrank(LP);
        IERC20(weth).approve(pool, type(uint256).max);
        IERC20(usdg).approve(pool, type(uint256).max);
        vm.stopPrank();
    }

    function _hop(Venue venue, address pool, address tokenIn, address tokenOut)
        internal
        pure
        returns (IAethraRouter.Hop[] memory h)
    {
        h = new IAethraRouter.Hop[](1);
        h[0] = IAethraRouter.Hop(venue, pool, tokenIn, tokenOut, "");
    }
}
