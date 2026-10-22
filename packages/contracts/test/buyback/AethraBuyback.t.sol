// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAethraHub, Venue} from "../../src/interfaces/IAethraHub.sol";
import {IAethraBuyback, IAethraRouter} from "../../src/interfaces/IAethraPeriphery.sol";
import {AethraBuyback} from "../../src/buyback/AethraBuyback.sol";
import {MockToken} from "../credit/mocks/MockToken.sol";
import {MockRouter} from "../credit/mocks/MockRouter.sol";
import {CreditBase} from "../credit/LendingVault.t.sol";

contract AethraBuybackV2 is AethraBuyback {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract AethraBuybackTest is CreditBase {
    AethraBuyback bb;
    MockRouter router;
    MockToken aeth;
    MockToken usd;
    MockToken weth;
    address keeper = address(0xEE9E);

    function setUp() public {
        _deployHub(); // treasury = 0x7EA5
        aeth = new MockToken("AETH", 18);
        usd = new MockToken("tUSD", 6);
        weth = new MockToken("WETH", 18);
        router = new MockRouter(address(weth));
        router.setRate(address(usd), address(aeth), 10e30); // 1 tUSD (1e6) -> 10 AETH (1e19)
        router.setRate(address(weth), address(aeth), 20_000e18);
        bb = AethraBuyback(
            payable(
                address(
                    new ERC1967Proxy(
                        address(new AethraBuyback()),
                        abi.encodeCall(
                            AethraBuyback.initialize,
                            (owner, IAethraHub(address(hub)), IAethraRouter(address(router)), address(aeth))
                        )
                    )
                )
            )
        );
        vm.prank(owner);
        hub.setOperator(keeper, true);
    }

    function _route(address tokenIn) internal view returns (IAethraRouter.Hop[] memory r) {
        r = new IAethraRouter.Hop[](1);
        r[0] = IAethraRouter.Hop(Venue.V4, address(0), tokenIn, address(aeth), "");
    }

    function test_initialState() public view {
        (IAethraHub h, IAethraRouter r, uint64 cooldown, uint16 tBps) = bb.config();
        assertEq(address(h), address(hub));
        assertEq(address(r), address(router));
        assertEq(cooldown, 1 hours);
        assertEq(tBps, 2000);
        assertEq(bb.aeth(), address(aeth));
        assertEq(bb.owner(), owner);
    }

    function test_syncEmitsRevenueOnce() public {
        usd.mint(address(bb), 100e6);
        vm.expectEmit(address(bb));
        emit IAethraBuyback.RevenueReceived(address(usd), 100e6, address(this));
        assertEq(bb.sync(address(usd)), 100e6);
        assertEq(bb.sync(address(usd)), 0);
    }

    function test_executeSplitsTreasuryAndBurns() public {
        usd.mint(address(bb), 100e6);
        uint256 supplyBefore = aeth.totalSupply();
        vm.prank(keeper);
        uint256 burned = bb.execute(address(usd), 100e6, _route(address(usd)), 800e18);
        // 20% to treasury, 80 tUSD -> 800 AETH burned
        assertEq(burned, 800e18);
        assertEq(usd.balanceOf(treasury), 20e6);
        assertEq(usd.balanceOf(address(bb)), 0);
        assertEq(aeth.balanceOf(address(bb)), 0);
        assertEq(aeth.totalSupply(), supplyBefore); // minted by the router, then burned
        assertEq(bb.totalBurned(), 800e18);
        assertEq(bb.totalBought(address(usd)), 80e6);
        assertEq(bb.lastExecution(address(usd)), block.timestamp);
        assertEq(bb.nextExecution(address(usd)), block.timestamp + 1 hours);
    }

    function test_executeNativeEth() public {
        vm.deal(address(bb), 1e18);
        vm.prank(keeper);
        uint256 burned = bb.execute(address(0), 1e18, _route(address(weth)), 0);
        assertEq(burned, 0.8e18 * 20_000);
        assertEq(treasury.balance, 0.2e18);
        assertEq(address(bb).balance, 0);
    }

    function test_executeAethBurnsDirectly() public {
        aeth.mint(address(bb), 1000e18);
        vm.prank(owner);
        uint256 burned = bb.execute(address(aeth), 1000e18, new IAethraRouter.Hop[](0), 0);
        assertEq(burned, 800e18);
        assertEq(aeth.balanceOf(treasury), 200e18);
        assertEq(aeth.totalSupply(), 200e18);
    }

    function test_executeRejects() public {
        usd.mint(address(bb), 100e6);
        vm.expectRevert(IAethraBuyback.NotKeeper.selector);
        bb.execute(address(usd), 100e6, _route(address(usd)), 0);

        vm.startPrank(keeper);
        vm.expectRevert(AethraBuyback.ZeroAmount.selector);
        bb.execute(address(usd), 0, _route(address(usd)), 0);
        vm.expectRevert(AethraBuyback.InsufficientBalance.selector);
        bb.execute(address(usd), 101e6, _route(address(usd)), 0);
        vm.expectRevert(AethraBuyback.BadRoute.selector);
        bb.execute(address(usd), 100e6, _route(address(weth)), 0);
        vm.expectRevert(AethraBuyback.BadRoute.selector);
        bb.execute(address(usd), 100e6, new IAethraRouter.Hop[](0), 0);
        vm.expectRevert(IAethraRouter.Slippage.selector);
        bb.execute(address(usd), 100e6, _route(address(usd)), 801e18);

        bb.execute(address(usd), 50e6, _route(address(usd)), 0);
        vm.expectRevert(IAethraBuyback.Cooldown.selector);
        bb.execute(address(usd), 10e6, _route(address(usd)), 0);
        vm.warp(block.timestamp + 1 hours);
        bb.execute(address(usd), 10e6, _route(address(usd)), 0);
        vm.stopPrank();
    }

    function test_noTreasuryBurnsEverything() public {
        vm.prank(owner);
        hub.setFeeConfig(address(bb), address(0), 1000);
        usd.mint(address(bb), 10e6);
        vm.prank(keeper);
        assertEq(bb.execute(address(usd), 10e6, _route(address(usd)), 0), 100e18);
    }

    function test_adminOnly() public {
        vm.expectRevert();
        bb.setConfig(IAethraRouter(address(router)), 0, 0);
        vm.expectRevert();
        bb.rescue(address(usd), address(this), 0);
        vm.startPrank(owner);
        vm.expectRevert(AethraBuyback.InvalidParams.selector);
        bb.setConfig(IAethraRouter(address(router)), 0, 10_001);
        bb.setConfig(IAethraRouter(address(router)), 5 minutes, 0);
        usd.mint(address(bb), 5e6);
        bb.rescue(address(usd), owner, 5e6);
        vm.stopPrank();
        assertEq(usd.balanceOf(owner), 5e6);
    }

    function test_upgradeKeepsState() public {
        usd.mint(address(bb), 10e6);
        vm.prank(keeper);
        bb.execute(address(usd), 10e6, _route(address(usd)), 0);
        address impl = address(new AethraBuybackV2());
        vm.expectRevert();
        bb.upgradeToAndCall(impl, "");
        vm.prank(owner);
        bb.upgradeToAndCall(impl, "");
        assertEq(AethraBuybackV2(payable(address(bb))).version(), 2);
        assertEq(bb.totalBurned(), 80e18);
    }

    function testFuzz_splitConserves(uint96 amount, uint16 tBps) public {
        uint256 amt = bound(uint256(amount), 1, 1e30);
        uint16 bps = uint16(bound(tBps, 0, 10_000));
        vm.prank(owner);
        bb.setConfig(IAethraRouter(address(router)), 0, bps);
        usd.mint(address(bb), amt);
        vm.prank(keeper);
        uint256 burned = bb.execute(address(usd), amt, _route(address(usd)), 0);
        uint256 toTreasury = amt * bps / 10_000;
        assertEq(usd.balanceOf(treasury), toTreasury);
        assertEq(bb.totalBought(address(usd)), amt - toTreasury);
        assertEq(burned, (amt - toTreasury) * 10e30 / 1e18);
        assertEq(usd.balanceOf(address(bb)), 0);
    }
}
