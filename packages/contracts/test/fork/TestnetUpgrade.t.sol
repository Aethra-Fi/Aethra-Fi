// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {AethraHub} from "../../src/core/AethraHub.sol";
import {AethraHook} from "../../src/hooks/AethraHook.sol";
import {AethraRouter} from "../../src/periphery/AethraRouter.sol";
import {IAethraHub, Venue, AssetClass} from "../../src/interfaces/IAethraHub.sol";
import {IAethraRouter} from "../../src/interfaces/IAethraPeriphery.sol";

interface IWETHLike {
    function deposit() external payable;
}

/// @notice Rehearses the testnet upgrade (hub, hook, router) against the live testnet state in a fork:
///         every registered pool must quote exactly the same before and after, and a real swap must still work.
///         Opt-in because it needs the network:  FORK_TESTNET=1 forge test --match-path test/fork/TestnetUpgrade.t.sol -vv
contract TestnetUpgradeForkTest is Test {
    using PoolIdLibrary for PoolKey;

    address internal constant DEPLOYER = 0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C;
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    AethraHub internal hub;
    AethraHook internal hook;
    AethraRouter internal router;
    address internal weth;

    struct Probe {
        IAethraRouter.Hop hop;
        uint256 amountIn;
        string label;
    }

    function setUp() public {
        if (!vm.envOr("FORK_TESTNET", false)) vm.skip(true);
        vm.createSelectFork(vm.envOr("TESTNET_RPC_URL", string("https://rpc.testnet.chain.robinhood.com")));
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/../sdk/src/addresses/testnet.json"));
        hub = AethraHub(vm.parseJsonAddress(json, ".hub"));
        hook = AethraHook(vm.parseJsonAddress(json, ".hook"));
        router = AethraRouter(payable(vm.parseJsonAddress(json, ".router")));
        weth = vm.parseJsonAddress(json, ".weth");
    }

    function _probes() internal view returns (Probe[] memory out, uint256 n) {
        uint256 count = hub.poolCount();
        out = new Probe[](count);
        for (uint256 i; i < count; i++) {
            bytes32 id = hub.poolIdAt(i);
            IAethraHub.PoolInfo memory p = hub.pool(id);
            if (!p.enabled) continue;
            uint256 amountIn = 10 ** (IERC20Meta(p.token0).decimals() > 2 ? IERC20Meta(p.token0).decimals() - 2 : 0); // 0.01 token0
            if (p.venue == Venue.DLMM || p.venue == Venue.DAMM) {
                out[n++] = Probe(
                    IAethraRouter.Hop(p.venue, p.pool, p.token0, p.token1, ""), amountIn, string.concat("pool ", vm.toString(p.pool))
                );
            } else if (p.venue == Venue.V4) {
                (bool found, PoolKey memory key) = _keyFor(id, p.token0, p.token1);
                if (!found) continue;
                out[n++] = Probe(
                    IAethraRouter.Hop(Venue.V4, address(0), p.token0, p.token1, abi.encode(key)), amountIn, string.concat("v4 ", vm.toString(id))
                );
            }
        }
    }

    function _keyFor(bytes32 id, address t0, address t1) internal view returns (bool, PoolKey memory key) {
        int24[4] memory spacings = [int24(1), 10, 60, 200];
        for (uint256 i; i < spacings.length; i++) {
            key = PoolKey(Currency.wrap(t0), Currency.wrap(t1), LPFeeLibrary.DYNAMIC_FEE_FLAG, spacings[i], IHooks(address(hook)));
            if (PoolId.unwrap(key.toId()) == id) return (true, key);
        }
        return (false, key);
    }

    function test_upgradeKeepsQuotesAndSwaps() public {
        (Probe[] memory probes, uint256 n) = _probes();
        assertGt(n, 0, "no pools found on testnet");

        uint256[] memory before_ = new uint256[](n);
        for (uint256 i; i < n; i++) {
            IAethraRouter.Hop[] memory h = new IAethraRouter.Hop[](1);
            h[0] = probes[i].hop;
            (before_[i],) = router.quote(h, probes[i].amountIn);
        }

        IPoolManager pm = IPoolManager(POOL_MANAGER);
        address hubImpl = address(new AethraHub());
        address hookImpl = address(new AethraHook(pm));
        address routerImpl = address(new AethraRouter(pm, weth));
        vm.startPrank(DEPLOYER);
        UUPSUpgradeable(address(hub)).upgradeToAndCall(hubImpl, "");
        UUPSUpgradeable(address(hook)).upgradeToAndCall(hookImpl, "");
        UUPSUpgradeable(address(router)).upgradeToAndCall(routerImpl, "");
        vm.stopPrank();

        uint256 nonZero;
        for (uint256 i; i < n; i++) {
            IAethraRouter.Hop[] memory h = new IAethraRouter.Hop[](1);
            h[0] = probes[i].hop;
            (uint256 q,) = router.quote(h, probes[i].amountIn);
            assertEq(q, before_[i], probes[i].label);
            if (q > 0) nonZero++;
        }
        console2.log("pools probed", n);
        console2.log("pools that quote > 0", nonZero);
        assertGt(nonZero, 0, "no pool quoted");

        // a real swap through the upgraded router: wrap ETH, swap through the first route that quotes
        address trader = makeAddr("trader");
        vm.deal(trader, 1 ether);
        for (uint256 i; i < n; i++) {
            if (before_[i] == 0 || probes[i].hop.tokenIn != weth) continue;
            vm.startPrank(trader);
            IWETHLike(weth).deposit{value: 0.1 ether}();
            IERC20(weth).approve(address(router), type(uint256).max);
            IAethraRouter.Hop[] memory h = new IAethraRouter.Hop[](1);
            h[0] = probes[i].hop;
            (uint256 q,) = router.quote(h, 0.001 ether);
            uint256 out = router.swap(h, 0.001 ether, q * 99 / 100, trader, block.timestamp, false);
            vm.stopPrank();
            assertEq(out, q);
            assertEq(IERC20(probes[i].hop.tokenOut).balanceOf(trader), out);
            console2.log("swapped 0.001 WETH via", probes[i].label);
            return;
        }
        console2.log("no WETH-in route quoted; swap step skipped");
    }

    /// The deployed hub keeps its state and the new staleness rule applies to new assets only.
    function test_hubStateSurvivesAndNewRuleApplies() public {
        uint256 pools = hub.poolCount();
        uint256 assets = hub.assetCount();
        address wethOracle = hub.asset(weth).oracle;
        address impl = address(new AethraHub());
        vm.prank(DEPLOYER);
        UUPSUpgradeable(address(hub)).upgradeToAndCall(impl, "");
        assertEq(hub.poolCount(), pools);
        assertEq(hub.assetCount(), assets);
        assertEq(hub.asset(weth).oracle, wethOracle);
        assertEq(hub.owner(), DEPLOYER);

        address newToken = makeAddr("newToken");
        vm.prank(DEPLOYER);
        vm.expectRevert(IAethraHub.InvalidStaleness.selector);
        hub.setAsset(newToken, AssetClass.STOCK, true, wethOracle, 0);
    }
}

interface IERC20Meta {
    function decimals() external view returns (uint8);
}
