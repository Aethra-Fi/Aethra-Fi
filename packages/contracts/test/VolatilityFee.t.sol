// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {VolatilityFee} from "../src/libraries/VolatilityFee.sol";

contract VolatilityFeeTest is Test {
    using VolatilityFee for VolatilityFee.State;

    function _params() internal pure returns (VolatilityFee.Params memory) {
        return VolatilityFee.Params({
            baseFee: 3000,
            maxFee: 50_000,
            filterPeriod: 30,
            decayPeriod: 600,
            reductionBps: 5000,
            control: 80_000,
            maxAccumulator: 3_500_000,
            stepBps: 25
        });
    }

    function test_baseFeeWhenCalm() public pure {
        VolatilityFee.Params memory p = _params();
        assertEq(VolatilityFee.fee(p, 0), 3000);
    }

    function test_accumulatesWithinBurstAndDecays() public pure {
        VolatilityFee.Params memory p = _params();
        VolatilityFee.State memory s;
        uint256 t = 1000;
        VolatilityFee.beforeSwap(s, p, 0, t);
        VolatilityFee.afterSwap(s, p, 10, t);
        assertEq(s.accumulator, 100_000);
        uint24 f1 = VolatilityFee.fee(p, s.accumulator);
        assertGt(f1, p.baseFee);

        // same burst: reference index unchanged, distance grows
        VolatilityFee.beforeSwap(s, p, 10, t + 5);
        VolatilityFee.afterSwap(s, p, 20, t + 5);
        assertEq(s.accumulator, 200_000);

        // new burst inside decay window: reference halves
        VolatilityFee.beforeSwap(s, p, 20, t + 100);
        assertEq(s.refAcc, 100_000);
        assertEq(s.indexRef, 20);

        // long pause: fully reset
        VolatilityFee.beforeSwap(s, p, 20, t + 10_000);
        assertEq(s.refAcc, 0);
    }

    function test_currentFeeDoesNotMutate() public pure {
        VolatilityFee.Params memory p = _params();
        VolatilityFee.State memory s = VolatilityFee.State(200_000, 0, 0, 1000);
        // consistent state: active index 20 is 20 steps from the burst reference 0
        uint24 f = VolatilityFee.currentFee(s, p, 20, 1010);
        assertEq(s.accumulator, 200_000);
        assertEq(s.lastUpdate, 1000);
        assertGt(f, p.baseFee);
    }

    function testFuzz_feeBounded(uint24 acc) public pure {
        VolatilityFee.Params memory p = _params();
        uint24 f = VolatilityFee.fee(p, acc);
        assertGe(f, p.baseFee);
        assertLe(f, p.maxFee);
    }

    function testFuzz_accumulatorCapped(int24 a, int24 b, uint32 dt) public pure {
        VolatilityFee.Params memory p = _params();
        VolatilityFee.State memory s;
        VolatilityFee.beforeSwap(s, p, a, uint256(dt) + 1);
        VolatilityFee.afterSwap(s, p, b, uint256(dt) + 1);
        assertLe(s.accumulator, p.maxAccumulator);
    }

    function test_validate() public {
        VolatilityFee.Params memory p = _params();
        VolatilityFee.validate(p);
        p.baseFee = p.maxFee + 1;
        vm.expectRevert(VolatilityFee.InvalidParams.selector);
        this.validateExt(p);
    }

    function validateExt(VolatilityFee.Params memory p) external pure {
        VolatilityFee.validate(p);
    }
}
