// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @notice Amplified-depth and quote MODEL helpers, not the native pool invariant.
/// @dev Virtual model liquidity is not newly deposited native liquidity.
library AmpLib {
    uint256 internal constant BPS = 10_000;

    function effectiveLiquidity(
        uint256 realLiquidity,
        uint256 spotPriceX96,
        uint256 referencePriceX96,
        uint256 ampBandBps,
        uint256 ampFactorBps
    ) internal pure returns (uint256) {
        if (realLiquidity == 0) return 0;
        if (referencePriceX96 == 0) return realLiquidity;
        if (ampFactorBps <= BPS) return realLiquidity;

        uint256 devBps = deviationBps(spotPriceX96, referencePriceX96);
        if (devBps > ampBandBps) return realLiquidity;

        return FullMath.mulDiv(realLiquidity, ampFactorBps, BPS);
    }

    function oracleAnchoredPriceX96(uint256 spotPriceX96, uint256 referencePriceX96, uint256 oracleWeightBps)
        internal
        pure
        returns (uint256)
    {
        if (spotPriceX96 == 0) return referencePriceX96;
        if (referencePriceX96 == 0) return spotPriceX96;
        if (oracleWeightBps == 0) return spotPriceX96;
        if (oracleWeightBps >= BPS) return referencePriceX96;

        uint256 spotWeight = BPS - oracleWeightBps;
        return ((spotPriceX96 * spotWeight) + (referencePriceX96 * oracleWeightBps)) / BPS;
    }

    function deviationBps(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0 || b == 0) return 0;

        if (a >= b) {
            return ((a - b) * BPS) / b;
        } else {
            return ((b - a) * BPS) / b;
        }
    }

    function bonusBpsFromDislocation(uint256 dislocationBps, uint256 bonusPerBps) internal pure returns (uint256) {
        if (dislocationBps == 0 || bonusPerBps == 0) return 0;
        return (dislocationBps * bonusPerBps) / BPS;
    }

    function exactOutput(
        uint256 amountIn,
        uint256 spotPriceX96,
        uint256 referencePriceX96,
        uint128 realLiquidity,
        uint24 feePips,
        uint256 ampBandBps,
        uint256 ampFactorBps,
        uint256 oracleWeightBps,
        bool zeroForOne
    ) public pure returns (uint256 amountOut, bool amplified) {
        if (amountIn == 0 || spotPriceX96 == 0 || realLiquidity == 0) {
            return (0, false);
        }

        uint256 execPriceX96 = oracleAnchoredPriceX96(spotPriceX96, referencePriceX96, oracleWeightBps);

        uint256 lo = uint256(TickMath.MIN_SQRT_PRICE) + 1;
        uint256 hi = uint256(TickMath.MAX_SQRT_PRICE) - 1;

        if (execPriceX96 < lo) execPriceX96 = lo;
        if (execPriceX96 > hi) execPriceX96 = hi;

        uint128 effectiveLiq = realLiquidity;

        if (referencePriceX96 != 0 && ampFactorBps > BPS && deviationBps(spotPriceX96, referencePriceX96) <= ampBandBps)
        {
            uint256 scaled = FullMath.mulDiv(uint256(realLiquidity), ampFactorBps, BPS);
            effectiveLiq = scaled > type(uint128).max ? type(uint128).max : uint128(scaled);
            amplified = true;
        }

        uint160 sqrtPriceCurrentX96 = uint160(execPriceX96);
        uint160 sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

        (,, amountOut,) =
            SwapMath.computeSwapStep(sqrtPriceCurrentX96, sqrtPriceLimitX96, effectiveLiq, -int256(amountIn), feePips);
    }
}
