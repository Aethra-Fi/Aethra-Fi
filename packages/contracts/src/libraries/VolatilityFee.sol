// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title VolatilityFee
/// @notice Volatility-accumulator dynamic fee shared by the v4 hook, DLMM and DAMM pools.
/// @dev Fees are in pips (1e-6), matching Uniswap v4 (3000 = 0.30%).
///      "index" is a discrete price coordinate: the bin id for DLMM, tick / tickSpacing for v4 and DAMM.
///      On each swap:
///        - if `filterPeriod` has passed since the last update the reference index is reset to the
///          pre-swap index and the reference accumulator (refAcc) decays (to 0 once `decayPeriod` has passed);
///        - the accumulator becomes refAcc + |index - indexRef| * 10_000 (capped).
///      variable fee = control * (accumulator * stepBps)^2 / 1e14, total fee = base + variable (capped).
library VolatilityFee {
    uint24 internal constant MAX_FEE_PIPS = 100_000; // 10% hard ceiling

    struct Params {
        uint24 baseFee; // pips
        uint24 maxFee; // pips, <= MAX_FEE_PIPS
        uint16 filterPeriod; // seconds of "same burst" grouping
        uint16 decayPeriod; // seconds after which volatility fully resets
        uint16 reductionBps; // decay multiplier applied to the reference accumulator (bps)
        uint24 control; // variable fee control (A)
        uint24 maxAccumulator; // cap for the accumulator
        uint16 stepBps; // price step per index unit, in bps (bin step / tick spacing in bps)
    }

    struct State {
        uint24 accumulator;
        uint24 refAcc;
        int24 indexRef;
        uint40 lastUpdate;
    }

    error InvalidParams();

    function validate(Params memory p) internal pure {
        if (
            p.maxFee > MAX_FEE_PIPS || p.baseFee > p.maxFee || p.reductionBps > 10_000 || p.filterPeriod > p.decayPeriod
                || p.stepBps == 0
        ) revert InvalidParams();
    }

    /// @notice Decay step, run before a swap with the pre-swap index.
    function beforeSwap(State memory s, Params memory p, int24 index, uint256 nowTs) internal pure {
        uint256 dt = nowTs - s.lastUpdate;
        if (dt >= p.filterPeriod) {
            s.indexRef = index;
            s.refAcc = dt < p.decayPeriod ? uint24(uint256(s.accumulator) * p.reductionBps / 10_000) : 0;
        }
    }

    /// @notice Accumulator update, run after a swap with the post-swap index.
    function afterSwap(State memory s, Params memory p, int24 index, uint256 nowTs) internal pure {
        int256 d = int256(index) - int256(s.indexRef);
        uint256 dist = uint256(d < 0 ? -d : d);
        uint256 acc = uint256(s.refAcc) + dist * 10_000;
        s.accumulator = uint24(acc > p.maxAccumulator ? p.maxAccumulator : acc);
        s.lastUpdate = uint40(nowTs);
    }

    /// @notice Total fee in pips for the given accumulator.
    function fee(Params memory p, uint24 accumulator) internal pure returns (uint24) {
        uint256 u = uint256(accumulator) * p.stepBps;
        uint256 variable = (u * u * p.control) / 1e14;
        uint256 total = uint256(p.baseFee) + variable;
        return uint24(total > p.maxFee ? p.maxFee : total);
    }

    /// @notice Fee a swap would pay right now (decay applied, before the swap moves the index).
    function currentFee(State memory s, Params memory p, int24 index, uint256 nowTs) internal pure returns (uint24) {
        State memory tmp = State(s.accumulator, s.refAcc, s.indexRef, s.lastUpdate);
        beforeSwap(tmp, p, index, nowTs);
        // Before the swap the accumulator equals refAcc + distance already travelled in this burst.
        afterSwap(tmp, p, index, nowTs);
        return fee(p, tmp.accumulator);
    }
}
