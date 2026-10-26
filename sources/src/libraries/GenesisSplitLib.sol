// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title GenesisSplitLib
/// @notice Single source of truth for V5 economic allocation.
/// @dev D and every resulting share are RAW units of the selected payout token.
///      The hook/GenesisDistLib bound D by physical backing, emission budget and caps.
///      Quote-model EXEC/improvement is not an additional distributable liability.
///      The split does not itself perform token transfers or verify backing.
library GenesisSplitLib {
    uint256 internal constant BPS = 10_000;

    struct SplitBps {
        uint16 trader; // default 4000
        uint16 lp; // default 2500
        uint16 protocol; // default 2000
        uint16 router; // default 1000
        uint16 keeper; // default 500
    }

    struct Shares {
        uint256 trader;
        uint256 lp;
        uint256 protocol;
        uint256 router;
        uint256 keeper;
        uint256 dust; // rounding remainder -> vault safety reserve
    }

    error SplitNot100Pct(uint256 sum);

    /// @notice Validate a split configuration. Governance MUST call this before
    ///         accepting new parameters.
    function validate(SplitBps memory s) internal pure {
        uint256 sum = uint256(s.trader) + s.lp + s.protocol + s.router + s.keeper;
        if (sum != BPS) revert SplitNot100Pct(sum);
    }

    /// @notice Split distributable value D into five shares plus dust.
    /// @dev Each share floors independently; dust = D - sum(shares).
    ///      Invariant: trader+lp+protocol+router+keeper+dust == D, always.
    ///      Dust is at most 4 wei-units per event (5 floor operations).
    function split(uint256 d, SplitBps memory s) internal pure returns (Shares memory out) {
        out.trader = d * s.trader / BPS;
        out.lp = d * s.lp / BPS;
        out.protocol = d * s.protocol / BPS;
        out.router = d * s.router / BPS;
        out.keeper = d * s.keeper / BPS;
        out.dust = d - (out.trader + out.lp + out.protocol + out.router + out.keeper);
    }

    /// @notice Fold the router share into the LP share for unattributed flow.
    /// @dev Called when hookData carried no valid registered-router beneficiary.
    ///      Attribution is thereby a revenue pitch to routers, not a favor.
    function foldRouterIntoLp(Shares memory sh) internal pure returns (Shares memory) {
        sh.lp += sh.router;
        sh.router = 0;
        return sh;
    }

    /// @notice Cap the trader rebate (per-block vault drain cap / vault surplus).
    ///         The unpaid remainder goes to dust (vault safety reserve), NEVER
    ///         to a deferred credit.
    function capTrader(Shares memory sh, uint256 maxTraderPayable) internal pure returns (Shares memory) {
        if (sh.trader > maxTraderPayable) {
            sh.dust += sh.trader - maxTraderPayable;
            sh.trader = maxTraderPayable;
        }
        return sh;
    }
}
