// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @title IGenesisRewardsController (v3 — Phase 3C corrected interface)
/// @notice Boundary between the immutable GenesisHookV5 and the replaceable
///         distribution layer.
///
/// PHASE 3C INTERFACE CORRECTIONS vs Phase 2:
///  1. lpEpochThreshold is a legacy token-specific compatibility field.
///     Indexed LP rewards are funded at realization into the adapter claims ledger.
///     This implementation permanently rejects the old settleLpEpoch entry point.
///  2. The keeper 30-day trailing limiter has been REMOVED. The repository contains
///     no independent economic rate-limit parameter, so the previous window could
///     strand keeper obligations permanently (accruals aged out of the window while
///     keeperReserve retained them). Keeper withdrawals are now limited only by
///     keeperReserve[token]. This is a deliberate simplification, not a preserved
///     velocity limiter.
///  3. The former single `safetyReserve` bucket is split into two reserved buckets
///     with distinct provenance: `roundingDust` (integer-division residue, ≤4 units
///     per event, no identifiable owner) and `cappedTraderRemainder` (trader rebate
///     that could not be paid because physical backing was insufficient — an
///     operational under-backing signal). Both remain fully reserved inside
///     reservedObligations; neither has a consumption path. The economic ownership
///     of cappedTraderRemainder is intentionally left unresolved pending a future
///     governance-approved policy.
///  4. Denomination is explicit: `recaptured` and every ledger are RAW token units
///     of the payout currency (currency0 OR currency1 of the registered pool).
interface IGenesisRewardsController {
    // ─────────────────────────────────────────────────────────────────────
    // Hook → Controller (the only swap-path call)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Report realized corrective recapture; receive the trader rebate
    ///         the hook must pay in-swap via afterSwapReturnDelta.
    /// @param poolId           Raw v4 pool id (must be registered).
    /// @param sender           PoolManager callback sender (router/EntryPoint).
    /// @param attributedUser   Beneficiary decoded by the hook's trusted-router
    ///                         hookData path, or address(0) if unattributed.
    /// @param recaptured       D — raw payout-currency token units.
    /// @param maxTraderPayable Hook-side allowance for the in-swap rebate
    ///                         (raw physical backing cap), same units.
    /// @param zeroForOne       Swap direction.
    /// @param dislocationBps   For analytics/events.
    /// @return traderRebate    Final immediately-payable rebate (≤ maxTraderPayable),
    ///                         raw payout-currency units. Never deferred.
    function onRecapture(
        bytes32 poolId,
        address token,
        address sender,
        address attributedUser,
        uint256 recaptured,
        uint256 maxTraderPayable,
        bool zeroForOne,
        uint256 dislocationBps
    ) external returns (uint256 traderRebate);

    // ─────────────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────────────

    function protocolRevenue(address token) external view returns (uint256);
    function routerBalance(address router, address token) external view returns (uint256);
    function keeperReserve(address token) external view returns (uint256);
    function lpPendingByToken(bytes32 poolId, address token) external view returns (uint256);

    /// @notice Vault for the controller non-LP obligations.
    /// @dev Non-trader shares first reach this vault in the atomic realization unit;
    ///      the LP share is then funded into the separate adapter claims ledger.
    function vault() external view returns (address);

    /// @notice Reserved integer-division residue (≤4 units/event; no identifiable owner).
    function roundingDust(address token) external view returns (uint256);

    /// @notice Reserved trader-rebate remainder that physical backing could not cover.
    /// @dev Economic ownership intentionally left unresolved: funds remain fully
    ///      reserved until a future governance-approved policy defines their lifecycle.
    function cappedTraderRemainder(address token) external view returns (uint256);

    function reservedObligations(address token) external view returns (uint256);
    function keeper() external view returns (address);
    function registeredRouter(address router) external view returns (bool);

    /// @notice Legacy per-token threshold; does not control indexed LP rewards.
    function lpEpochThreshold(address token) external view returns (uint256);

    // ─────────────────────────────────────────────────────────────────────
    // Withdrawals / settlement (pull-based, evented)
    // ─────────────────────────────────────────────────────────────────────

