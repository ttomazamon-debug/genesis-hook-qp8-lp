// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {GenesisSplitLib} from "../libraries/GenesisSplitLib.sol";
import {IGenesisRewardsController} from "../interfaces/IGenesisRewardsController.sol";

/// @notice Custody boundary: the vault HOLDS all assets; this controller only
///         LEDGERS claims against it and authorizes payouts.
interface IGenesisVaultV2 {
    /// @notice Pay `amount` of `token` to `to`. Callable only by the controller.
    function pay(address token, address to, uint256 amount) external;
    /// @notice Physical token balance available in the vault.
    function available(address token) external view returns (uint256);
}

/// @notice Minimal PoolManager surface for LP donation (real v4 signatures).
interface IGenesisPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function donate(PoolKey memory key, uint256 amount0, uint256 amount1, bytes calldata hookData)
        external
        returns (BalanceDelta);
    function sync(Currency currency) external;
    function settle() external payable returns (uint256);
}

/// @notice V5 distribution layer. Splits each realized recapture (D, raw payout-
///         currency units) exactly once into trader/LP/protocol/router/keeper
///         shares; pays the trader share immediately via the hook; accrues the
///         non-trader shares in GenesisVaultV2, then funds/indexes the LP share
///         atomically through the bound adapter into its separate claims ledger.
///
/// FAILURE POLICY: capacity shortfalls never revert (trader rebate caps to
/// available, remainder → cappedTraderRemainder reserve). Only misconfiguration
/// reverts (wrong caller, unregistered pool); the hook wraps onRecapture in
/// try/catch so a controller revert degrades to "swap proceeds, no distribution".
///
/// PHASE 3C:
///  - lpEpochThreshold remains a per-token compatibility field only. New LP rewards
///    are indexed at realization; settleLpEpoch always reverts IndexedLpOnly.
///  - The keeper 30-day trailing limiter has been REMOVED: the repository contains no
///    independent economic rate-limit parameter, and the previous window could strand
///    keeper obligations permanently. Keeper withdrawals are now limited only by
///    keeperReserve[token]. This is a deliberate simplification, not a preserved limiter.
///  - Integer-division residue (roundingDust) and unpayable trader remainder
///    (cappedTraderRemainder) are SEPARATE reserved buckets with distinct provenance.
///    Both are fully reserved; neither has a consumption path. The economic ownership
///    of cappedTraderRemainder is intentionally left unresolved pending a future
///    governance-approved policy.
interface ILpFundingResearch {function finalizeReward(address token,uint256 amount) external;}
contract GenesisRewardsController is IGenesisRewardsController {
    address public researchLpBridge;
    event LpRewardIndexed(bytes32 indexed poolId,address indexed token,uint256 amount);
    error IndexedLpOnly();
    function setResearchLpBridge(address bridge) external onlyGovernance {
        require(researchLpBridge==address(0)&&bridge.code.length>0);researchLpBridge=bridge;
    }
    function finalizeRealizationLp(bytes32 poolId,address token) external onlyHook nonReentrant {
        if(poolToken[poolId]!=token&&poolToken1[poolId]!=token)revert PoolNotRegistered(poolId);
        uint256 amount=lpPendingByToken[poolId][token];
        if(amount==0)return;
        require(researchLpBridge!=address(0));
        lpPendingByToken[poolId][token]=0;totalLpPending[token]-=amount;
        _vault.pay(token,researchLpBridge,amount);
        ILpFundingResearch(researchLpBridge).finalizeReward(token,amount);
        emit LpRewardIndexed(poolId,token,amount);
    }

    using SafeERC20 for IERC20;
    using GenesisSplitLib for GenesisSplitLib.SplitBps;

    // ─────────────────────────────────────────────────────────────────────
    // Constants / immutables
    // ─────────────────────────────────────────────────────────────────────

    uint256 public constant TIMELOCK_DELAY = 48 hours;

    // Split bounds: each within ±1000 bps of the 40/25/20/10/5 defaults.
    uint16 public constant TRADER_MIN = 3000;
    uint16 public constant TRADER_MAX = 5000;
    uint16 public constant LP_MIN = 1500;
    uint16 public constant LP_MAX = 3500;
    uint16 public constant PROTOCOL_MIN = 1000;
    uint16 public constant PROTOCOL_MAX = 3000;
    uint16 public constant ROUTER_MIN = 0;
    uint16 public constant ROUTER_MAX = 2000;
    uint16 public constant KEEPER_MIN = 0;
    uint16 public constant KEEPER_MAX = 1500;

    address public immutable governance; // Safe
    IGenesisVaultV2 internal immutable _vault;
    IGenesisPoolManager public immutable poolManager;

    // ─────────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────────

    address public hook; // one-time set
    address public keeper;

    GenesisSplitLib.SplitBps public splitBps; // defaults 4000/2500/2000/1000/500

    /// @notice Legacy per-token LP threshold retained for storage/ABI compatibility.
    /// @dev Neither zero nor a positive value controls indexed LP funding or claims.
    ///      settleLpEpoch is permanently disabled in this architecture.
    mapping(address => uint256) public lpEpochThreshold;

    // Pool registry: poolId → key (verified) and its currency tokens.
    mapping(bytes32 => PoolKey) internal _poolKey;
    mapping(bytes32 => address) public poolToken; // currency0 of registered pool
    mapping(bytes32 => address) public poolToken1; // currency1, for donate-leg selection

    // Ledgers (all raw token units).
    mapping(address => uint256) public protocolRevenue; // token → amount
    mapping(address => mapping(address => uint256)) public routerBalance; // router → token → amount
    mapping(address => uint256) public keeperReserve; // token → amount
    /// @notice Phase 3C: LP obligations are TOKEN-SPECIFIC. A USDC obligation is
    ///         NEVER interchangeable with a WETH one.
    mapping(bytes32 => mapping(address => uint256)) public lpPendingByToken; // poolId → token → raw

    /// @notice Integer-division residue from the 5-way split (≤4 units/event). No
    ///         identifiable economic owner. Fully reserved.
    mapping(address => uint256) public roundingDust; // token → amount
    /// @notice Trader rebate that physical backing could not cover (capTrader). An
    ///         operational under-backing signal. Fully reserved. Economic ownership
    ///         intentionally unresolved pending a future governance-approved policy.
    mapping(address => uint256) public cappedTraderRemainder; // token → amount

    // Aggregates for O(1) reserved-obligation accounting (no iteration).
    mapping(address => uint256) public totalLpPending; // token → sum over pools
    mapping(address => uint256) public totalRouterPending; // token → sum over routers

    mapping(address => bool) public registeredRouter;

    // Timelock: opId → eta (0 = not scheduled).
    mapping(bytes32 => uint256) public operationEta;

    uint256 private _lock = 1;

    // ─────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────

    modifier onlyGovernance() {
        if (msg.sender != governance) revert OnlyGovernance();
        _;
    }
    modifier onlyHook() {
        if (msg.sender != hook) revert OnlyHook();
        _;
    }
    modifier onlyKeeper() {
        if (msg.sender != keeper) revert OnlyKeeper();
        _;
    }
    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlySelf();
        _;
    }
    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────

    constructor(address _governance, address vault_, address _poolManager, address _keeper) {
        if (_governance == address(0) || vault_ == address(0) || _poolManager == address(0) || _keeper == address(0)) {
            revert ZeroAddress();
        }
        governance = _governance;
        _vault = IGenesisVaultV2(vault_);
        poolManager = IGenesisPoolManager(_poolManager);
        keeper = _keeper;
        splitBps = GenesisSplitLib.SplitBps(4000, 2500, 2000, 1000, 500);
        // Legacy LP threshold fields default to zero. Indexed LP attribution and
        // claims do not use these fields or require threshold scheduling.
    }

    // ─────────────────────────────────────────────────────────────────────
    // Hook → Controller: the swap-path entry point
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Physical custody vault used for non-trader economics.
    function vault() external view override returns (address) {
        return address(_vault);
    }

    /// @inheritdoc IGenesisRewardsController
    /// @param token The PAYOUT currency (raw units) — the swap's OUTPUT currency,
    ///        which may be currency0 OR currency1.
    /// @param maxTraderPayable The hook's RAW physical cap. Under Model A custody the
    ///        hook has NOT yet transferred this event's funds to the vault, so the
    ///        hook's _realBackingRaw cap is the SOLE authority.
    function onRecapture(
        bytes32 poolId,
        address token,
        address sender,
        address attributedUser,
        uint256 recaptured,
        uint256 maxTraderPayable,
        bool zeroForOne,
        uint256 dislocationBps
    ) external onlyHook returns (uint256 traderRebate) {
        if (token == address(0)) revert ZeroAddress();
        if (poolToken[poolId] != token && poolToken1[poolId] != token) revert PoolNotRegistered(poolId);
        if (recaptured == 0) return 0;

        // 1. Split exactly once. `s.dust` here is pure integer-division residue.
        GenesisSplitLib.Shares memory s = GenesisSplitLib.split(recaptured, splitBps);
        uint256 divisionResidue = s.dust;

        // 2. Attribution: router share paid only for registered-router-attributed
        //    flow; otherwise folded into the LP share (attribution = router revenue).
        bool attributed = attributedUser != address(0) && registeredRouter[sender];
        if (!attributed) {
            s = GenesisSplitLib.foldRouterIntoLp(s);
        }

        // 3. Cap the trader rebate against the hook's RAW physical allowance. capTrader
        //    ADDS the unpayable remainder into s.dust; the delta above the pre-cap
        //    residue is the cappedTraderRemainder (distinct provenance, tracked apart).
        s = GenesisSplitLib.capTrader(s, maxTraderPayable);
        uint256 traderRemainder = s.dust - divisionResidue; // >= 0 by capTrader semantics

        // 4. Accrue ledgers (effects before the hook performs the actual rebate).
        lpPendingByToken[poolId][token] += s.lp;
        totalLpPending[token] += s.lp;
        protocolRevenue[token] += s.protocol;
        if (s.router > 0) {
            routerBalance[sender][token] += s.router;
            totalRouterPending[token] += s.router;
        }
        keeperReserve[token] += s.keeper;
        roundingDust[token] += divisionResidue;
        cappedTraderRemainder[token] += traderRemainder;

        emit EconomicsRealized(
            poolId,
            sender,
            attributed ? attributedUser : address(0),
            token,
            recaptured,
            s.trader,
            s.lp,
            s.protocol,
            s.router,
            s.keeper,
            divisionResidue, // integer-division rounding residue only
            traderRemainder, // trader rebate physical backing could not cover
            dislocationBps,
            zeroForOne
        );

        return s.trader;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Reserved obligations that protocol withdrawals may never touch.
    /// @dev protocolRevenue is intentionally NOT reserved: it is a withdrawal right
    ///      gated against surplus at withdrawal time. Both residue buckets ARE reserved.
    function reservedObligations(address token) public view returns (uint256) {
        return totalLpPending[token] + totalRouterPending[token] + keeperReserve[token] + roundingDust[token]
            + cappedTraderRemainder[token];
    }

    function poolKeyOf(bytes32 poolId) external view returns (PoolKey memory) {
        return _poolKey[poolId];
    }

    /// @notice Remaining keeper withdrawal capacity.
    /// @dev The previous 30-day keeper limiter has been removed because the repository
    ///      contains no independent economic rate-limit parameter. Keeper withdrawals
    ///      are now limited only by keeperReserve[token].
    function keeperRemainingCap(address token) public view returns (uint256) {
        return keeperReserve[token];
    }

    // ─────────────────────────────────────────────────────────────────────
    // Withdrawals
    // ─────────────────────────────────────────────────────────────────────

    /// @inheritdoc IGenesisRewardsController
    function withdrawProtocolRevenue(address token, address to, uint256 amount) external onlyGovernance nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 rev = protocolRevenue[token];
        if (amount > rev) revert InsufficientBalance(amount, rev);

        uint256 reserved = reservedObligations(token);
        uint256 avail = _vault.available(token);
        uint256 surplus = avail > reserved ? avail - reserved : 0;
        if (amount > surplus) revert InsufficientSurplus(amount, surplus);

        protocolRevenue[token] = rev - amount;
        _vault.pay(token, to, amount);
        emit ProtocolRevenueWithdrawn(token, to, amount);
    }

    /// @inheritdoc IGenesisRewardsController
    function withdrawRouterReward(address token, address to, uint256 amount) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        // Deregistration preserves earned balances: no registeredRouter check here.
        uint256 bal = routerBalance[msg.sender][token];
        if (amount > bal) revert InsufficientBalance(amount, bal);

        routerBalance[msg.sender][token] = bal - amount;
        totalRouterPending[token] -= amount;
        _vault.pay(token, to, amount);
        emit RouterRewardWithdrawn(msg.sender, token, to, amount);
    }

    /// @inheritdoc IGenesisRewardsController
    /// @dev Limited only by keeperReserve[token] (the 30-day limiter was removed).
    function withdrawKeeperFunds(address token, address to, uint256 amount) external onlyKeeper nonReentrant {
        if (to == address(0)) revert ZeroAddress();

        uint256 res = keeperReserve[token];
        if (amount > res) revert InsufficientBalance(amount, res);

        keeperReserve[token] = res - amount;
        _vault.pay(token, to, amount);
        emit KeeperFundsWithdrawn(msg.sender, token, to, amount);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Disabled legacy LP epoch entry point and retained callback ABI
    // ─────────────────────────────────────────────────────────────────────

    /// @inheritdoc IGenesisRewardsController
    /// @notice Legacy LP epoch settlement is disabled for every caller and threshold.
    /// @dev Indexed LP rewards are funded in finalizeRealizationLp; users claim
    ///      from the adapter ledger. No keeper donation is required.
    function settleLpEpoch(bytes32,address) external pure {revert IndexedLpOnly();}

    /// @notice Retained legacy callback, restricted to the immutable PoolManager.
    /// @dev The disabled settleLpEpoch entry point no longer initiates an unlock.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();

        (bytes32 poolId, address token, bool isCurrency0, uint256 amount) =
            abi.decode(data, (bytes32, address, bool, uint256));
        PoolKey memory key = _poolKey[poolId];

        if (isCurrency0) {
            poolManager.donate(key, amount, 0, "");
            poolManager.sync(key.currency0);
        } else {
            poolManager.donate(key, 0, amount, "");
            poolManager.sync(key.currency1);
        }

        IERC20(token).safeTransfer(address(poolManager), amount);
        poolManager.settle();

        return "";
    }

    function setHook(address _hook) external onlyGovernance {
        if (_hook == address(0)) revert ZeroAddress();
        if (hook != address(0)) revert HookAlreadySet();
        hook = _hook;
        emit HookSet(_hook);
    }

    /// @inheritdoc IGenesisRewardsController
    function registerPool(bytes32 poolId, PoolKey calldata key) external onlyGovernance {
        bytes32 computed = keccak256(abi.encode(key));
        if (computed != poolId) revert PoolIdMismatch(poolId, computed);
        _poolKey[poolId] = key;
        poolToken[poolId] = Currency.unwrap(key.currency0);
        poolToken1[poolId] = Currency.unwrap(key.currency1);
        emit PoolRegistered(poolId, Currency.unwrap(key.currency0));
    }

    /// @inheritdoc IGenesisRewardsController
    function setRouterRegistered(address router, bool ok) external onlyGovernance {
        if (router == address(0)) revert ZeroAddress();
        registeredRouter[router] = ok;
        emit RouterRegistered(router, ok);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Timelocked governance (48h) — schedule / execute / cancel self-calls
    // ─────────────────────────────────────────────────────────────────────

    /// @inheritdoc IGenesisRewardsController
    function scheduleOperation(bytes calldata data) external onlyGovernance returns (bytes32 opId, uint256 eta) {
        opId = keccak256(data);
        if (operationEta[opId] != 0) revert OperationAlreadyScheduled(opId);
        eta = block.timestamp + TIMELOCK_DELAY;
        operationEta[opId] = eta;
        emit GovernanceOperationScheduled(opId, data, eta);
    }

    /// @inheritdoc IGenesisRewardsController
    function executeOperation(bytes calldata data) external onlyGovernance {
        bytes32 opId = keccak256(data);
        uint256 eta = operationEta[opId];
        if (eta == 0) revert OperationNotScheduled(opId);
        if (block.timestamp < eta) revert OperationNotReady(opId, eta);

        delete operationEta[opId]; // replay prevention before the call

        (bool ok, bytes memory ret) = address(this).call(data);
        if (!ok) {
            // Bubble the inner revert reason.
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        emit GovernanceOperationExecuted(opId);
    }

    /// @inheritdoc IGenesisRewardsController
    function cancelOperation(bytes calldata data) external onlyGovernance {
        bytes32 opId = keccak256(data);
        if (operationEta[opId] == 0) revert OperationNotScheduled(opId);
        delete operationEta[opId];
        emit GovernanceOperationCancelled(opId);
    }

    /// @inheritdoc IGenesisRewardsController
    function setSplitDirect(uint16 trader, uint16 lp, uint16 protocol_, uint16 router, uint16 keeper_)
        external
        onlySelf
    {
        if (
            trader < TRADER_MIN || trader > TRADER_MAX || lp < LP_MIN || lp > LP_MAX || protocol_ < PROTOCOL_MIN
                || protocol_ > PROTOCOL_MAX || router > ROUTER_MAX || keeper_ > KEEPER_MAX
        ) revert SplitOutOfBounds();
        GenesisSplitLib.SplitBps memory s = GenesisSplitLib.SplitBps(trader, lp, protocol_, router, keeper_);
        GenesisSplitLib.validate(s); // must sum to exactly 10_000
        splitBps = s;
        emit SplitChanged(trader, lp, protocol_, router, keeper_);
    }

    /// @inheritdoc IGenesisRewardsController
    function setKeeperDirect(address newKeeper) external onlySelf {
        if (newKeeper == address(0)) revert ZeroAddress();
        address old = keeper;
        keeper = newKeeper; // old keeper loses withdrawal authority immediately
        emit KeeperChanged(old, newKeeper);
    }

    /// @inheritdoc IGenesisRewardsController
    /// @notice Update a legacy compatibility field through the existing timelock.
    /// @dev This does not enable settleLpEpoch or change indexed LP funding/claims.
    function setLpEpochThresholdDirect(address token, uint256 amount) external onlySelf {
        if (token == address(0)) revert ZeroAddress();
        uint256 old = lpEpochThreshold[token];
        lpEpochThreshold[token] = amount;
        emit LpThresholdChanged(token, old, amount);
    }
}
