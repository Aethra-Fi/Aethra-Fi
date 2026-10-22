// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IDLMMFactory} from "../../src/interfaces/IAethraPools.sol";
import {IAethraHub} from "../../src/interfaces/IAethraHub.sol";
import {DLMMPool} from "../../src/dlmm/DLMMPool.sol";
import {DLMMFactory} from "../../src/dlmm/DLMMFactory.sol";
import {BinMath} from "../../src/dlmm/BinMath.sol";
import {VolatilityFee} from "../../src/libraries/VolatilityFee.sol";
import {DLMMBase, TestToken} from "./DLMMBase.t.sol";

contract DLMMFactoryV2 is DLMMFactory {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract DLMMPoolV2 is DLMMPool {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract DLMMFactoryTest is DLMMBase {
    function _params(address a, address b, uint16 step, int24 active)
        internal
        pure
        returns (IDLMMFactory.CreateParams memory)
    {
        return IDLMMFactory.CreateParams(a, b, step, active, BASE_FEE, MAX_FEE);
    }

    function test_initialState() public view {
        assertEq(factory.owner(), owner);
        assertEq(factory.hub(), address(hub));
        assertEq(factory.beacon(), address(beacon));
        uint16[6] memory steps = [uint16(1), 5, 10, 25, 50, 100];
        for (uint256 i; i < 6; ++i) assertTrue(factory.isBinStepAllowed(steps[i]));
        assertFalse(factory.isBinStepAllowed(2));
        DLMMFactory.VolatilityDefaults memory d = factory.volatilityDefaults();
        assertEq(d.filterPeriod, 30);
        assertEq(d.decayPeriod, 600);
    }

    function test_cannotReinitialize() public {
        vm.expectRevert();
        factory.initialize(address(this), address(hub), address(beacon));
        // the implementation is locked too
        DLMMFactory impl = new DLMMFactory();
        vm.expectRevert();
        impl.initialize(address(this), address(hub), address(beacon));
    }

    function test_createPoolSortsAndRegisters() public {
        TestToken x = new TestToken("X", 6);
        TestToken y = new TestToken("Y", 18);
        (address lo, address hi) = address(x) < address(y) ? (address(x), address(y)) : (address(y), address(x));
        vm.prank(trader);
        address p = factory.createPool(_params(hi, lo, 10, -1234));
        assertEq(DLMMPool(p).token0(), lo);
        assertEq(DLMMPool(p).token1(), hi);
        assertEq(DLMMPool(p).activeId(), -1234);
        assertEq(DLMMPool(p).binStepBps(), 10);
        assertEq(DLMMPool(p).feeParams().stepBps, 10);
        assertEq(DLMMPool(p).feeParams().baseFee, BASE_FEE);
        assertEq(factory.getPool(lo, hi, 10), p);
        assertEq(factory.getPool(hi, lo, 10), p);
        assertEq(factory.getPool(lo, hi, 25), address(0));
        assertTrue(factory.isPool(p));
        assertTrue(factory.isPool(address(pool)));
        assertFalse(factory.isPool(address(0xdead)));
        assertEq(factory.allPools().length, 2);
        assertEq(factory.poolCount(), 2);
        IAethraHub.PoolInfo memory info = hub.pool(bytes32(uint256(uint160(p))));
        assertEq(info.pool, p);
        assertEq(info.creator, trader);
        assertEq(hub.poolCount(), 2);
    }

    function test_createPoolEmits() public {
        TestToken x = new TestToken("X", 18);
        (address t0, address t1) =
            address(x) < address(token0) ? (address(x), address(token0)) : (address(token0), address(x));
        vm.expectEmit(false, true, true, true, address(factory));
        emit IDLMMFactory.PoolCreated(address(0), t0, t1, 5, 7, address(this));
        factory.createPool(_params(address(x), address(token0), 5, 7));
    }

    function test_createPoolRejects() public {
        vm.expectRevert(DLMMFactory.PoolExists.selector);
        factory.createPool(_params(address(token1), address(token0), STEP, 0));
        vm.expectRevert(DLMMFactory.IdenticalTokens.selector);
        factory.createPool(_params(address(token0), address(token0), STEP, 0));
        vm.expectRevert(DLMMFactory.ZeroAddress.selector);
        factory.createPool(_params(address(0), address(token0), STEP, 0));
        vm.expectRevert(DLMMFactory.BinStepNotAllowed.selector);
        factory.createPool(_params(address(token0), address(token1), 7, 0));
        // active id outside the price range
        vm.expectRevert(BinMath.PriceOutOfRange.selector);
        factory.createPool(_params(address(token0), address(token1), 100, 8000));
        // invalid fees
        IDLMMFactory.CreateParams memory p = _params(address(token0), address(token1), 50, 0);
        p.baseFee = p.maxFee + 1;
        vm.expectRevert(VolatilityFee.InvalidParams.selector);
        factory.createPool(p);
    }

    function test_createPoolRequiresRegistrar() public {
        vm.prank(owner);
        hub.setRegistrar(address(factory), false);
        vm.expectRevert(IAethraHub.NotRegistrar.selector);
        factory.createPool(_params(address(token0), address(token1), 50, 0));
    }

    function test_adminSetters() public {
        vm.expectRevert();
        factory.setBinStep(7, true);
        vm.startPrank(owner);
        factory.setBinStep(7, true);
        assertTrue(factory.isBinStepAllowed(7));
        vm.expectRevert(DLMMFactory.BinStepNotAllowed.selector);
        factory.setBinStep(0, true);
        factory.setVolatilityDefaults(DLMMFactory.VolatilityDefaults(10, 100, 2500, 20_000, 100_000));
        vm.expectRevert(VolatilityFee.InvalidParams.selector);
        factory.setVolatilityDefaults(DLMMFactory.VolatilityDefaults(200, 100, 2500, 20_000, 100_000));
        VolatilityFee.Params memory fp = pool.feeParams();
        vm.expectRevert(DLMMFactory.UnknownPool.selector);
        factory.setPoolFeeParams(address(0x1234), fp);
        vm.stopPrank();
        address p = factory.createPool(_params(address(token0), address(token1), 7, 0));
        assertEq(DLMMPool(p).feeParams().filterPeriod, 10);
        assertEq(DLMMPool(p).feeParams().control, 20_000);
    }

    function test_factoryUpgradeKeepsState() public {
        address before = factory.getPool(address(token0), address(token1), STEP);
        address impl = address(new DLMMFactoryV2());
        vm.prank(owner);
        factory.upgradeToAndCall(impl, "");
        assertEq(DLMMFactoryV2(address(factory)).version(), 2);
        assertEq(factory.getPool(address(token0), address(token1), STEP), before);
        assertEq(factory.owner(), owner);
        assertEq(factory.beacon(), address(beacon));
        factory.createPool(_params(address(token0), address(token1), 50, 0));
        assertEq(factory.poolCount(), 2);
    }

    function test_factoryUpgradeOnlyOwner() public {
        address impl = address(new DLMMFactoryV2());
        vm.expectRevert();
        factory.upgradeToAndCall(impl, "");
    }

    function test_beaconUpgradesAllPools() public {
        _seed(pool, lp, 3, 1e18);
        _swap(pool, trader, true, 1e18);
        int24 active = pool.activeId();
        (uint128 r0, uint128 r1, uint256 t) = pool.getBin(active);
        uint256 lpShares = pool.sharesOf(active, lp);

        address impl2 = address(new DLMMPoolV2());
        vm.expectRevert();
        beacon.upgradeTo(impl2);
        vm.prank(owner);
        beacon.upgradeTo(impl2);

        assertEq(DLMMPoolV2(address(pool)).version(), 2);
        assertEq(pool.activeId(), active);
        (uint128 r0b, uint128 r1b, uint256 tb) = pool.getBin(active);
        assertEq(r0b, r0);
        assertEq(r1b, r1);
        assertEq(tb, t);
        assertEq(pool.sharesOf(active, lp), lpShares);
        // pools created after the upgrade also use v2
        address p = factory.createPool(_params(address(token0), address(token1), 50, 0));
        assertEq(DLMMPoolV2(p).version(), 2);
        // and still work
        _swap(pool, trader, false, 1e18);
    }

    function test_proxyIsolation() public {
        // a second factory proxy has its own namespaced storage
        DLMMFactory f2 = DLMMFactory(
            address(
                new ERC1967Proxy(
                    address(new DLMMFactory()), abi.encodeCall(DLMMFactory.initialize, (owner, address(hub), address(beacon)))
                )
            )
        );
        assertEq(f2.poolCount(), 0);
        assertEq(f2.getPool(address(token0), address(token1), STEP), address(0));
    }
}
