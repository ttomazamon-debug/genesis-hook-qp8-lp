// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library FeeEngineV2Lib {
    uint256 internal constant BPS = 10_000;
    uint24 internal constant MAX_FEE_PIPS = 1_000_000;

    struct FeeInputs {
        uint24 baseFeePips;
        uint256 amountIn;
        uint256 depth;
        uint256 flowAccumulator;
        uint256 spotPriceX96;
        uint256 referencePriceX96;
        bool zeroForOne;
        uint256 minDepth;
        uint256 directionalPenaltyCoefficient;
        uint256 directionalConvexCoefficient;
        uint256 directionalDiscountCoefficient;
        uint256 directionalDiscountMaxPips;
        uint256 directionalNoiseBps;
        uint256 impactThresholdBps;
        uint256 impactCoefficient;
        uint256 flowCoefficient;
        uint256 dislocationThresholdBps;
        uint256 dislocationCoefficient;
        uint256 correctiveDiscountMaxBps;
        uint24 maxFeePips;
    }

    function computeFeePips(FeeInputs memory x) internal pure returns (uint24) {
        uint256 fee = x.baseFeePips;
        uint256 depth = x.depth < x.minDepth ? x.minDepth : x.depth;
        uint256 preDislocationBps = dislocationBpsOf(x.spotPriceX96, x.referencePriceX96);

        if (depth > 0 && x.amountIn > 0) {
            uint256 impactBps = (x.amountIn * BPS) / depth;
            if (impactBps > x.impactThresholdBps) {
                fee += ((impactBps - x.impactThresholdBps) * x.impactCoefficient) / BPS;
            }

            uint256 flowBps = (x.flowAccumulator * BPS) / depth;
            if (flowBps > 2_500) flowBps = 2_500;

            bool antiCorrective = preDislocationBps > x.dislocationThresholdBps
                && !isCorrectiveDirection(x.spotPriceX96, x.referencePriceX96, x.zeroForOne);

            if (antiCorrective) {
                fee += (flowBps * x.flowCoefficient) / BPS;
            }
        }

        if (preDislocationBps > x.dislocationThresholdBps) {
            uint256 postSpotPriceX96 = estimatedPostSpotPriceX96(x.spotPriceX96, x.amountIn, depth, x.zeroForOne);
            uint256 postDislocationBps = dislocationBpsOf(postSpotPriceX96, x.referencePriceX96);

            if (postDislocationBps > preDislocationBps + x.directionalNoiseBps) {
                uint256 worseningBps = postDislocationBps - preDislocationBps;

                fee += ((preDislocationBps - x.dislocationThresholdBps) * x.dislocationCoefficient) / BPS;

                fee += (worseningBps * x.directionalPenaltyCoefficient) / BPS;

                fee += (worseningBps * worseningBps * x.directionalConvexCoefficient) / (BPS * BPS);
            } else if (postDislocationBps + x.directionalNoiseBps < preDislocationBps) {
                uint256 improvementBps = preDislocationBps - postDislocationBps;

                // Corrective flow is still directional flow. It should not receive
                // an LP-fee discount; routing edge must come from vault-backed credits.
                // Apply a smaller premium than toxic/worsening flow.
                fee += (improvementBps * x.dislocationCoefficient) / (BPS * 4);
            }
        }

        uint256 cap = x.maxFeePips == 0 ? MAX_FEE_PIPS : x.maxFeePips;
        if (fee > cap) fee = cap;

        return uint24(fee);
    }

    function estimatedPostSpotPriceX96(uint256 spotPriceX96, uint256 amountIn, uint256 depth, bool zeroForOne)
        internal
        pure
        returns (uint256)
    {
        if (spotPriceX96 == 0 || amountIn == 0 || depth == 0) return spotPriceX96;

        uint256 impactBps = (amountIn * BPS) / depth;
        if (impactBps > 5_000) impactBps = 5_000;

        if (zeroForOne) {
            return (spotPriceX96 * (BPS - impactBps)) / BPS;
        }

        return (spotPriceX96 * (BPS + impactBps)) / BPS;
    }

    function dislocationBpsOf(uint256 spotPriceX96, uint256 referencePriceX96) internal pure returns (uint256) {
        if (spotPriceX96 == 0 || referencePriceX96 == 0) return 0;

        uint256 diff =
            spotPriceX96 > referencePriceX96 ? spotPriceX96 - referencePriceX96 : referencePriceX96 - spotPriceX96;

        return (diff * BPS) / referencePriceX96;
    }

    function isCorrectiveDirection(uint256 spotPriceX96, uint256 referencePriceX96, bool zeroForOne)
        internal
        pure
        returns (bool)
    {
        if (spotPriceX96 == referencePriceX96) return false;

        if (spotPriceX96 > referencePriceX96) {
            return zeroForOne;
        }

        return !zeroForOne;
    }
}
