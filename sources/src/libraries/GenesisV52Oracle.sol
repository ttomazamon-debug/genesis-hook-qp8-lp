// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

interface IUniswapV3PoolMinimalV52 {
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (
            int56[] memory tickCumulatives,
            uint160[] memory secondsPerLiquidityCumulativeX128s
        );

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    function observations(uint256 index)
        external
        view
        returns (
            uint32 blockTimestamp,
            int56 tickCumulative,
            uint160 secondsPerLiquidityCumulativeX128,
            bool initialized
        );
}

/// @notice Stateless fair-value reader for GenesisHook V5.2.
/// @dev Holds no storage.
///
/// Logic transplanted from GenesisHook._externalFairValueX96 at canonical SHA:
/// 3ca120efddf4cbcca88712a466f3414c434e194960c89bea1622444688ac0801
///
/// Any failure returns (false, 0).
contract GenesisV52Oracle {
    uint32 public constant FAIR_VALUE_TWAP_SECONDS = 1_800;
    uint32 public constant FAIR_VALUE_MAX_STALENESS_SECONDS = 300;

    function fairValueX96(address source)
        external
        view
        returns (bool valid, uint256 fairValueX96)
    {
        if (source == address(0)) return (false, 0);

        IUniswapV3PoolMinimalV52 pool =
            IUniswapV3PoolMinimalV52(source);

        uint16 observationIndex;
        uint16 observationCardinality;

        try pool.slot0()
            returns (
                uint160,
                int24,
                uint16 index,
                uint16 cardinality,
                uint16,
                uint8,
                bool
            )
        {
            observationIndex = index;
            observationCardinality = cardinality;
        } catch {
            return (false, 0);
        }

        if (observationCardinality == 0) return (false, 0);

        try pool.observations(observationIndex)
            returns (
                uint32 observationTimestamp,
                int56,
                uint160,
                bool initialized
            )
        {
            if (!initialized) return (false, 0);

            if (block.timestamp < uint256(observationTimestamp)) {
                return (false, 0);
            }

            if (
                block.timestamp - uint256(observationTimestamp)
                    > FAIR_VALUE_MAX_STALENESS_SECONDS
            ) {
                return (false, 0);
            }
        } catch {
            return (false, 0);
        }

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = FAIR_VALUE_TWAP_SECONDS;
        secondsAgos[1] = 0;

        try pool.observe(secondsAgos)
            returns (
                int56[] memory tickCumulatives,
                uint160[] memory
            )
        {
            if (tickCumulatives.length != 2) {
                return (false, 0);
            }

            int56 delta =
                tickCumulatives[1] - tickCumulatives[0];

            int56 window =
                int56(uint56(FAIR_VALUE_TWAP_SECONDS));

            // Match Uniswap OracleLibrary arithmeticMeanTick semantics:
            // negative non-integral means round toward negative infinity.
            int24 arithmeticMeanTick =
                int24(delta / window);

            if (
                delta < 0
                    && (delta % window != 0)
            ) {
                arithmeticMeanTick--;
            }

            if (
                arithmeticMeanTick < TickMath.MIN_TICK
                    || arithmeticMeanTick > TickMath.MAX_TICK
            ) {
                return (false, 0);
            }

            return (
                true,
                uint256(
                    TickMath.getSqrtPriceAtTick(
                        arithmeticMeanTick
                    )
                )
            );
        } catch {
            return (false, 0);
        }
    }
}
