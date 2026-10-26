// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IGenesisRewardsController} from "src/interfaces/IGenesisRewardsController.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

interface IERC20MinimalDL {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title GenesisDistLib (Phase 3C — final)
/// @notice External linked library (DELEGATECALL → hook storage context).
///
/// ═══════════════════════════════════════════════════════════════════════════
/// ATOMICITY (review Blockers 1 + 2)
/// ═══════════════════════════════════════════════════════════════════════════
/// This library contains NO try/catch. It reverts freely.
///
/// The hook wraps the ENTIRE realization — cap stack, controller accrual,
/// cap/budget burn, physical transfers, settlement, backing decrement — in a
/// single `onlySelf` external subcall guarded by ONE try/catch in afterSwap.
/// EVM sub-call semantics give exact rollback: if ANY step fails, every state
/// change from the unit is reverted and the swap proceeds with zero hook delta.
///
/// The earlier nested design (try/catch here, transfers in the hook afterwards)
/// let controller obligations and cap burn SURVIVE a later transfer/settle
/// failure, recreating unbacked accounting. Removing this boundary fixes it.
///
/// ═══════════════════════════════════════════════════════════════════════════
/// CUSTODY (Model A) — WHY THERE IS NO reservedObligations() SUBTRACTION
/// ═══════════════════════════════════════════════════════════════════════════
/// Hook backing and controller obligations are PHYSICALLY DISJOINT POOLS.
///
/// Each realization moves the FULL D out of the hook:
///     backing     -= D
///     trader      -> PoolManager        (traderPaid += trader)
///     D - trader  -> the controller's vault  (vaultHeld += D - trader)
///
/// The controller's obligations are ledgered against the VAULT, and the vault has
/// ALREADY physically received those tokens in the same atomic unit. Therefore:
///
///     vaultHeld[t]           = lp + protocol + router + keeper + dust
///     reservedObligations[t] = lp + router + keeper + dust     (protocol not reserved)
///     ⇒ reservedObligations[t] <= vaultHeld[t]   always
///
/// Nothing in the controller has ANY claim on hook-held tokens. Every token still
/// in _realBackingRaw is unencumbered. Subtracting vault obligations from hook
/// backing would debit the same prior distributions TWICE — once when D left
/// backing, and again on every later swap — and since `reserved` grows while
/// `backing` shrinks, it would progressively throttle capacity to zero.
///
/// Hence: freeBacking == backing. The hook's RAW physical backing is the sole cap.
/// (This also removes an external call from the swap hot path.)
///
/// ═══════════════════════════════════════════════════════════════════════════
/// UNITS
/// ═══════════════════════════════════════════════════════════════════════════
/// Everything is RAW units of the swap's OUTPUT currency. No normalization, no
/// cross-currency aggregation, no price conversion. D is hard-capped by the RAW
/// physical backing of the exact token being paid out.
interface ILpFinalizeResearch {function finalizeRealizationLp(bytes32,address) external;}
library GenesisDistLib {
    event EconomicsRealized(bytes32 indexed poolId, address indexed token, uint256 distributable, uint256 traderShare);
    event ControllerRebateCapped(bytes32 indexed poolId, uint256 returned, uint256 accepted);
    event TraderRebatePaid(bytes32 indexed poolId, address indexed token, uint256 rawAmount);
    event VaultShareTransferred(bytes32 indexed poolId, address indexed token, uint256 rawAmount);
    error Genesis_TransferFailed_DL();
    error Genesis_VaultUnset_DL();

    struct Ctx {
        address controller;
        address outToken;
        uint256 outCcyId;
        address sender;
        address attributedUser;
        uint256 outputRaw;
        uint256 dislocationBps;
        uint256 improvementBps;
        uint256 feePips;
        bool zeroForOne;
        uint256 perSwapBps;
        uint256 feeCapBps;
        uint256 amtCapBps;
        uint256 blockBps;
    }

    /// @notice Size the recapture request in RAW OUTPUT-CURRENCY units.
    /// @dev V4's capture curve applied to the REALIZED output leg. LVR is proportional
    ///      to (size x dislocation) and size is measurable on either leg, so this is the
    ///      same economic quantity expressed directly in the currency that must be paid
    ///      — no price conversion, no oracle in the payout path, no decimal bridge.
    function sizeRequest(Ctx memory x) internal pure returns (uint256 requestOut) {
        if (
            x.outputRaw == 0
                || x.dislocationBps <= 10
                || x.improvementBps == 0
        ) return 0;

        uint256 estimatedLvrOut =
            (x.outputRaw * x.improvementBps) / 10_000;
        if (estimatedLvrOut == 0) return 0;

        uint256 captureBps;
        if (x.dislocationBps >= 350) {
            captureBps = 5_000;
        } else {
            captureBps = 1_000 + ((x.dislocationBps - 10) * 4_000) / 340;
        }
        uint256 feeBps = x.feePips / 100;
        if (feeBps < 30) captureBps += ((30 - feeBps) * 1_000) / 30;
        if (captureBps > 5_000) captureBps = 5_000;

        requestOut = (estimatedLvrOut * captureBps) / 10_000;
        if (requestOut == 0) return 0;

        uint256 feePaidOut = (x.outputRaw * x.feePips) / 1_000_000;
        uint256 feeCap = (feePaidOut * x.feeCapBps) / 10_000;
        uint256 amtCap = (x.outputRaw * x.amtCapBps) / 10_000;
        uint256 cap = feeCap < amtCap ? feeCap : amtCap;
        if (requestOut > cap) requestOut = cap;
    }

    /// @notice Compute D against the hook's RAW backing of the payout currency, accrue
    ///         the controller, and burn caps. REVERTS on any failure — the hook's outer
    ///         try/catch is the single fail-open boundary.
    /// @return d      Total distributable, RAW output-currency units. ALL of it leaves the
    ///                hook: `trader` to the PoolManager, `d - trader` to the vault.
    /// @return trader Trader share, RAW output-currency units, <= d.
    function realize(
        mapping(PoolId => mapping(uint256 => uint256)) storage backingRaw,
        mapping(PoolId => mapping(uint256 => uint256)) storage budgetRaw,
        mapping(PoolId => mapping(uint256 => uint256)) storage drainedRaw,
        mapping(PoolId => mapping(uint256 => uint256)) storage drainBlockOf,
        mapping(PoolId => mapping(uint256 => uint256)) storage snapshotRaw,
        PoolId pid,
        Ctx memory x
    ) public returns (uint256 d, uint256 trader) {
        uint256 requestOut = sizeRequest(x);
        if (requestOut == 0) return (0, 0);

        // ── Cap 1: the hook's RAW physical backing of THIS token.
        //    NO reservedObligations() subtraction — see the custody note above.
        //    Controller obligations are physically held by the VAULT, not the hook;
        //    subtracting them here would double-count every prior distribution and
        //    progressively throttle capacity to zero.
        uint256 backing = backingRaw[pid][x.outCcyId];
        if (backing == 0) return (0, 0);

        // ── Cap 2: per-swap share of this token's backing.
        uint256 perSwapCap = (backing * x.perSwapBps) / 10_000;

        // ── Cap 3: per-block drain of this token (next-block reset).
        if (drainBlockOf[pid][x.outCcyId] != block.number) {
            drainBlockOf[pid][x.outCcyId] = block.number;
            drainedRaw[pid][x.outCcyId] = 0;
            snapshotRaw[pid][x.outCcyId] = backing;
        }
        uint256 drained = drainedRaw[pid][x.outCcyId];
        uint256 maxPerBlock = (snapshotRaw[pid][x.outCcyId] * x.blockBps) / 10_000;
        uint256 remainingBlockCap = maxPerBlock > drained ? maxPerBlock - drained : 0;

        // ── Cap 4: emission budget for this token.
        uint256 budget = budgetRaw[pid][x.outCcyId];

        d = requestOut;
        if (d > backing) d = backing; // physical ceiling
        if (d > perSwapCap) d = perSwapCap;
        if (d > remainingBlockCap) d = remainingBlockCap;
        if (d > budget) d = budget;
        if (d == 0) return (0, 0);

        // ── Controller accrual. A revert here reverts the whole realization unit.
        //    maxTraderPayable == d: the hook's physical cap is the sole authority.
        trader = IGenesisRewardsController(x.controller)
            .onRecapture(
                PoolId.unwrap(pid), x.outToken, x.sender, x.attributedUser, d, d, x.zeroForOne, x.dislocationBps
            );

        // Controller return is never trusted.
        if (trader > d) {
            emit ControllerRebateCapped(PoolId.unwrap(pid), trader, d);
            trader = d;
        }

        // ── Burn caps. Rolled back with everything else if a later step fails.
        drainedRaw[pid][x.outCcyId] = drained + d;
        budgetRaw[pid][x.outCcyId] = budget - d;

        emit EconomicsRealized(PoolId.unwrap(pid), x.outToken, d, trader);
    }

    /// @notice As realize(), but ALSO performs the physical settlement in the same
    ///         library call — the hook keeps zero settlement bytecode. Runs via
    ///         DELEGATECALL so address(this) is the hook; transfers, sync/settle and
    ///         events behave EXACTLY as the former inline block. Reverts freely; the
    ///         hook's outer try/catch is the single fail-open boundary.
    /// @return traderPaid RAW output-currency units actually settled to the trader.
    function realizeAndSettle(
        mapping(PoolId => mapping(uint256 => uint256)) storage backingRaw,
        mapping(PoolId => mapping(uint256 => uint256)) storage budgetRaw,
        mapping(PoolId => mapping(uint256 => uint256)) storage drainedRaw,
        mapping(PoolId => mapping(uint256 => uint256)) storage drainBlockOf,
        mapping(PoolId => mapping(uint256 => uint256)) storage snapshotRaw,
        mapping(uint256 => uint256) storage traderPaidRaw,
        IPoolManager poolManager,
        PoolId pid,
        Currency outCurrency,
        Ctx memory x
    ) public returns (uint256 traderPaid) {
        (uint256 d, uint256 trader) = realize(backingRaw, budgetRaw, drainedRaw, drainBlockOf, snapshotRaw, pid, x);
        if (d == 0) return 0;

        // Physical guard: caps already bound d by backing, but operator fees also
        // sit at the hook address, so re-check the real balance before moving tokens.
        if (IERC20MinimalDL(x.outToken).balanceOf(address(this)) < d) {
            revert Genesis_TransferFailed_DL();
        }

        if (trader > 0) {
            poolManager.sync(outCurrency);
            if (!IERC20MinimalDL(x.outToken).transfer(address(poolManager), trader)) {
                revert Genesis_TransferFailed_DL();
            }
            poolManager.settle();
            traderPaidRaw[x.outCcyId] += trader;
            emit TraderRebatePaid(PoolId.unwrap(pid), x.outToken, trader);
        }

        uint256 toVault = d - trader;
        if (toVault > 0) {
            address vaultAddr = IGenesisRewardsController(x.controller).vault();
            if (vaultAddr == address(0)) revert Genesis_VaultUnset_DL();
            if (!IERC20MinimalDL(x.outToken).transfer(vaultAddr, toVault)) {
                revert Genesis_TransferFailed_DL();
            }
            emit VaultShareTransferred(PoolId.unwrap(pid), x.outToken, toVault);
        }

        ILpFinalizeResearch(x.controller).finalizeRealizationLp(PoolId.unwrap(pid),x.outToken);
        backingRaw[pid][x.outCcyId] -= d;
        traderPaid = trader;
    }
}
