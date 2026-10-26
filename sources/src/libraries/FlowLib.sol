// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library FlowLib {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;

    struct FlowState {
        uint256 accumulator;
        uint256 lastBlock;
    }

    function decayAccumulator(FlowState memory state, uint256 currentBlock, uint256 decayBpsPerBlock)
        internal
        pure
        returns (uint256 decayed)
    {
        if (state.accumulator == 0) return 0;
        if (currentBlock <= state.lastBlock) return state.accumulator;

        uint256 blocksElapsed = currentBlock - state.lastBlock;

        // Prevent stale flow pressure from surviving long inactivity windows.
        // At 9_900 bps/block, 460 blocks is below ~1% of the original value.
        if (blocksElapsed >= 460) return 0;

        decayed = state.accumulator;

        uint256 windows = blocksElapsed / 50;
        uint256 remainder = blocksElapsed % 50;

        // Approximation of 0.99^50 scaled by BPS.
        for (uint256 w = 0; w < windows && w < 9; ++w) {
            decayed = (decayed * 6_050) / BPS;
            if (decayed == 0) return 0;
        }

        for (uint256 i = 0; i < remainder; ++i) {
            decayed = (decayed * decayBpsPerBlock) / BPS;
            if (decayed == 0) return 0;
        }
    }

    function updateAccumulator(
        FlowState memory state,
        uint256 currentBlock,
        uint256 amountIn,
        uint256 decayBpsPerBlock,
        uint256 depth
    ) internal pure returns (uint256 updated) {
        uint256 decayed = decayAccumulator(state, currentBlock, decayBpsPerBlock);
        updated = decayed + amountIn;

        if (depth > 0) {
            uint256 cap = depth * 10;
            if (updated > cap) return cap;
        }
    }

    function computeFeePips(
        uint24 baseFee,
        uint24 flowCoefficient,
        uint256 amountIn,
        uint256 depth,
        uint256 accumulator
    ) internal pure returns (uint24 feePips) {
        if (depth == 0) return baseFee;

        uint256 impactBps = (amountIn * BPS) / depth;
        uint256 flowBps = (accumulator * BPS) / depth;

        uint256 surcharge;
        if (impactBps + flowBps > 10) {
            surcharge = uint256(flowCoefficient) * (impactBps + flowBps - 10) / BPS;
        }

        uint256 total = uint256(baseFee) + surcharge;

        if (total > type(uint24).max) {
            return type(uint24).max;
        }

        return uint24(total);
    }

    function tenureMultiplierBps(uint256 blocksHeld) internal pure returns (uint256) {
        if (blocksHeld >= 5400) return 15_000; // 1.5x
        if (blocksHeld >= 1800) return 12_500; // 1.25x
        return 10_000; // 1.0x
    }
}
