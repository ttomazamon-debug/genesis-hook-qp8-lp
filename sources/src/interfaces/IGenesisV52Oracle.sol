// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

interface IGenesisV52Oracle {
    /// @return valid True only if a fresh, well-formed TWAP was obtained.
    /// @return fairValueX96 sqrtPriceX96-format TWAP. Zero when !valid.
    function fairValueX96(address source)
        external
        view
        returns (bool valid, uint256 fairValueX96);
}
