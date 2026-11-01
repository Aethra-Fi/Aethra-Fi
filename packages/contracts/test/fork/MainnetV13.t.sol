// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {IAethraHub, Venue} from "../../src/interfaces/IAethraHub.sol";
import {IAethraRouter} from "../../src/interfaces/IAethraPeriphery.sol";
import {AethraHook} from "../../src/hooks/AethraHook.sol";
import {DLMMFactory} from "../../src/dlmm/DLMMFactory.sol";
import {DLMMPool} from "../../src/dlmm/DLMMPool.sol";
import {AethraLaunchpad} from "../../src/launchpad/AethraLaunchpad.sol";

interface IWETH9t {
    function deposit() external payable;
}

/// @notice v1.3 opening rehearsal against the live mainnet deployment, the same steps as
///         `scripts/mainnet-v13.sh open` (script/mainnet/ReleaseV13.s.sol): hook and DLMM pool upgrades with the
///         treasury fallback, a 20% protocol share to the treasury, and the launchpad as a hub registrar. Then a user
///         launches a token and trades the curve, and a v4 swap's protocol fee is swept to the treasury.
///         Opt-in because it needs the network:  FORK_MAINNET=1 forge test --match-path test/fork/MainnetV13.t.sol -vv
contract MainnetV13Test is Test {
    address constant DEPLOYER = 0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C;
    address constant USER = address(0xA11CE13);
    bytes32 constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint16 constant SHARE = 2000;

    IAethraHub hub;
    IAethraRouter router;
    AethraLaunchpad launchpad;
    IPoolManager pm;
    address hook;
    address weth;
    address usdg;
    UpgradeableBeacon dlmmBeacon;
    address treasury;

    function setUp() public {
        if (!vm.envOr("FORK_MAINNET", false)) return;
        vm.createSelectFork("mainnet");
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/../sdk/src/addresses/mainnet.json"));
        hub = IAethraHub(vm.parseJsonAddress(json, ".hub"));
        router = IAethraRouter(vm.parseJsonAddress(json, ".router"));
        bytes memory lp = vm.parseJson(json, ".launchpad"); // top level since v1.3, under `hidden` before
        launchpad = AethraLaunchpad(lp.length == 32 && abi.decode(lp, (address)) != address(0) ? abi.decode(lp, (address)) : vm.parseJsonAddress(json, ".hidden.launchpad"));
        pm = IPoolManager(vm.parseJsonAddress(json, ".poolManager"));
        hook = vm.parseJsonAddress(json, ".hook");
        weth = vm.parseJsonAddress(json, ".weth");
        usdg = vm.parseJsonAddress(json, ".tokens.USDG.address");
        dlmmBeacon = UpgradeableBeacon(DLMMFactory(vm.parseJsonAddress(json, ".dlmmFactory")).beacon());
        treasury = hub.treasury();
        vm.deal(USER, 1 ether);
    }

    /// @dev what ReleaseV13 sends with MODE=open
    function _open() internal {
        vm.startPrank(DEPLOYER);
        UUPSUpgradeable(hook).upgradeToAndCall(address(new AethraHook(pm)), "");
        dlmmBeacon.upgradeTo(address(new DLMMPool()));
        hub.setFeeConfig(address(0), treasury, SHARE);
        hub.setRegistrar(address(launchpad), true);
        vm.stopPrank();
    }

    function test_launchpadLockedUntilOpen() public {
        if (!vm.envOr("FORK_MAINNET", false)) return;
        vm.prank(USER);
        vm.expectRevert();
        launchpad.create{value: 0.001 ether}("Locked", "LOCK", "", 0);
    }

    function test_openKeepsStateAndPointsFeesAtTreasury() public {
        if (!vm.envOr("FORK_MAINNET", false)) return;
        assertEq(hub.buyback(), address(0));
        _open();
        assertEq(hub.protocolFeeShareBps(), SHARE);
        assertEq(hub.treasury(), treasury);
        assertTrue(hub.isRegistrar(address(launchpad)));
        (address gpm,, address ghook) = launchpad.graduationTargets();
        assertEq(gpm, address(pm));
        assertEq(ghook, hook);
        assertGt(launchpad.graduationThreshold(), 0);
    }

    function test_launchAndTradeCurve() public {
        if (!vm.envOr("FORK_MAINNET", false)) return;
        _open();
        uint256 before = IERC20(weth).balanceOf(treasury);
        vm.prank(USER);
        address token = launchpad.create{value: 0.002 ether}("Aethra Fork Test", "AFT", "", 0);
        assertGt(IERC20(token).balanceOf(USER), 0, "initial buy bought nothing");
        assertEq(uint8(hub.pool(bytes32(uint256(uint160(token)))).venue), uint8(Venue.LAUNCH), "launch not registered");

        // sell half back through the router's LAUNCH hop, as the web app does
        uint256 half = IERC20(token).balanceOf(USER) / 2;
        IAethraRouter.Hop[] memory sell = new IAethraRouter.Hop[](1);
        sell[0] = IAethraRouter.Hop(Venue.LAUNCH, address(launchpad), token, weth, abi.encode(token));
        vm.startPrank(USER);
        IERC20(token).approve(address(router), half);
        uint256 got = router.swap(sell, half, 1, USER, block.timestamp, false);
        vm.stopPrank();
        assertGt(got, 0, "sell returned nothing");
        assertGt(IERC20(weth).balanceOf(treasury), before, "curve trade fees did not reach the treasury");
    }

    function test_v4SwapProtocolFeeToTreasury() public {
        if (!vm.envOr("FORK_MAINNET", false)) return;
        _open();
        PoolKey memory key = PoolKey(Currency.wrap(weth), Currency.wrap(usdg), LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, IHooks(hook));
        IAethraRouter.Hop[] memory h = new IAethraRouter.Hop[](1);
        h[0] = IAethraRouter.Hop(Venue.V4, address(0), weth, usdg, abi.encode(key));
        // the seeded pool holds about $0.22; a smaller trade's protocol fee rounds to zero USDG units
        uint256 amountIn = 0.00002 ether;
        vm.startPrank(USER);
        IWETH9t(weth).deposit{value: amountIn}();
        IERC20(weth).approve(address(router), amountIn);
        router.swap(h, amountIn, 0, USER, block.timestamp, false);
        vm.stopPrank();

        uint256 accrued = AethraHook(hook).protocolFees(Currency.wrap(usdg));
        assertGt(accrued, 0, "no protocol fee accrued");
        uint256 before = IERC20(usdg).balanceOf(treasury);
        assertEq(AethraHook(hook).collectProtocolFees(Currency.wrap(usdg)), accrued);
        assertEq(IERC20(usdg).balanceOf(treasury) - before, accrued);
    }
}
