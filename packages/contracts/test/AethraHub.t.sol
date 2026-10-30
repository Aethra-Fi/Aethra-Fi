// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AethraHub} from "../src/core/AethraHub.sol";
import {IAethraHub, Venue, AssetClass} from "../src/interfaces/IAethraHub.sol";
import {MockPriceFeed} from "../src/mocks/MockPriceFeed.sol";

contract AethraHubV2 is AethraHub {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract AethraHubTest is Test {
    AethraHub hub;
    address owner = address(0xA11CE);
    address token = address(0x7070);

    function setUp() public {
        AethraHub impl = new AethraHub();
        hub = AethraHub(address(new ERC1967Proxy(address(impl), abi.encodeCall(AethraHub.initialize, (owner)))));
    }

    function test_initialState() public view {
        assertEq(hub.owner(), owner);
        assertTrue(hub.isOperator(owner));
        assertEq(hub.poolCount(), 0);
    }

    function test_cannotReinitialize() public {
        vm.expectRevert();
        hub.initialize(address(this));
    }

    function test_setAssetAndPrice() public {
        MockPriceFeed feed = new MockPriceFeed(address(this), 8, "TSLA / USD", 250e8);
        vm.prank(owner);
        hub.setAsset(token, AssetClass.STOCK, true, address(feed), 1 hours);
        assertEq(hub.getPrice(token), 250e18);
        (uint256 p, bool fresh, bool open) = hub.tryGetPrice(token);
        assertEq(p, 250e18);
        assertTrue(fresh && open);
        assertEq(hub.assetCount(), 1);

        feed.setPriceAndSession(260e8, false);
        (, , open) = hub.tryGetPrice(token);
        assertFalse(open);

        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(IAethraHub.StalePrice.selector);
        hub.getPrice(token);
        (, fresh,) = hub.tryGetPrice(token);
        assertFalse(fresh);
    }

    function test_priceWithoutOracle() public {
        vm.expectRevert(IAethraHub.NoOracle.selector);
        hub.getPrice(token);
        (uint256 p, bool fresh,) = hub.tryGetPrice(token);
        assertEq(p, 0);
        assertFalse(fresh);
    }

    function test_onlyOperatorSetsAsset() public {
        vm.expectRevert(IAethraHub.NotOperator.selector);
        hub.setAsset(token, AssetClass.STOCK, true, address(0), 0);
    }

    function test_registerPool() public {
        address registrar = address(0xBEEF);
        vm.prank(owner);
        hub.setRegistrar(registrar, true);
        vm.prank(registrar);
        hub.registerPool(bytes32("p1"), Venue.DLMM, address(1), address(2), address(3), address(4));
        assertEq(hub.poolCount(), 1);
        assertTrue(hub.isPoolEnabled(bytes32("p1")));
        IAethraHub.PoolInfo memory info = hub.pool(bytes32("p1"));
        assertEq(uint8(info.venue), uint8(Venue.DLMM));
        assertEq(info.creator, address(4));

        vm.prank(registrar);
        vm.expectRevert(IAethraHub.PoolExists.selector);
        hub.registerPool(bytes32("p1"), Venue.DLMM, address(1), address(2), address(3), address(4));

        vm.prank(owner);
        hub.setPoolEnabled(bytes32("p1"), false);
        assertFalse(hub.isPoolEnabled(bytes32("p1")));
    }

    function test_registerPoolRequiresRegistrar() public {
        vm.expectRevert(IAethraHub.NotRegistrar.selector);
        hub.registerPool(bytes32("p1"), Venue.DLMM, address(1), address(2), address(3), address(4));
    }

    function test_feeConfig() public {
        vm.startPrank(owner);
        hub.setFeeConfig(address(0xB), address(0xC), 2000);
        assertEq(hub.protocolFeeShareBps(), 2000);
        vm.expectRevert(IAethraHub.InvalidBps.selector);
        hub.setFeeConfig(address(0xB), address(0xC), 5001);
        vm.stopPrank();
    }

    function test_upgradeKeepsState() public {
        vm.startPrank(owner);
        hub.setFeeConfig(address(0xB), address(0xC), 1500);
        hub.upgradeToAndCall(address(new AethraHubV2()), "");
        vm.stopPrank();
        assertEq(AethraHubV2(address(hub)).version(), 2);
        assertEq(hub.protocolFeeShareBps(), 1500);
        assertEq(hub.owner(), owner);
    }

    function test_upgradeOnlyOwner() public {
        address impl = address(new AethraHubV2());
        vm.expectRevert();
        hub.upgradeToAndCall(impl, "");
    }

    function testFuzz_priceScaling(uint8 dec, uint64 raw) public {
        dec = uint8(bound(dec, 0, 24));
        vm.assume(raw > 0);
        MockPriceFeed feed = new MockPriceFeed(address(this), dec, "X", int256(uint256(raw)));
        vm.prank(owner);
        hub.setAsset(token, AssetClass.CANONICAL, true, address(feed), 1 days);
        uint256 expected = dec <= 18 ? uint256(raw) * 10 ** (18 - dec) : uint256(raw) / 10 ** (dec - 18);
        if (expected == 0) {
            vm.expectRevert(IAethraHub.BadPrice.selector);
            hub.getPrice(token);
        } else {
            assertEq(hub.getPrice(token), expected);
        }
    }
}