    function withdrawProtocolRevenue(address token, address to, uint256 amount) external;
    function withdrawRouterReward(address token, address to, uint256 amount) external;
    function withdrawKeeperFunds(address token, address to, uint256 amount) external;

    /// @notice Legacy entry point; indexed-LP controllers always revert IndexedLpOnly.
    /// @dev LP claims are requested from the separate LP claims ledger, not here.
    function settleLpEpoch(bytes32 poolId, address token) external;

    // ─────────────────────────────────────────────────────────────────────
    // Configuration
    // ─────────────────────────────────────────────────────────────────────

    /// @notice One-time hook binding (governance).
    function setHook(address hook) external;

    /// @notice Register a pool; verifies keccak256(abi.encode(key)) == poolId.
    function registerPool(bytes32 poolId, PoolKey calldata key) external;

    /// @notice Immediate governance (justified: enables only future accrual,
    ///         cannot touch existing balances; integration speed matters).
    function setRouterRegistered(address router, bool ok) external;

    // ─────────────────────────────────────────────────────────────────────
    // Timelocked governance (48h): setSplit / setKeeper / setLpEpochThreshold
    // via generic schedule/execute/cancel self-call pattern.
    // ─────────────────────────────────────────────────────────────────────

    function scheduleOperation(bytes calldata data) external returns (bytes32 opId, uint256 eta);
    function executeOperation(bytes calldata data) external;
    function cancelOperation(bytes calldata data) external;

    // Timelock-only direct setters (callable only by the contract itself):
    function setSplitDirect(uint16 trader, uint16 lp, uint16 protocol_, uint16 router, uint16 keeper_) external;
    function setKeeperDirect(address newKeeper) external;
    function setLpEpochThresholdDirect(address token, uint256 amount) external;

    // ─────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────

    event EconomicsRealized(
        bytes32 indexed poolId,
        address indexed sender,
        address indexed beneficiary, // address(0) = unattributed
        address token,
        uint256 grossValue,
        uint256 traderShare,
        uint256 lpShare,
        uint256 protocolShare,
        uint256 routerShare,
        uint256 keeperShare,
        uint256 roundingDust,
        uint256 cappedTraderRemainder,
        uint256 dislocationBps,
        bool zeroForOne
    );
    event LpRewardDonated(bytes32 indexed poolId, address indexed token, uint256 amount);
    event ProtocolRevenueWithdrawn(address indexed token, address indexed to, uint256 amount);
    event RouterRewardWithdrawn(address indexed router, address indexed token, address to, uint256 amount);
    event KeeperFundsWithdrawn(address indexed keeper, address indexed token, address to, uint256 amount);
    event RouterRegistered(address indexed router, bool ok);
    event KeeperChanged(address indexed oldKeeper, address indexed newKeeper);
    event SplitChanged(uint16 trader, uint16 lp, uint16 protocol_, uint16 router, uint16 keeper_);
    event LpThresholdChanged(address indexed token, uint256 oldThreshold, uint256 newThreshold);
    event PoolRegistered(bytes32 indexed poolId, address indexed currency0);
    event HookSet(address indexed hook);
    event GovernanceOperationScheduled(bytes32 indexed opId, bytes data, uint256 eta);
    event GovernanceOperationExecuted(bytes32 indexed opId);
    event GovernanceOperationCancelled(bytes32 indexed opId);

    // ─────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────

    error OnlyHook();
    error OnlyGovernance();
    error OnlyKeeper();
    error OnlySelf();
    error OnlyPoolManager();
    error HookAlreadySet();
    error PoolNotRegistered(bytes32 poolId);
    error PoolIdMismatch(bytes32 expected, bytes32 computed);
    error ZeroAddress();
    error InsufficientBalance(uint256 requested, uint256 available);
    error InsufficientSurplus(uint256 requested, uint256 surplus);
    error EpochBelowThreshold(uint256 accrued, uint256 threshold);
    error OperationNotScheduled(bytes32 opId);
    error OperationNotReady(bytes32 opId, uint256 eta);
    error OperationAlreadyScheduled(bytes32 opId);
    error SplitOutOfBounds();
    error Reentrancy();
    error NothingPending();
    error LpSettlementDisabled();
}
