// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {IAethraHub, Venue} from "../../src/interfaces/IAethraHub.sol";
import {IAethraRouter} from "../../src/interfaces/IAethraPeriphery.sol";
import {SeedV1} from "../../script/mainnet/SeedV1.s.sol";

/// @notice v1.0 launch rehearsal against the live mainnet deployment: seed WETH/USDG with script/mainnet/SeedV1.s.sol,
///         then a fresh wallet swaps ETH -> USDG -> WETH through the router.
///         Opt-in because it needs the network:  FORK_MAINNET=1 forge test --match-path test/fork/MainnetLaunch.t.sol -vv
contract MainnetLaunchTest is Test {
    address constant DEPLOYER = 0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C;
    address constant USER = address(0xA11CE5);
    uint256 constant PRICE6 = 2242_580000; // $2,242.58, the CoinGecko price on 2026-10-31

    IAethraHub hub;
    IAethraRouter router;
    address weth;
    address usdg;
    address hook;

    function setUp() public {
        if (!vm.envOr("FORK_MAINNET", false)) return;
        vm.createSelectFork("mainnet");
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/../sdk/src/addresses/mainnet.json"));
        hub = IAethraHub(vm.parseJsonAddress(json, ".hub"));
        router = IAethraRouter(vm.parseJsonAddress(json, ".router"));
        weth = vm.parseJsonAddress(json, ".weth");
        usdg = vm.parseJsonAddress(json, ".tokens.USDG.address");
        hook = vm.parseJsonAddress(json, ".hook");
    }

    function test_seedThenSwapBothWays() public {
        vm.skip(!vm.envOr("FORK_MAINNET", false));

        // the deployer's launch budget: 0.005 ETH + the matching USDG
        uint256 seedEth = 0.005 ether;
        uint256 seedUsdg = seedEth * PRICE6 / 1e18;
        vm.deal(DEPLOYER, 0.01 ether);
        deal(usdg, DEPLOYER, seedUsdg);
        vm.setEnv("SEED_ETH", vm.toString(seedEth));
        vm.setEnv("SEED_USDG", vm.toString(seedUsdg));
        vm.setEnv("PRICE_USDG_PER_ETH", vm.toString(PRICE6));
        (bytes32 poolId, uint256 tokenId) = new SeedV1().run();
        assertGt(tokenId, 0, "no position minted");

        IAethraHub.PoolInfo memory info = hub.pool(poolId);
        assertEq(uint8(info.venue), uint8(Venue.V4), "pool not registered as v4");
        assertTrue(info.enabled, "pool not enabled");

        PoolKey memory key = PoolKey(Currency.wrap(weth), Currency.wrap(usdg), LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, IHooks(hook));
        IAethraRouter.Hop[] memory buy = new IAethraRouter.Hop[](1);
        buy[0] = IAethraRouter.Hop(Venue.V4, address(0), weth, usdg, abi.encode(key));

        // 0.0002 ETH in (4% of the pool): about $0.45 out after fee and price impact
        uint256 ethIn = 0.0002 ether;
        (uint256 quoted,) = router.quote(buy, ethIn);
        uint256 fair = ethIn * PRICE6 / 1e18;
        assertGt(quoted, fair * 90 / 100, "quote too far below the market price");
        assertLt(quoted, fair, "quote above the market price");

        vm.deal(USER, 1 ether);
        vm.prank(USER);
        uint256 got = router.swap{value: ethIn}(buy, ethIn, quoted * 99 / 100, USER, block.timestamp, false);
        assertEq(got, quoted, "swap paid a different amount than quoted");
        assertEq(IERC20(usdg).balanceOf(USER), got, "user did not receive USDG");

        // and back to WETH
        IAethraRouter.Hop[] memory sell = new IAethraRouter.Hop[](1);
        sell[0] = IAethraRouter.Hop(Venue.V4, address(0), usdg, weth, abi.encode(key));
        vm.startPrank(USER);
        IERC20(usdg).approve(address(router), got);
        uint256 back = router.swap(sell, got, 0, USER, block.timestamp, false);
        vm.stopPrank();
        assertGt(back, ethIn * 95 / 100, "round trip lost more than fees and impact");
    }
}
