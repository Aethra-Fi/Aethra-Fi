// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FixedPointMathLib as FPM} from "solady/utils/FixedPointMathLib.sol";
import {BinMath} from "../../src/dlmm/BinMath.sol";

contract BinMathHarness {
    using BinMath for BinMath.Tree;

    BinMath.Tree tree;

    function price(int24 id, uint16 step) external pure returns (uint256) {
        return BinMath.getPriceX128(id, step);
    }

    function add(int24 id) external {
        tree.add(id);
    }

    function remove(int24 id) external {
        tree.remove(id);
    }

    function contains(int24 id) external view returns (bool) {
        return tree.contains(id);
    }

    function above(int24 id) external view returns (bool, int24) {
        return tree.nextAbove(id);
    }

    function below(int24 id) external view returns (bool, int24) {
        return tree.nextBelow(id);
    }
}

contract BinMathTest is Test {
    uint256 constant ONE = 1 << 128;
    BinMathHarness h;

    function setUp() public {
        h = new BinMathHarness();
    }

    function _step(uint256 seed) internal pure returns (uint16) {
        uint16[6] memory steps = [uint16(1), 5, 10, 25, 50, 100];
        return steps[seed % 6];
    }

    /// @dev Largest |id| with price inside [2^-100, 2^100] (approximate, from ln).
    function _maxId(uint16 step) internal pure returns (int256) {
        int256 lnBase = FPM.lnWad(int256((10_000 + uint256(step)) * 1e14));
        return (100 * 693_147_180_559_945_309) / lnBase; // 100 * ln(2) / ln(1 + s)
    }

    function test_priceAnchors() public view {
        assertEq(h.price(0, 25), ONE);
        assertEq(h.price(1, 25), (uint256(10_025) << 128) / 10_000);
        assertApproxEqAbs(h.price(-1, 25), FPM.fullMulDiv(ONE, 10_000, 10_025), 1);
        // 2^... sanity: (1.01)^100 ~= 2.704813829
        assertApproxEqRel(h.price(100, 100) * 1e9 / ONE, 2_704_813_829, 1e9);
    }

    function test_priceBounds() public {
        int256 m = _maxId(1);
        h.price(int24(m - 10), 1);
        h.price(int24(-(m - 10)), 1);
        vm.expectRevert(BinMath.PriceOutOfRange.selector);
        h.price(int24(m + 10), 1);
        vm.expectRevert(BinMath.PriceOutOfRange.selector);
        h.price(int24(-(m + 10)), 1);
        vm.expectRevert(BinMath.PriceOutOfRange.selector);
        h.price(type(int24).max, 100);
        vm.expectRevert(BinMath.PriceOutOfRange.selector);
        h.price(type(int24).min, 1);
    }

    function testFuzz_monotonic(int24 id, uint256 seed) public view {
        uint16 step = _step(seed);
        int256 m = _maxId(step) - 2;
        id = int24(bound(id, -m, m));
        uint256 p0 = h.price(id, step);
        uint256 p1 = h.price(id + 1, step);
        assertGt(p1, p0);
        // the ratio is the bin step
        assertApproxEqRel(FPM.fullMulDiv(p1, 1e18, p0), 1e18 + uint256(step) * 1e14, 1e10);
    }

    /// @dev Independent check: repeated multiplication (linear) vs square-and-multiply.
    function testFuzz_matchesRepeatedMultiplication(int24 id, uint256 seed) public view {
        uint16 step = _step(seed);
        id = int24(bound(id, -1500, 1500));
        uint256 n = id < 0 ? uint256(-int256(id)) : uint256(int256(id));
        uint256 numer = 10_000 + uint256(step);
        // exact rational accumulation in 1e60 fixed point
        uint256 acc = 1e60;
        for (uint256 i; i < n; ++i) {
            acc = id < 0 ? acc * 10_000 / numer : acc * numer / 10_000;
        }
        uint256 expected = FPM.fullMulDiv(acc, ONE, 1e60);
        assertApproxEqRel(h.price(id, step), expected, 1e3); // 1e-15 relative
    }

    /// @dev Independent check for large ids: exp(id * ln(1 + s)).
    function testFuzz_matchesExp(int24 id, uint256 seed) public view {
        uint16 step = _step(seed);
        int256 lnBase = FPM.lnWad(int256((10_000 + uint256(step)) * 1e14));
        int256 m = int256(60e18) / lnBase; // keep e^x inside a comfortable WAD range
        id = int24(bound(id, 0, m));
        uint256 expectedWad = uint256(FPM.expWad(int256(id) * lnBase));
        uint256 gotWad = FPM.fullMulDiv(h.price(id, step), 1e18, ONE);
        assertApproxEqRel(gotWad, expectedWad, 1e7); // 1e-11 relative
        // negative ids are the reciprocal
        uint256 prod = FPM.fullMulDiv(h.price(id, step), h.price(-id, step), ONE);
        // the small side has fewer significant bits (>= 2^41 here), so allow 1e-11
        assertApproxEqRel(prod, ONE, 1e7);
    }

    function testFuzz_outOfRangeAlwaysCleanRevert(int24 id, uint256 seed) public {
        uint16 step = _step(seed);
        int256 m = _maxId(step);
        int256 a = id < 0 ? -int256(id) : int256(id);
        vm.assume(a > m + 2);
        vm.expectRevert(BinMath.PriceOutOfRange.selector);
        h.price(id, step);
    }

    // ------------------------------------------------------------------ tree

    function test_treeBasics() public {
        (bool f,) = h.above(0);
        assertFalse(f);
        (f,) = h.below(0);
        assertFalse(f);
        h.add(type(int24).min);
        h.add(type(int24).max);
        h.add(-300);
        h.add(5);
        h.add(70_000);
        int24 id;
        (f, id) = h.above(-300);
        assertTrue(f);
        assertEq(id, 5);
        (f, id) = h.above(5);
        assertEq(id, 70_000);
        (f, id) = h.above(70_000);
        assertEq(id, type(int24).max);
        (f,) = h.above(type(int24).max);
        assertFalse(f);
        (f, id) = h.below(5);
        assertEq(id, -300);
        (f, id) = h.below(-300);
        assertEq(id, type(int24).min);
        (f,) = h.below(type(int24).min);
        assertFalse(f);
        h.remove(5);
        assertFalse(h.contains(5));
        (f, id) = h.above(-300);
        assertEq(id, 70_000);
    }

    function testFuzz_treeMatchesBruteForce(int24[12] memory raw, int24 query, uint8 removeMask) public {
        int24[12] memory ids;
        bool[12] memory live;
        for (uint256 i; i < 12; ++i) {
            // cluster half of the ids to exercise same-word paths
            ids[i] = i % 2 == 0 ? raw[i] : int24(bound(raw[i], -600, 600));
            h.add(ids[i]);
            live[i] = true;
        }
        for (uint256 i; i < 8; ++i) {
            if (removeMask & (1 << i) != 0) {
                h.remove(ids[i]);
                for (uint256 j; j < 12; ++j) {
                    if (ids[j] == ids[i]) live[j] = false;
                }
            }
        }
        if (query % 3 == 0) query = int24(bound(query, -700, 700));
        bool fa;
        bool fb;
        int24 ea = type(int24).max;
        int24 eb = type(int24).min;
        for (uint256 i; i < 12; ++i) {
            if (!live[i]) continue;
            if (ids[i] > query && ids[i] <= ea) (fa, ea) = (true, ids[i]);
            if (ids[i] < query && ids[i] >= eb) (fb, eb) = (true, ids[i]);
        }
        (bool ga, int24 a) = h.above(query);
        (bool gb, int24 b) = h.below(query);
        assertEq(ga, fa, "above found");
        assertEq(gb, fb, "below found");
        if (fa) assertEq(a, ea, "above id");
        if (fb) assertEq(b, eb, "below id");
    }
}
