// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice EMA and three recent sqrt-price samples, updated at most once per block.
/// @dev Historical twap field/function names do not imply elapsed-time weighting.
///      The independent external v3 reader implements the separate timed TWAP.
library OracleLib {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant Q96 = 2 ** 96;

    struct OracleState {
        uint256 emaPriceX96;
        uint256 twapPriceX96_0;
        uint256 twapPriceX96_1;
        uint256 twapPriceX96_2;
        uint256 lastBlock;
    }

    function initialize(uint256 spotPriceX96, uint256 currentBlock) internal pure returns (OracleState memory s) {
        s.emaPriceX96 = spotPriceX96;
        s.twapPriceX96_0 = spotPriceX96;
        s.twapPriceX96_1 = spotPriceX96;
        s.twapPriceX96_2 = spotPriceX96;
        s.lastBlock = currentBlock;
    }

    function update(OracleState memory s, uint256 spotPriceX96, uint256 currentBlock, uint256 alphaBps)
        internal
        pure
        returns (OracleState memory next)
    {
        next = s;

        if (currentBlock <= s.lastBlock) {
            return next;
        }

        uint256 emaOld = s.emaPriceX96;
        uint256 emaNew = ((emaOld * (BPS - alphaBps)) + (spotPriceX96 * alphaBps)) / BPS;

        next.emaPriceX96 = emaNew;
        next.twapPriceX96_2 = s.twapPriceX96_1;
        next.twapPriceX96_1 = s.twapPriceX96_0;
        next.twapPriceX96_0 = spotPriceX96;
        next.lastBlock = currentBlock;
    }

    function twap3(OracleState memory s) internal pure returns (uint256) {
        return (s.twapPriceX96_0 + s.twapPriceX96_1 + s.twapPriceX96_2) / 3;
    }

    function referencePriceX96(OracleState memory s) internal pure returns (uint256) {
        return (s.emaPriceX96 + twap3(s)) / 2;
    }

    function dislocationBps(uint256 spotPriceX96, uint256 refPriceX96) internal pure returns (uint256) {
        if (refPriceX96 == 0) return 0;

        if (spotPriceX96 >= refPriceX96) {
            return ((spotPriceX96 - refPriceX96) * BPS) / refPriceX96;
        } else {
            return ((refPriceX96 - spotPriceX96) * BPS) / refPriceX96;
        }
    }

    function isCorrectiveDirection(uint256 spotPriceX96, uint256 refPriceX96, bool zeroForOne)
        internal
        pure
        returns (bool)
    {
        if (spotPriceX96 > refPriceX96) {
            // spot too high, corrective move is selling token0 for token1
            return zeroForOne;
        } else if (spotPriceX96 < refPriceX96) {
            // spot too low, corrective move is buying token0 with token1
            return !zeroForOne;
        }
        return false;
    }

    function isConfirmedCorrectiveDirection(OracleState memory s, uint256 spotPriceX96, bool zeroForOne)
        internal
        pure
        returns (bool)
    {
        uint256 ref = referencePriceX96(s);
        if (ref == 0) return false;

        bool spotCorrective = isCorrectiveDirection(spotPriceX96, ref, zeroForOne);
        if (!spotCorrective) return false;

        bool twap0Corrective = isCorrectiveDirection(s.twapPriceX96_0, ref, zeroForOne);
        bool twap1Corrective = isCorrectiveDirection(s.twapPriceX96_1, ref, zeroForOne);

        // Require 2 historical confirmations always.
        // No strong-dislocation bypass: prevents N-1 manipulation -> N credit farming.
        return twap0Corrective && twap1Corrective;
    }

    function stalenessBlocks(OracleState memory s, uint256 currentBlock) internal pure returns (uint256) {
        if (currentBlock <= s.lastBlock) return 0;
        return currentBlock - s.lastBlock;
    }
}
