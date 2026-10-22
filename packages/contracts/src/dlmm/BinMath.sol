// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {LibBit} from "solady/utils/LibBit.sol";

/// @title BinMath
/// @notice Bin pricing and a three-level bitmap of non-empty bins for Aethra DLMM pools.
/// @dev Prices are Q128.128 fixed point numbers of token1 per token0 in raw units:
///      price(id) = (1 + binStep / 10_000) ^ id.
///      Ids are restricted so that the price stays inside [2^-100, 2^100], well inside the range where the
///      Q128.128 representation keeps enough precision and value math (price * reserve) cannot overflow.
library BinMath {
    uint256 internal constant ONE = 1 << 128;
    /// @dev 2^100 in Q128.128. Positive powers above this revert.
    uint256 internal constant MAX_POW = 1 << 228;
    /// @dev Squares of values above 2^178 (Q128) exceed MAX_POW.
    uint256 private constant SQRT_MAX_POW = 1 << 178;
    /// @dev Below this, price * base (with price < base) fits in 256 bits after the Q128 shift.
    uint256 private constant SQUARE_LIMIT = 1 << 191;
    uint256 internal constant BPS = 10_000;

    error PriceOutOfRange();

    // ------------------------------------------------------------------ pricing

    /// @notice Q128.128 price of bin `id` for a bin step of `binStep` bps. Reverts if outside [2^-100, 2^100].
    function getPriceX128(int24 id, uint16 binStep) internal pure returns (uint256 price) {
        uint256 n = id < 0 ? uint256(-int256(id)) : uint256(int256(id));
        uint256 base = ((BPS + binStep) << 128) / BPS;
        price = ONE;
        // Square-and-multiply. The running square never exceeds the final power (base > 1), so bounding it
        // bounds the result. When multiplying, price < base holds, so the product can only overflow 256 bits
        // for base > 2^191; that rare branch is checked explicitly.
        while (true) {
            if (n & 1 != 0) {
                if (base > SQUARE_LIMIT && price > FixedPointMathLib.fullMulDiv(MAX_POW, ONE, base)) {
                    revert PriceOutOfRange();
                }
                price = FixedPointMathLib.fullMulDiv(price, base, ONE);
                if (price > MAX_POW) revert PriceOutOfRange();
            }
            n >>= 1;
            if (n == 0) break;
            // more bits remain, so the result is at least base^2
            if (base > SQRT_MAX_POW) revert PriceOutOfRange();
            base = FixedPointMathLib.fullMulDiv(base, base, ONE);
        }
        if (id < 0) price = FixedPointMathLib.fullMulDiv(ONE, ONE, price);
    }

    // ------------------------------------------------------------------ bitmap tree

    /// @dev 2^24 bins addressed by key = id + 2^23. level2 holds one bit per bin (65_536 words),
    ///      level1 one bit per non-empty level2 word (256 words), level0 one bit per non-empty level1 word.
    struct Tree {
        uint256 level0;
        mapping(uint256 => uint256) level1;
        mapping(uint256 => uint256) level2;
    }

    function _key(int24 id) private pure returns (uint256) {
        return uint256(int256(id) + 8_388_608);
    }

    function _id(uint256 key) private pure returns (int24) {
        return int24(int256(key) - 8_388_608);
    }

    function contains(Tree storage t, int24 id) internal view returns (bool) {
        uint256 k = _key(id);
        return t.level2[k >> 8] & (1 << (k & 255)) != 0;
    }

    function add(Tree storage t, int24 id) internal {
        uint256 k = _key(id);
        uint256 w2 = k >> 8;
        uint256 v2 = t.level2[w2];
        t.level2[w2] = v2 | (1 << (k & 255));
        if (v2 == 0) {
            uint256 w1 = k >> 16;
            uint256 v1 = t.level1[w1];
            t.level1[w1] = v1 | (1 << (w2 & 255));
            if (v1 == 0) t.level0 |= 1 << w1;
        }
    }

    function remove(Tree storage t, int24 id) internal {
        uint256 k = _key(id);
        uint256 w2 = k >> 8;
        uint256 v2 = t.level2[w2] & ~(1 << (k & 255));
        t.level2[w2] = v2;
        if (v2 == 0) {
            uint256 w1 = k >> 16;
            uint256 v1 = t.level1[w1] & ~(1 << (w2 & 255));
            t.level1[w1] = v1;
            if (v1 == 0) t.level0 &= ~(1 << w1);
        }
    }

    /// @notice Largest non-empty id strictly below `id`.
    function nextBelow(Tree storage t, int24 id) internal view returns (bool found, int24 next) {
        uint256 k = _key(id);
        uint256 w2 = k >> 8;
        uint256 m = t.level2[w2] & ((1 << (k & 255)) - 1);
        if (m != 0) return (true, _id((w2 << 8) | LibBit.fls(m)));
        uint256 w1 = k >> 16;
        m = t.level1[w1] & ((1 << (w2 & 255)) - 1);
        if (m == 0) {
            m = t.level0 & ((1 << w1) - 1);
            if (m == 0) return (false, 0);
            w1 = LibBit.fls(m);
            m = t.level1[w1];
        }
        w2 = (w1 << 8) | LibBit.fls(m);
        return (true, _id((w2 << 8) | LibBit.fls(t.level2[w2])));
    }

    /// @notice Smallest non-empty id strictly above `id`.
    function nextAbove(Tree storage t, int24 id) internal view returns (bool found, int24 next) {
        uint256 k = _key(id);
        uint256 w2 = k >> 8;
        uint256 m = t.level2[w2] & _above(k & 255);
        if (m != 0) return (true, _id((w2 << 8) | LibBit.ffs(m)));
        uint256 w1 = k >> 16;
        m = t.level1[w1] & _above(w2 & 255);
        if (m == 0) {
            m = t.level0 & _above(w1);
            if (m == 0) return (false, 0);
            w1 = LibBit.ffs(m);
            m = t.level1[w1];
        }
        w2 = (w1 << 8) | LibBit.ffs(m);
        return (true, _id((w2 << 8) | LibBit.ffs(t.level2[w2])));
    }

    /// @dev Mask of the bits strictly above bit `b` (b < 256).
    function _above(uint256 b) private pure returns (uint256 mask) {
        unchecked {
            mask = ~((2 << b) - 1);
        }
    }
}
