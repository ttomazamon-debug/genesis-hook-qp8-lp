// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {IGenesisSystem, IGenesisClaimVault} from "src/interfaces/IGenesisSystem.sol";
import {FlowLib} from "src/libraries/FlowLib.sol";
import {OracleLib} from "src/libraries/OracleLib.sol";
import {AmpLib} from "src/libraries/AmpLib.sol";
import {FeeEngineV2Lib} from "src/libraries/FeeEngineV2Lib.sol";
import {IGenesisV52Oracle} from "../interfaces/IGenesisV52Oracle.sol";
import {IGenesisRewardsController} from "src/interfaces/IGenesisRewardsController.sol";
import {GenesisDistLib} from "src/libraries/GenesisDistLib.sol";

interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
}

// LP release candidate: exact-input native swaps with executed-input fee scaling.
// Preserve the full-fill gross budget; scale reserved input fees on partial fills.
// LP rewards use the bound native trace adapter and a separately funded claims ledger.
// Existing ABI names retain historical Research/Prototype spelling.
// Fresh deployment required: position storage holds an unlock deadline, not an add block.
interface IResearchLpBridge {
 function beforeAddLiquidity(address,PoolKey calldata,IPoolManager.ModifyLiquidityParams calldata,bytes calldata) external returns(bytes4);
 function beforeRemoveLiquidity(address,PoolKey calldata,IPoolManager.ModifyLiquidityParams calldata,bytes calldata) external returns(bytes4);
 function captureBefore(PoolKey calldata,IPoolManager.SwapParams calldata,uint24,bool) external;
 function finishEmpty(PoolKey calldata,bool) external;
}
contract GenesisHookV5 is IGenesisSystem, IHooks {
    address public researchLpBridge;
    function setResearchLpBridge(address bridge) external onlyOperator {
        require(researchLpBridge==address(0)&&bridge.code.length>0);researchLpBridge=bridge;
    }
    // The bridge requests a hook-self, reverted native probe; callbacks are skipped by core.
    function researchLpProbe(PoolKey calldata key,IPoolManager.SwapParams calldata params,uint24 fee) external {
        require(msg.sender==researchLpBridge);
        if((key.fee & uint24(0x800000))!=0)poolManager.updateDynamicLPFee(key,fee);
        poolManager.swap(key,params,"");(,int24 tick,,)=poolManager.getSlot0(key.toId());
        revert ResearchLpEndTick(tick);
    }
    error ResearchLpEndTick(int24 tick);

    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;

    uint256 internal constant FLOW_DECAY_BPS_PER_BLOCK = 9_900;

    uint24 internal constant DYNAMIC_FEE_FLAG = 0x400000;
    uint24 internal constant MAX_LP_FEE_PIPS = 1_000_000;

    uint256 internal constant EXECUTION_BONUS_MICRO_SHARE_BPS = 2_000;
    uint256 internal constant EXECUTION_BONUS_BASE_SHARE_BPS = 1_000;

    uint256 internal constant ROFR_MAX_FEE_BPS = 30;
    uint256 internal constant ROFR_MAX_RECAPTURE_TO_FEE_BPS = 5_000;
    uint256 internal constant ROFR_MAX_RECAPTURE_TO_AMOUNT_BPS = 25;
    uint256 internal constant EXECUTION_IMPROVEMENT_MAX_SHARE_BPS = 200;

    IPoolManager public immutable poolManager;
    IGenesisV52Oracle public immutable v52Oracle;

    address public operator;
    address public pendingOperator;
    bool public paused;

    mapping(PoolId => PoolConfig) internal _poolConfigs;
    mapping(PoolId => RiskConfig) internal _riskConfigs;
    mapping(PoolId => FlowLib.FlowState) internal _flowStates;
    mapping(PoolId => OracleLib.OracleState) internal _oracleStates;

    // New deployments only: immutable-at-deposit unlock deadline, not an add block.
    mapping(bytes32 => uint256) internal _positionUnlockBlock;
    mapping(PoolId => uint8) internal _currency0Decimals;
    mapping(PoolId => uint8) internal _currency1Decimals;
    mapping(PoolId => uint256) internal _poolCurrency0Ids;
    mapping(PoolId => bool) internal _poolCurrency0IsNative;

    mapping(PoolId => uint256) internal _vaultBalances;

    // SYNTH-MINIMAL-DELETED: _vaultSyntheticBalances (write-only dead state, Phase 3C size opt v3)
    mapping(PoolId => uint256) internal _vaultRealBalances;

    mapping(PoolId => uint256) internal _creditEmissionBudgets;

    // ── Phase 3C: per-currency RAW physical backing (pid => currencyId => raw) ──
    // The ONLY payout gate. Never normalized, never aggregated across currencies.
    // Legacy _vaultRealBalances / totalRealVaultBalance are unit-mixed (measured
    // 3,361x inflated on Base mainnet, block 48617989) and are ANALYTICS ONLY.
    mapping(PoolId => mapping(uint256 => uint256)) internal _realBackingRaw;
    mapping(PoolId => mapping(uint256 => uint256)) internal _emissionBudgetRaw;
    mapping(PoolId => mapping(uint256 => uint256)) internal _drainedRaw;
    mapping(PoolId => mapping(uint256 => uint256)) internal _drainBlockRaw;
    mapping(PoolId => mapping(uint256 => uint256)) internal _snapshotRaw;

    /// @dev Cumulative trader payouts per token — conservation-invariant analytics.
    mapping(uint256 => uint256) public traderPaidRaw;
    /// @dev Cumulative surcharge collected per token — conservation-invariant analytics.
    mapping(uint256 => uint256) public surchargeCollectedRaw;

    uint256 private _realizing = 1; // reentrancy guard for the realization unit

    mapping(PoolId => uint256) internal _vaultDrainedThisBlock;
    mapping(PoolId => uint256) internal _vaultDrainBlock;
    mapping(PoolId => uint256) internal _vaultSnapshotAtDrainBlock;

    uint256 internal constant VAULT_MAX_DRAIN_PER_BLOCK_BPS = 500; // 5%
    uint256 internal constant ORACLE_STALE_BLOCKS = 10;

    uint256 public totalVaultBalance;
    uint256 public totalRealVaultBalance;
    uint256 public totalRofrRecapture;
    mapping(PoolId => uint256) internal _bonusMicroThreshold;
    mapping(PoolId => uint256) internal _bonusMaxThreshold;

    mapping(address => bool) public trustedCreditRouters;
    uint256 public totalProtocolFees;
    uint16 public operatorFeePips = 50;
    uint16 internal constant OPERATOR_FEE_PIPS_MAX = 1_000;
    mapping(uint256 => uint256) public operatorFeeAccruedByCurrency;

    // ── V5 rewards distribution (Phase 3B) ─────────────────────────────
    // _creditEmissionBudgets / _vaultDrain* are retained from V4 under their
    // original names and now bound the REAL-BACKED distributable value D.
    // Raw synthetic ROFR is never distributed (source-audit Finding 1).
    IGenesisRewardsController public rewardsController;
    /// @notice The ONLY address permitted to change the rewards controller.
    ///         MUST be the GenesisControllerGovernor (48h timelock, Safe-owned).
    ///         Immutable: no instant operator replacement, anti-V6 preserved.
    address public immutable controllerGovernor;
    bool public rewardsEnabled; // default false: armed explicitly post-binding

    // ── Phase V5.1 additions ─────────────────────────────────────────────────
    /// @notice Address authorised to call updateOracleHeartbeat(). Set by operator.
    ///         Set to address(0) to disable heartbeat capability.
    address public oracleKeeper;
    /// @notice Current staleness threshold in blocks. Replaces the former
    ///         compile-time constant ORACLE_STALE_BLOCKS = 10.
    ///         Bounded: [10, 120]. Operator-controlled.
    uint256 public oracleStalenessBlocks = 10;
    /// @notice Last block in which updateOracleHeartbeat() was successfully
    ///         executed. Enforces one heartbeat per block (all pools share limit).
    uint256 private _lastHeartbeatBlock;

    // Direction-isolated flow pressure used for fee computation.
    // Legacy _flowStates remains aggregate observability state.
    mapping(PoolId => FlowLib.FlowState) internal _flowStatesZeroForOne;
    mapping(PoolId => FlowLib.FlowState) internal _flowStatesOneForZero;

    // External fair value is used ONLY for ROFR validation.
    mapping(PoolId => address) internal _fairValueSource;

    struct FairValueCache {
        uint256 fairValueX96;
        uint64 updatedAt;
    }

    mapping(PoolId => FairValueCache) internal _fairValueCache;
    uint64 internal constant FAIR_VALUE_CACHE_MAX_AGE_SECONDS = 60;

    // ─────────────────────────────────────────────────────────────────────────

    event RofrRecaptured(bytes32 indexed poolId, address indexed user, uint256 amount, uint256 dislocationBps);
    event TrustedCreditRouterSet(address indexed router, bool trusted);
    event RewardsControllerChanged(address indexed oldController, address indexed newController);
    event RewardsEnabledChanged(bool enabled);
    event BackingFunded(bytes32 indexed poolId, address indexed token, uint256 rawAmount);
    event OracleKeeperUpdated(address indexed newKeeper);
    event OracleHeartbeat(bytes32 indexed poolId, uint160 sqrtPriceX96, uint256 blockNumber);
    event TraderRebatePaid(bytes32 indexed poolId, address indexed token, uint256 rawAmount);
    event VaultShareTransferred(bytes32 indexed poolId, address indexed token, uint256 rawAmount);
    event EconomicsRealizationFailed(bytes32 indexed poolId, bytes4 reasonSelector);

    error Genesis_MissingSwapSnapshot();
    error Genesis_Paused();
    error Genesis_InvalidBonusThreshold();
    error Genesis_InvalidDecimals();
    error Genesis_VaultBalanceNotBacked();
    error Genesis_VaultCannotSettle();
    error Genesis_VaultUnderfunded();
    error Genesis_ExactOutputUnsupported();
    error Genesis_NormalizationOverflow();
    error Genesis_DenormalizationOverflow();
    error Genesis_PoolCurrencyNotRegistered();
    error Genesis_UntrustedAttributor();
    error Genesis_MonetizationCapExceeded();
    error Genesis_TransferFailed();
    error Genesis_OnlySelf();
    error Genesis_RealizationReentrancy();
    error Genesis_VaultUnset();
    error Genesis_HeartbeatAlreadyThisBlock();
    error Genesis_HeartbeatPriceMoved();
    error Genesis_HeartbeatPoolNotInitialized();

    modifier onlyOperator() {
        if (msg.sender != operator) revert Genesis_Unauthorized();
        _;
    }

    modifier notPaused() {
        if (paused) revert Genesis_Paused();
        _;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert Genesis_Unauthorized();
        _;
    }

    constructor(
        IPoolManager _poolManager,
        address _operator,
        address _controllerGovernor,
        address _v52Oracle
    ) {
        if (address(_poolManager) == address(0)) revert Genesis_ZeroAddress();
        if (_operator == address(0)) revert Genesis_ZeroAddress();
        if (_controllerGovernor == address(0)) revert Genesis_ZeroAddress();
        if (_v52Oracle == address(0)) revert Genesis_ZeroAddress();

        controllerGovernor = _controllerGovernor;
        poolManager = _poolManager;
        operator = _operator;
        v52Oracle = IGenesisV52Oracle(_v52Oracle);
    }

    function proposeOperator(address newOperator) external onlyOperator {
        if (newOperator == address(0)) revert Genesis_ZeroAddress();
        pendingOperator = newOperator;
    }

    function acceptOperator() external {
        if (msg.sender != pendingOperator) revert Genesis_Unauthorized();
        operator = pendingOperator;
        pendingOperator = address(0);
    }

    function setPaused(bool value) external onlyOperator {
        paused = value;
    }

    function setOperatorFeePips(uint16 newOperatorFeePips) external onlyOperator {
        if (newOperatorFeePips > OPERATOR_FEE_PIPS_MAX) revert Genesis_MonetizationCapExceeded();
        operatorFeePips = newOperatorFeePips;
    }

    function _currencyIdFor(Currency currency) internal pure returns (uint256) {
        return Currency.unwrap(currency) == address(0) ? 1 : uint256(uint160(Currency.unwrap(currency)));
    }

    function withdrawOperatorFees(Currency currency, address to) external onlyOperator returns (uint256 amount) {
        if (to == address(0)) revert Genesis_ZeroAddress();

        uint256 currencyId = _currencyIdFor(currency);
        amount = operatorFeeAccruedByCurrency[currencyId];
        operatorFeeAccruedByCurrency[currencyId] = 0;

        if (amount > 0) {
            bool ok = IERC20Minimal(Currency.unwrap(currency)).transfer(to, amount);
            if (!ok) revert Genesis_TransferFailed();
        }
    }

    function setTrustedCreditRouter(address router, bool trusted) external onlyOperator {
        if (router == address(0)) revert Genesis_ZeroAddress();

        trustedCreditRouters[router] = trusted;

        emit TrustedCreditRouterSet(router, trusted);
    }

    function setPoolFairValueSource(
        PoolKey calldata key,
        address source
    ) external onlyOperator {
        PoolId pid = key.toId();
        _fairValueSource[pid] = source;
        delete _fairValueCache[pid];
    }

    function configurePool(PoolKey calldata key, PoolConfig calldata cfg) external onlyOperator {
        if (cfg.vault == address(0)) revert Genesis_InvalidConfig();
        if (cfg.oracleWeightBps > 10_000) revert Genesis_InvalidConfig();
        if (cfg.flowCoefficient == 0) revert Genesis_InvalidConfig();
        if (cfg.dislocationCoefficient == 0) revert Genesis_InvalidConfig();
        if (cfg.ampFactorBps < 10_000) revert Genesis_InvalidConfig();
        if (cfg.minHoldBlocks == 0) revert Genesis_InvalidConfig();

        PoolId pid = key.toId();
        _poolConfigs[pid] = cfg;
        address currency0Address = Currency.unwrap(key.currency0);
        _poolCurrency0IsNative[pid] = currency0Address == address(0);
        _poolCurrency0Ids[pid] = _poolCurrency0IsNative[pid] ? 1 : uint256(uint160(currency0Address));

        emit PoolConfigured(PoolId.unwrap(pid), cfg);
    }

    function setPoolBonusThresholds(PoolKey calldata key, uint256 microThreshold, uint256 maxThreshold)
        external
        onlyOperator
    {
        if (microThreshold == 0) revert Genesis_InvalidBonusThreshold();
        if (maxThreshold < microThreshold) revert Genesis_InvalidBonusThreshold();

        PoolId pid = key.toId();
        _bonusMicroThreshold[pid] = microThreshold;
        _bonusMaxThreshold[pid] = maxThreshold;
    }

    function setPoolCurrencyDecimals(PoolKey calldata key, uint8 currency0Decimals_, uint8 currency1Decimals_)
        external
        onlyOperator
    {
        if (currency0Decimals_ < 2 || currency0Decimals_ > 18) revert Genesis_InvalidDecimals();
        if (currency1Decimals_ < 2 || currency1Decimals_ > 18) revert Genesis_InvalidDecimals();

        PoolId pid = key.toId();
        _currency0Decimals[pid] = currency0Decimals_;
        _currency1Decimals[pid] = currency1Decimals_;
    }

    function getPoolConfig(PoolId pid) external view returns (PoolConfig memory) {
        return _poolConfigs[pid];
    }

    function setPoolRiskConfig(PoolKey calldata key, RiskConfig calldata cfg) external onlyOperator {
        if (cfg.executionImprovementMaxShareBps == 0 || cfg.executionImprovementMaxShareBps > 1_000) {
            revert Genesis_InvalidConfig();
        }
        if (cfg.rofrMaxRecaptureToFeeBps == 0 || cfg.rofrMaxRecaptureToFeeBps > 10_000) {
            revert Genesis_InvalidConfig();
        }
        if (cfg.rofrMaxRecaptureToAmountBps == 0 || cfg.rofrMaxRecaptureToAmountBps > 1_000) {
            revert Genesis_InvalidConfig();
        }

        PoolId pid = key.toId();
        _riskConfigs[pid] = cfg;

        emit PoolRiskConfigured(PoolId.unwrap(pid), cfg);
    }

    function getFlowState(PoolId pid) external view returns (FlowLib.FlowState memory) {
        return _flowStates[pid];
    }

    function getOracleState(PoolId pid) external view returns (OracleLib.OracleState memory) {
        return _oracleStates[pid];
    }

    /// @param depthHint Effective virtual reserve in raw currency0 units; zero estimates it from the pool.
    function previewSwapFee(PoolKey calldata key, uint256 amountIn, uint256 depthHint, bool zeroForOne)
        external
        view
        returns (uint24)
    {
        return _previewSwapFee(key.toId(), amountIn, depthHint, zeroForOne);
    }

    function vaultBalance(PoolId pid) external view returns (uint256) {
        return _vaultBalances[pid];
    }

    function realVaultBalance(PoolId pid) external view returns (uint256) {
        return _vaultRealBalances[pid];
    }

    function externalVaultBalanceNormalized(PoolKey calldata key) external view returns (uint256) {
        return _externalVaultBalanceNormalized(key.toId());
    }

    function registerVaultFunding(PoolKey calldata key, uint256 normalizedAmount) external onlyOperator notPaused {
        PoolId pid = key.toId();

        if (normalizedAmount == 0) revert Genesis_InvalidAmount();

        uint256 externalBacking = _externalVaultBalanceNormalized(pid);
        if (externalBacking < _vaultRealBalances[pid] + normalizedAmount) revert Genesis_VaultBalanceNotBacked();

        _fundVaultAccounting(pid, normalizedAmount);
    }

    function _positionKey(
        address owner,
        PoolId pid,
        IPoolManager.ModifyLiquidityParams calldata params
    ) internal pure returns (bytes32) {
        // Exact original 160-byte ABI preimage; signed ticks/address cleaned.
        bytes32 result;
        bytes32 rawPid = PoolId.unwrap(pid);
        int24 lower = params.tickLower;
        int24 upper = params.tickUpper;
        bytes32 salt = params.salt;
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, and(owner, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(p, 0x20), rawPid)
            mstore(add(p, 0x40), signextend(2, lower))
            mstore(add(p, 0x60), signextend(2, upper))
            mstore(add(p, 0x80), salt)
            result := keccak256(p, 0xa0)
        }
        return result;
    }

    function _isExactInput(int256 amountSpecified) internal pure returns (bool) {
        if (amountSpecified == type(int256).min) revert Genesis_InvalidAmount();
        return amountSpecified < 0;
    }

    function _requireExactInput(int256 amountSpecified) internal pure returns (uint256 amountIn) {
        if (!_isExactInput(amountSpecified)) revert Genesis_ExactOutputUnsupported();
        amountIn = uint256(-amountSpecified);
    }

    function _absAmountSpecified(int256 amountSpecified) internal pure returns (uint256) {
        if (amountSpecified == type(int256).min) revert Genesis_InvalidAmount();
        return amountSpecified >= 0 ? uint256(amountSpecified) : uint256(-amountSpecified);
    }

    function _currentSpotPriceX96(OracleLib.OracleState memory o) internal pure returns (uint256) {
        return o.twapPriceX96_0 == 0 ? o.emaPriceX96 : o.twapPriceX96_0;
    }

    function _actualSpotPriceX96(PoolId pid, OracleLib.OracleState memory o) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(pid);
        return sqrtPriceX96 == 0 ? _currentSpotPriceX96(o) : uint256(sqrtPriceX96);
    }

    function _estimatedDepth(PoolId pid, uint160 sqrtPriceX96) internal view returns (uint256) {
        PoolConfig memory cfg = _poolConfigs[pid];
        OracleLib.OracleState memory o = _oracleStates[pid];
        uint256 ref = OracleLib.referencePriceX96(o);

        uint128 liq = poolManager.getLiquidity(pid);

        if (liq == 0 || sqrtPriceX96 == 0) return 1;

        uint256 virtualReserve0 = FullMath.mulDiv(uint256(liq), uint256(1) << 96, uint256(sqrtPriceX96));

        uint256 effectiveLiq =
            AmpLib.effectiveLiquidity(virtualReserve0, _currentSpotPriceX96(o), ref, cfg.ampBandBps, cfg.ampFactorBps);

        return effectiveLiq == 0 ? 1 : effectiveLiq;
    }

    function _realVaultBalanceForPool(PoolId pid) internal view returns (uint256) {
        return _vaultRealBalances[pid];
    }

    function _claimableBackingForPool(PoolId pid) internal view returns (uint256) {
        return _realVaultBalanceForPool(pid);
    }

    function _riskConfigOrDefault(PoolId pid) internal view returns (RiskConfig memory cfg) {
        cfg = _riskConfigs[pid];

        if (cfg.executionImprovementMaxShareBps == 0) {
            cfg.executionImprovementMaxShareBps = uint16(EXECUTION_IMPROVEMENT_MAX_SHARE_BPS);
        }
        if (cfg.rofrMaxRecaptureToFeeBps == 0) {
            cfg.rofrMaxRecaptureToFeeBps = uint16(ROFR_MAX_RECAPTURE_TO_FEE_BPS);
        }
        if (cfg.rofrMaxRecaptureToAmountBps == 0) {
            cfg.rofrMaxRecaptureToAmountBps = uint16(ROFR_MAX_RECAPTURE_TO_AMOUNT_BPS);
        }
    }

    function _currencyDecimalsForDirection(PoolId pid, bool zeroForOne) internal view returns (uint8 decimals_) {
        decimals_ = zeroForOne ? _currency0Decimals[pid] : _currency1Decimals[pid];
        return decimals_ == 0 ? 18 : decimals_;
    }

    function _normalizedAmountIn(PoolId pid, uint256 amountIn, bool zeroForOne) internal view returns (uint256) {
        uint8 decimals_ = _currencyDecimalsForDirection(pid, zeroForOne);
        if (decimals_ == 18) return amountIn;

        if (decimals_ < 18) {
            uint256 scale = 10 ** uint256(18 - decimals_);
            if (amountIn > type(uint256).max / scale) revert Genesis_NormalizationOverflow();
            return amountIn * scale;
        }

        return amountIn / (10 ** uint256(decimals_ - 18));
    }

    function _valueNormalizedAmountIn(
        PoolId pid,
        uint256 amountIn,
        bool zeroForOne,
        uint160 sqrtPriceX96
    ) internal view returns (uint256) {
        if (zeroForOne) return _normalizedAmountIn(pid, amountIn, true);
        if (sqrtPriceX96 == 0) return 0;

        uint256 sp = uint256(sqrtPriceX96);
        uint256 intermediate =
            FullMath.mulDiv(amountIn, uint256(1) << 96, sp);
        uint256 rawCurrency0 =
            FullMath.mulDiv(intermediate, uint256(1) << 96, sp);

        return _normalizedAmountIn(pid, rawCurrency0, true);
    }

    function _denormalizeAmountOut(PoolId pid, uint256 normalizedAmount, bool zeroForOne)
        internal
        view
        returns (uint256)
    {
        uint8 decimals_ = _currencyDecimalsForDirection(pid, zeroForOne);
        if (decimals_ == 18) return normalizedAmount;

        if (decimals_ < 18) {
            return normalizedAmount / (10 ** uint256(18 - decimals_));
        }

        uint256 scale = 10 ** uint256(decimals_ - 18);
        if (normalizedAmount > type(uint256).max / scale) revert Genesis_DenormalizationOverflow();
        return normalizedAmount * scale;
    }

    function _externalVaultBalanceNormalized(PoolId pid) internal view returns (uint256 normalizedBalance) {
        PoolConfig memory cfg = _poolConfigs[pid];
        if (cfg.vault == address(0) || cfg.vault.code.length == 0) return 0;

        uint256 currencyId = _poolCurrency0Id(pid);

        try IGenesisClaimVault(cfg.vault).tokenBalance(currencyId) returns (uint256 rawBalance) {
            normalizedBalance = _normalizedAmountIn(pid, rawBalance, true);
        } catch {
            normalizedBalance = 0;
        }
    }

    function _poolCurrency0Id(PoolId pid) internal view returns (uint256 currencyId) {
        currencyId = _poolCurrency0Ids[pid];
        if (currencyId == 0) revert Genesis_PoolCurrencyNotRegistered();
    }

    function _previewSwapFee(PoolId pid, uint256 amountIn, uint256 depthHint, bool zeroForOne)
        internal
        view
        returns (uint24)
    {
        PoolConfig memory cfg = _poolConfigs[pid];
        FlowLib.FlowState memory fs =
            zeroForOne ? _flowStatesZeroForOne[pid] : _flowStatesOneForZero[pid];
        OracleLib.OracleState memory o = _oracleStates[pid];

        uint256 spot = _actualSpotPriceX96(pid, o);
        uint256 normalizedAmountIn =
            _valueNormalizedAmountIn(pid, amountIn, zeroForOne, uint160(spot));
        uint256 ref = OracleLib.referencePriceX96(o);
        uint256 normalizedDepth = depthHint == 0 ? _estimatedDepth(pid, uint160(spot)) : depthHint;
        // Fee inputs and depth must both use 18-decimal currency0 value units.
        normalizedDepth = _normalizedAmountIn(pid, normalizedDepth, true);

        uint256 accumulator =
            FlowLib.updateAccumulator(fs, block.number, normalizedAmountIn, FLOW_DECAY_BPS_PER_BLOCK, normalizedDepth);

        return FeeEngineV2Lib.computeFeePips(
            FeeEngineV2Lib.FeeInputs({
                baseFeePips: cfg.baseFee,
                amountIn: normalizedAmountIn,
                depth: normalizedDepth,
                flowAccumulator: accumulator,
                spotPriceX96: spot,
                referencePriceX96: ref,
                zeroForOne: zeroForOne,
                minDepth: 10 ether,
                directionalPenaltyCoefficient: 8_000,
                directionalConvexCoefficient: 500,
                directionalDiscountCoefficient: 6_000,
                directionalDiscountMaxPips: 1_000,
                directionalNoiseBps: 5,
                impactThresholdBps: 30,
                impactCoefficient: uint256(cfg.flowCoefficient) / IMPACT_DAMPENING_DIVISOR,
                flowCoefficient: uint256(cfg.flowCoefficient),
                dislocationThresholdBps: 10,
                dislocationCoefficient: uint256(cfg.dislocationCoefficient),
                correctiveDiscountMaxBps: 5_000,
                maxFeePips: 20_000
            })
        );
    }

    function _encodeDynamicFee(uint24 feePips) internal pure returns (uint24) {
        if (feePips > MAX_LP_FEE_PIPS) feePips = MAX_LP_FEE_PIPS;
        return feePips | DYNAMIC_FEE_FLAG;
    }

    function _cachedExternalFairValueX96(PoolId pid)
        internal
        returns (bool valid, uint256 fairValueX96)
    {
        FairValueCache memory cached = _fairValueCache[pid];

        if (
            cached.fairValueX96 != 0
                && block.timestamp >= uint256(cached.updatedAt)
                && block.timestamp - uint256(cached.updatedAt)
                    <= FAIR_VALUE_CACHE_MAX_AGE_SECONDS
        ) {
            return (true, cached.fairValueX96);
        }

        (bool ok, uint256 fresh) = _externalFairValueX96(pid);
        if (!ok || fresh == 0) return (false, 0);

        _fairValueCache[pid] =
            FairValueCache(fresh, uint64(block.timestamp));

        return (true, fresh);
    }

    function _externalFairValueX96(PoolId pid)
        internal
        view
        returns (bool valid, uint256 fairValueX96)
    {
        address source = _fairValueSource[pid];
        if (source == address(0)) return (false, 0);
        return _safeFairValue(source);
    }

    function _safeFairValue(address source)
        private
        view
        returns (bool, uint256)
    {
        address oracle = address(v52Oracle);
        bytes4 sel = IGenesisV52Oracle.fairValueX96.selector;

        uint256 okFlag;
        uint256 validWord;
        uint256 fv;

        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, sel)
            mstore(add(p, 0x04), source)

            if iszero(iszero(extcodesize(oracle))) {
                if staticcall(gas(), oracle, p, 0x24, p, 0x40) {
                    if eq(returndatasize(), 0x40) {
                        okFlag := 1
                        validWord := mload(p)
                        fv := mload(add(p, 0x20))
                    }
                }
            }
        }

        if (okFlag == 0 || validWord == 0 || fv == 0) {
            return (false, 0);
        }

        return (true, fv);
    }

    // Exactly the 64-byte encoding of abi.encodePacked(bytes32,uint256).
    // Only Solidity's 0x00..0x3f scratch area is used; free-memory pointer and
    // zero slot are untouched. No slot prefix, field width or index changes.
    function _transientSlotFromBase(bytes32 base, uint256 index) internal pure returns (bytes32 slot) {
        assembly ("memory-safe") {
            mstore(0, base)
            mstore(0x20, index)
            slot := keccak256(0, 0x40)
        }
    }

    // Internal keccak preimage construction ONLY, not external-call calldata.
    // ABI(string,bytes32,uint256): 96-byte head + length + padded string.
    // Both labels are fixed <=32-byte literals at the callers below.
    // Memory from the free-memory pointer is temporary and does not escape.
    function _transientTaggedPidNonceSlot(
        PoolId pid, uint256 nonce, bytes32 tag, uint256 tagLength, uint256 headSize
    ) internal pure returns (bytes32 slot) {
        // Callers supply 0x40 for ABI(string,bytes32), 0x60 when nonce is included.
        // Internal hash preimage only; no external-call encoding changes.
        bytes32 rawPid = PoolId.unwrap(pid);
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, headSize)
            mstore(add(p, 0x20), rawPid)
            mstore(add(p, 0x40), nonce)
            // For the nonce-free layout this replaces the unused nonce word.
            mstore(add(p, headSize), tagLength)
            mstore(add(add(p, headSize), 0x20), tag)
            slot := keccak256(p, add(headSize, 0x40))
        }
    }

    // Original queue layouts are ABI(string,bytes32,address,int256,bool)
    // and ABI(string,bytes32,address,int256,bool,uint256), respectively.
    // Prefix, width, signed amount and field order remain unchanged.
    function _transientQueueTaggedSlot(
        PoolId pid, address sender, int256 amountSpecified, bool zeroForOne,
        uint256 index, bool withIndex
    ) internal pure returns (bytes32 slot) {
        bytes32 rawPid = PoolId.unwrap(pid);
        uint256 headSize = withIndex ? 0xc0 : 0xa0;
        bytes32 tag = withIndex ? bytes32("GENESIS_SWAP_QUEUE_ITEM_V1") : bytes32("GENESIS_SWAP_QUEUE_V1");
        uint256 tagLength = withIndex ? 26 : 21;
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, headSize)
            mstore(add(p, 0x20), rawPid)
            mstore(add(p, 0x40), and(sender, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(p, 0x60), amountSpecified)
            mstore(add(p, 0x80), iszero(iszero(zeroForOne)))
            // In the base layout the length word below replaces this unused
            // index word. In the item layout this is the original index field.
            mstore(add(p, 0xa0), index)
            mstore(add(p, headSize), tagLength)
            mstore(add(add(p, headSize), 0x20), tag)
            slot := keccak256(p, add(headSize, 0x40))
        }
    }

    function _transientPoolNonceSlot(PoolId pid) internal pure returns (bytes32 slot) {
        return _transientTaggedPidNonceSlot(pid, 0, bytes32("GENESIS_SWAP_NONCE_V1"), 21, 0x40);
    }

    function _transientQueueBaseSlot(PoolId pid, address sender, int256 amountSpecified, bool zeroForOne)
        internal pure returns (bytes32)
    {
        return _transientQueueTaggedSlot(pid, sender, amountSpecified, zeroForOne, 0, false);
    }

    function _transientQueueHeadSlot(PoolId pid, address sender, int256 amountSpecified, bool zeroForOne)
        internal
        pure
        returns (bytes32)
    {
        return
            _transientSlotFromBase(_transientQueueBaseSlot(pid, sender, amountSpecified, zeroForOne), 1);
    }

    function _transientQueueTailSlot(PoolId pid, address sender, int256 amountSpecified, bool zeroForOne)
        internal
        pure
        returns (bytes32)
    {
        return
            _transientSlotFromBase(_transientQueueBaseSlot(pid, sender, amountSpecified, zeroForOne), 2);
    }

    function _transientQueueItemSlot(PoolId pid, address sender, int256 amountSpecified, bool zeroForOne, uint256 index)
        internal pure returns (bytes32)
    {
        return _transientQueueTaggedSlot(pid, sender, amountSpecified, zeroForOne, index, true);
    }

    function _transientSnapshotBaseSlot(PoolId pid, uint256 nonce) internal pure returns (bytes32) {
        return _transientTaggedPidNonceSlot(pid, nonce, bytes32("GENESIS_SWAP_SNAPSHOT_V4"), 24, 0x60);
    }

    function _transientOperatorFeeSlot(PoolId pid, uint256 nonce) internal pure returns (bytes32) {
        return _transientTaggedPidNonceSlot(pid, nonce, bytes32("genesis.opfee.v1"), 16, 0x60);
    }

    function _storeTransientOperatorFee(PoolId pid, uint256 nonce, uint256 operatorFeeRaw) internal {
        bytes32 slot = _transientOperatorFeeSlot(pid, nonce);
        assembly {
            tstore(slot, operatorFeeRaw)
        }
    }

    function _loadAndClearTransientOperatorFee(PoolId pid, uint256 nonce) internal returns (uint256 operatorFeeRaw) {
        bytes32 slot = _transientOperatorFeeSlot(pid, nonce);
        assembly {
            operatorFeeRaw := tload(slot)
            tstore(slot, 0)
        }
    }

    function _transientFeeSlot(PoolId pid, uint256 nonce) internal pure returns (bytes32) {
        return _transientSlotFromBase(_transientSnapshotBaseSlot(pid, nonce), 1);
    }

    function _transientCorrectiveSlot(PoolId pid, uint256 nonce) internal pure returns (bytes32) {
        return _transientSlotFromBase(_transientSnapshotBaseSlot(pid, nonce), 2);
    }

    function _transientSurchargeSlot(PoolId pid, uint256 nonce) internal pure returns (bytes32) {
        return _transientSlotFromBase(_transientSnapshotBaseSlot(pid, nonce), 5);
    }

    function _transientRawSurchargeSlot(PoolId pid, uint256 nonce) internal pure returns (bytes32) {
        return _transientSlotFromBase(_transientSnapshotBaseSlot(pid, nonce), 6);
    }

    function _transientRofrSlot(
        PoolId pid,
        uint256 nonce,
        uint256 index
    ) internal pure returns (bytes32) {
        return _transientSlotFromBase(_transientSnapshotBaseSlot(pid, nonce), index);
    }

    function _snapshotRofrPreSwap(
        PoolId pid,
        uint256 nonce,
        uint160 sqrtPriceX96,
        bool zeroForOne
    ) internal returns(bool mayReward) {
        (bool valid, uint256 fairValue) =
            _cachedExternalFairValueX96(pid);

        if (!valid || fairValue == 0) return false;

        uint256 spotPre = uint256(sqrtPriceX96);

        // Same V5.2 threshold, but dislocationPre does not need
        // its own transient slot; it can be recomputed post-swap
        // from these exact same pre-swap values.
        if (OracleLib.dislocationBps(spotPre, fairValue) <= 10) {
            return false;
        }

        bytes32 snapshotBase = _transientSnapshotBaseSlot(pid, nonce);
        bytes32 spotSlot = _transientSlotFromBase(snapshotBase, 8);
        bytes32 fairSlot = _transientSlotFromBase(snapshotBase, 9);

        assembly ("memory-safe") {
            tstore(spotSlot, spotPre)
            tstore(fairSlot, fairValue)
        }
        // Necessary condition from the EXACT pinned values consumed after swap.
        // Does not predict realized size, budgets or whether rewards stay enabled.
        return OracleLib.isCorrectiveDirection(spotPre,fairValue,zeroForOne);
    }

    function _consumeRofrSnapshot(
        PoolId pid,
        uint256 nonce,
        bool zeroForOne
    )
        internal
        returns (
            uint256 spotPre,
            uint256 dislocationPre,
            uint256 improvementBps
        )
    {
        bytes32 snapshotBase = _transientSnapshotBaseSlot(pid, nonce);
        bytes32 spotSlot = _transientSlotFromBase(snapshotBase, 8);
        bytes32 fairSlot = _transientSlotFromBase(snapshotBase, 9);

        uint256 fairValue;

        assembly ("memory-safe") {
            spotPre := tload(spotSlot)
            fairValue := tload(fairSlot)

            tstore(spotSlot, 0)
            tstore(fairSlot, 0)
        }

        if (
            spotPre == 0
                || fairValue == 0
                || !OracleLib.isCorrectiveDirection(
                    spotPre,
                    fairValue,
                    zeroForOne
                )
        ) {
            return (spotPre, 0, 0);
        }

        dislocationPre =
            OracleLib.dislocationBps(
                spotPre,
                fairValue
            );

        OracleLib.OracleState memory postOracle =
            _oracleStates[pid];

        uint256 spotPost =
            _actualSpotPriceX96(pid, postOracle);

        uint256 dislocationPost =
            OracleLib.dislocationBps(
                spotPost,
                fairValue
            );

        if (dislocationPost >= dislocationPre) {
            return (spotPre, dislocationPre, 0);
        }

        improvementBps =
            dislocationPre - dislocationPost;
    }

    function _storeTransientSwapSnapshot(
        PoolId pid,
        address sender,
        int256 amountSpecified,
        bool zeroForOne,
        uint24 feePips,
        bool corrective,
        uint256 normalizedSurcharge,
        uint256 rawSurcharge
    ) internal returns (uint256 nonce) {
        bytes32 nonceSlot = _transientPoolNonceSlot(pid);

        assembly {
            nonce := add(tload(nonceSlot), 1)
            tstore(nonceSlot, nonce)
        }

        bytes32 tailSlot = _transientQueueTailSlot(pid, sender, amountSpecified, zeroForOne);
        uint256 tail;

        assembly {
            tail := add(tload(tailSlot), 1)
            tstore(tailSlot, tail)
        }

        bytes32 queueItemSlot = _transientQueueItemSlot(pid, sender, amountSpecified, zeroForOne, tail);

        bytes32 snapshotBase = _transientSnapshotBaseSlot(pid, nonce);
        // Same keccak(base,index) fields, in the original write order.
        // Scratch 0x00..0x3f only, exactly as _transientSlotFromBase.
        assembly ("memory-safe") {
            tstore(queueItemSlot, nonce)
            mstore(0, snapshotBase)
            mstore(0x20, 1)
            tstore(keccak256(0, 0x40), feePips)
            mstore(0x20, 2)
            tstore(keccak256(0, 0x40), add(1, iszero(corrective)))
            mstore(0x20, 5)
            tstore(keccak256(0, 0x40), normalizedSurcharge)
            mstore(0x20, 6)
            tstore(keccak256(0, 0x40), rawSurcharge)
        }
    }

    function _loadAndClearTransientSwapSnapshot(PoolId pid, address sender, int256 amountSpecified, bool zeroForOne)
        internal
        returns (
            uint24 feePips,
            bool corrective,
            uint256 normalizedSurcharge,
            uint256 rawSurcharge,
            bool hasSnapshot,
            uint256 nonce
        )
    {
        bytes32 queueBase = _transientQueueBaseSlot(pid, sender, amountSpecified, zeroForOne);
        bytes32 headSlot = _transientSlotFromBase(queueBase, 1);
        bytes32 tailSlot = _transientSlotFromBase(queueBase, 2);

        uint256 head;
        uint256 tail;

        assembly {
            head := tload(headSlot)
            tail := tload(tailSlot)
        }

        if (head >= tail) {
            return (0, false, 0, 0, false, 0);
        }

        uint256 nextHead = head + 1;
        bytes32 queueItemSlot = _transientQueueItemSlot(pid, sender, amountSpecified, zeroForOne, nextHead);

        assembly {
            nonce := tload(queueItemSlot)
            tstore(queueItemSlot, 0)
            tstore(headSlot, nextHead)
        }

        if (nonce == 0) {
            return (0, false, 0, 0, false, 0);
        }

        bytes32 snapshotBase = _transientSnapshotBaseSlot(pid, nonce);
        uint256 correctiveValue;
        // All four loads precede all four clears, preserving the original order.
        // Nonce allocation, queue heads/tails and the 1/2 sentinel are unchanged.
        assembly ("memory-safe") {
            mstore(0, snapshotBase)
            mstore(0x20, 1)
            let feeSlot := keccak256(0, 0x40)
            mstore(0x20, 2)
            let correctiveSlot := keccak256(0, 0x40)
            mstore(0x20, 5)
            let surchargeSlot := keccak256(0, 0x40)
            mstore(0x20, 6)
            let rawSurchargeSlot := keccak256(0, 0x40)
            feePips := tload(feeSlot)
            correctiveValue := tload(correctiveSlot)
            normalizedSurcharge := tload(surchargeSlot)
            rawSurcharge := tload(rawSurchargeSlot)
            tstore(feeSlot, 0)
            tstore(correctiveSlot, 0)
            tstore(surchargeSlot, 0)
            tstore(rawSurchargeSlot, 0)
        }

        hasSnapshot = feePips != 0 && correctiveValue != 0;
        corrective = correctiveValue == 1;
    }

    function _beneficiaryFromHookData(address sender, bytes calldata hookData)
        internal
        view
        returns (address beneficiary)
    {
        if (hookData.length == 0) return sender;

        address decoded;

        if (hookData.length == 20) {
            assembly {
                decoded := shr(96, calldataload(hookData.offset))
            }
        } else if (hookData.length == 32) {
            decoded = abi.decode(hookData, (address));
        } else {
            return sender;
        }

        if (decoded == address(0) || decoded == sender) return sender;

        if (!trustedCreditRouters[sender]) revert Genesis_UntrustedAttributor();

        return decoded;
    }

    // Both ledger entries use the same checked FlowLib calculation and field order.
    // Storage references select the original mapping entry; no new state is added.
    function _recordExecutedFlow(FlowLib.FlowState storage state, uint256 normalizedAmountIn, uint256 depth)
        internal
    {
        state.accumulator = FlowLib.updateAccumulator(
            state, block.number, normalizedAmountIn, FLOW_DECAY_BPS_PER_BLOCK, depth
        );
        state.lastBlock = block.number;
    }

    function _updateAfterSwap(PoolId pid, uint256 amountIn, bool zeroForOne) internal {
        FlowLib.FlowState storage directionalFs =
            zeroForOne ? _flowStatesZeroForOne[pid] : _flowStatesOneForZero[pid];
        OracleLib.OracleState memory o = _oracleStates[pid];
        uint16 oracleWeight = _poolConfigs[pid].oracleWeightBps;
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(pid);
        uint256 depth = _normalizedAmountIn(pid, _estimatedDepth(pid, sqrtPriceX96), true);
        uint256 normalizedAmountIn =
            _valueNormalizedAmountIn(pid, amountIn, zeroForOne, sqrtPriceX96);
        _recordExecutedFlow(directionalFs, normalizedAmountIn, depth);
        _recordExecutedFlow(_flowStates[pid], normalizedAmountIn, depth);
        _oracleStates[pid] = OracleLib.update(
            o, uint256(sqrtPriceX96), block.number,
            oracleWeight == 0 ? 1000 : oracleWeight
        );
    }

    /// @notice Phase 3C: credit RAW physical backing in the surcharge's OWN currency.
    /// @dev No decimal normalization, no cross-currency aggregation. The only payout gate.
    function _fundBackingRaw(PoolId pid, Currency currency, uint256 rawAmount) internal {
        if (rawAmount == 0) return;
        uint256 ccyId = _currencyIdFor(currency);
        _realBackingRaw[pid][ccyId] += rawAmount;
        _emissionBudgetRaw[pid][ccyId] += rawAmount;
        surchargeCollectedRaw[ccyId] += rawAmount;
        emit BackingFunded(PoolId.unwrap(pid), Currency.unwrap(currency), rawAmount);
    }

    function realBackingRaw(PoolKey calldata key, Currency currency) external view returns (uint256) {
        return _realBackingRaw[key.toId()][_currencyIdFor(currency)];
    }

    function emissionBudgetRaw(PoolKey calldata key, Currency currency) external view returns (uint256) {
        return _emissionBudgetRaw[key.toId()][_currencyIdFor(currency)];
    }

    /// @dev ANALYTICS ONLY as of Phase 3C. Unit-mixed: decimal-normalizes surcharges
    ///      from BOTH currencies into one accumulator, so 1 USDC == 1 WETH here.
    ///      MUST NOT gate payouts or solvency. See _realBackingRaw.
    function _fundVaultAccounting(PoolId pid, uint256 amount) internal {
        if (amount == 0) return;

        _vaultRealBalances[pid] += amount;
        _vaultBalances[pid] += amount;
        totalRealVaultBalance += amount;
        totalVaultBalance += amount;

        // Self-funding guard:
        // credits can only be issued from an explicit real-vault-backed emission budget.
        _creditEmissionBudgets[pid] += amount;
    }

    function _toxicSurcharge(
        PoolKey calldata key,
        PoolId pid,
        uint256 amountIn,
        uint256 feePips,
        bool corrective,
        bool zeroForOne
    ) internal view returns (Currency specifiedCurrency, uint256 rawSurcharge, uint256 normalizedSurcharge) {
        specifiedCurrency = zeroForOne ? key.currency0 : key.currency1;

        corrective;

        PoolConfig memory cfg = _poolConfigs[pid];
        OracleLib.OracleState memory o = _oracleStates[pid];

        uint256 spot = _actualSpotPriceX96(pid, o);
        uint256 ref = OracleLib.referencePriceX96(o);
        uint256 dislocationBps = OracleLib.dislocationBps(spot, ref);

        if (dislocationBps <= 10 || feePips <= cfg.baseFee) return (specifiedCurrency, 0, 0);

        uint256 surchargePips = feePips - cfg.baseFee;
        rawSurcharge = (amountIn * surchargePips) / 1_000_000;
        normalizedSurcharge =
            _valueNormalizedAmountIn(pid, rawSurcharge, zeroForOne, uint160(spot));
    }

    // ── V5 rewards controller governance (Phase 3B) ────────────────────

    /// @notice One-time initial binding. Replacement afterwards requires the 48h timelock.
    // ── V5 rewards controller governance (Phase 3B, size-optimized) ────
    // The 48h delay lives in GenesisControllerGovernor, not in hook bytecode.
    // controllerGovernor is immutable: the operator can NEVER swap the
    // controller instantly, and the controller remains replaceable (anti-V6).

    /// @notice Set/replace/unbind the rewards controller. Governor-only.
    /// @param next The new controller. address(0) is the explicit unbind path.
    function setRewardsController(address next) external {
        if (msg.sender != controllerGovernor) revert Genesis_Unauthorized();
        address old = address(rewardsController);
        rewardsController = IGenesisRewardsController(next);
        emit RewardsControllerChanged(old, next);
    }

    /// @notice Immediate operator toggle: enables or disables new reward realization.
    ///         This toggle does not change the bound controller or reward recipients.
    ///         Controller replacement requires the immutable governor.
    ///         Disabling rewards does not prevent claims of existing LP escrow.
    function setRewardsEnabled(bool enabled) external onlyOperator {
        rewardsEnabled = enabled;
        emit RewardsEnabledChanged(enabled);
    }

    /// @notice Set the address authorised to call updateOracleHeartbeat().
    ///         Operator-only. Set to address(0) to disable heartbeat.
    /// @param  newKeeper  EOA or contract that will send heartbeat transactions.
    function setOracleKeeper(address newKeeper) external onlyOperator {
        oracleKeeper = newKeeper;
        emit OracleKeeperUpdated(newKeeper);
    }

    /// @notice Set the oracle staleness threshold in blocks. Operator-only.
    ///         Hard bounds: minimum 10, maximum 120.
    /// @param  newValue  New staleness threshold in blocks.
    function setOracleStalenessBlocks(uint256 newValue) external onlyOperator {
        if (newValue < 10 || newValue > 120) revert Genesis_InvalidConfig();
        oracleStalenessBlocks = newValue;
    }

    // ── V5 real-backed distribution (Phase 3B, size-optimized) ─────────
    // Cap stack, decimal bridges, controller call, return validation and
    // fail-open handling all live in GenesisDistLib (external linked library,
    // DELEGATECALL -> hook storage context, events emitted from the hook's
    // address). Semantics are byte-for-byte identical to the inline version;
    // only the code location changed. Library address is link-time immutable.

    /// @notice ATOMIC ECONOMICS REALIZATION UNIT (Phase 3C).
    ///
    /// @dev Called ONLY by this contract via `this.realizeEconomics(...)`, so a revert
    ///      anywhere inside rolls back EVERY state change below — controller
    ///      obligations, cap burn, budget burn, transfers, backing decrement — while
    ///      afterSwap's try/catch absorbs it and the swap completes with zero delta.
    ///      This is the ONLY fail-open boundary; GenesisDistLib no longer catches.
    ///
    ///      CUSTODY (Model A): the FULL D leaves the hook here.
    ///        trader      -> PoolManager (settled; negative unspecified delta)
    ///        D - trader  -> controller's vault (lp+protocol+router+keeper+dust)
    ///      Backing is therefore decremented by D, not by the trader share, so no
    ///      token is ever both hook trader-backing and controller-reserved backing.
    function realizeEconomics(
        PoolId pid,
        PoolKey calldata key,
        address sender,
        address user,
        uint256 outputRaw,
        uint24 feePips,
        bool zeroForOne,
        uint256 dislocationBps,
        uint256 improvementBps
    ) external returns (uint256 traderPaid) {
        if (msg.sender != address(this)) revert Genesis_OnlySelf();

        // CIRCUIT BREAKER AT THE ATOMIC BOUNDARY (defence in depth).
        // The afterSwap call site also gates on these, but the breaker must bind
        // where value PHYSICALLY MOVES so that no present or future internal
        // self-call path can bypass it. The operator may disable or re-enable
        // realization, but cannot use this toggle to change rewardsController.
        // Only the timelocked governor may replace that controller.
        // Also short-circuits an unbound controller,
        // which would otherwise call a codeless address and revert into the
        // try/catch with a misleading EconomicsRealizationFailed event.
        //
        // Placed BEFORE the reentrancy guard is armed so the early return cannot
        // leave _realizing stuck at 2.
        if (!rewardsEnabled || address(rewardsController) == address(0)) return 0;

        if (_realizing != 1) revert Genesis_RealizationReentrancy();
        _realizing = 2;

        address ctl = address(rewardsController);
        Currency outCurrency = zeroForOne ? key.currency1 : key.currency0;
        uint256 outCcyId = _currencyIdFor(outCurrency);
        address token = Currency.unwrap(outCurrency);
        RiskConfig memory risk = _riskConfigOrDefault(pid);

        // Cap stack + controller accrual + cap/budget burn + physical settlement,
        // all inside GenesisDistLib (delegatecall -> hook storage context). The
        // settlement block is no longer in the hook's bytecode (size optimization).
        traderPaid = GenesisDistLib.realizeAndSettle(
            _realBackingRaw,
            _emissionBudgetRaw,
            _drainedRaw,
            _drainBlockRaw,
            _snapshotRaw,
            traderPaidRaw,
            poolManager,
            pid,
            outCurrency,
            GenesisDistLib.Ctx({
                controller: ctl,
                outToken: token,
                outCcyId: outCcyId,
                sender: sender,
                attributedUser: user == sender ? address(0) : user,
                outputRaw: outputRaw,
                dislocationBps: dislocationBps,
                improvementBps: improvementBps,
                feePips: uint256(feePips),
                zeroForOne: zeroForOne,
                perSwapBps: risk.executionImprovementMaxShareBps,
                feeCapBps: risk.rofrMaxRecaptureToFeeBps,
                amtCapBps: risk.rofrMaxRecaptureToAmountBps,
                blockBps: VAULT_MAX_DRAIN_PER_BLOCK_BPS
            })
        );

        _realizing = 1;
    }

    function _fundVaultFromRofrRecapture(
        PoolId pid,
        address user,
        uint256 amountIn,
        uint256 feePips,
        bool zeroForOne,
        uint256 dislocationBps,
        uint256 improvementBps,
        uint256 spotPre
    )
        internal
        returns (uint256 recaptured)
    {
        if (
            dislocationBps <= 10
                || improvementBps == 0
                || amountIn == 0
                || spotPre == 0
        ) {
            return 0;
        }

        uint256 feeBps = feePips / 100;

        uint256 normalizedAmountIn =
            _valueNormalizedAmountIn(
                pid,
                amountIn,
                zeroForOne,
                uint160(spotPre)
            );

        uint256 estimatedLvr =
            (normalizedAmountIn * improvementBps)
                / 10_000;

        if (estimatedLvr == 0) return 0;

        uint256 captureBps;

        if (dislocationBps >= 350) {
            captureBps = 5_000;
        } else {
            captureBps =
                1_000
                    + (
                        (dislocationBps - 10)
                            * 4_000
                    )
                    / 340;
        }

        if (feeBps < 30) {
            captureBps +=
                ((30 - feeBps) * 1_000) / 30;
        }

        if (captureBps > 5_000) {
            captureBps = 5_000;
        }

        recaptured =
            (estimatedLvr * captureBps) / 10_000;

        if (recaptured == 0) return 0;

        uint256 feePaid =
            (normalizedAmountIn * feePips)
                / 1_000_000;

        RiskConfig memory risk =
            _riskConfigOrDefault(pid);

        uint256 feeBackedCap =
            (
                feePaid
                    * risk.rofrMaxRecaptureToFeeBps
            ) / 10_000;

        uint256 amountCap =
            (
                normalizedAmountIn
                    * risk.rofrMaxRecaptureToAmountBps
            ) / 10_000;

        uint256 cap =
            feeBackedCap < amountCap
                ? feeBackedCap
                : amountCap;

        if (recaptured > cap) recaptured = cap;
        if (recaptured == 0) return 0;

        _vaultBalances[pid] += recaptured;
        totalVaultBalance += recaptured;
        totalRofrRecapture += recaptured;

        emit RofrRecaptured(
            PoolId.unwrap(pid),
            user,
            recaptured,
            dislocationBps
        );
    }

    /// @notice Refresh the pool oracle using current pool price without a swap.
    ///         Keeps oracle.lastBlock current so subsequent external corrective
    ///         swaps pass the staleness gate in _isCorrectiveSwap.
    ///
    /// Security properties:
    ///   keeper-only        Prevents attacker from calling after their own
    ///                      manipulative swap to encode a distorted price.
    ///   one-per-block      At most one heartbeat per block, all pools.
    ///   spot-movement gate Refuses sqrtPriceX96 movement over 2 % from EMA.
    ///                      This is a sqrt-price bound (about 4 % in token price),
    ///                      not a general economic manipulation-proof guarantee.
    ///   same OracleLib.update as afterSwap (EMA and recent per-block samples).
    ///   sample semantics   Internal twap fields are recent samples, not a timed TWAP.
    ///                      The external v3 reader supplies the separate timed TWAP.
    ///   no economics       No corrective flag, no vault writes, no ROFR emitted.
    ///   notPaused          Disabled when hook is paused.
    ///   Gas ~45,000 vs ~200,000+ for a dust swap.
    ///
    /// @param key  PoolKey of the target pool (must be active Genesis pool).
    function updateOracleHeartbeat(PoolKey calldata key) external notPaused {
        // Access control
        if (msg.sender != oracleKeeper) revert Genesis_Unauthorized();

        // One heartbeat per block, shared across all pools
        if (block.number == _lastHeartbeatBlock) revert Genesis_HeartbeatAlreadyThisBlock();

        // Pool must be configured
        PoolId pid = key.toId();
        PoolConfig memory cfg = _poolConfigs[pid];
        if (cfg.baseFee == 0) revert Genesis_InvalidConfig();

        // Read confirmed pool price from PoolManager.
        // Cannot be manipulated in this tx without paying full swap cost.
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(pid);
        if (sqrtPriceX96 == 0) revert Genesis_HeartbeatPoolNotInitialized();

        // Spot-movement gate: refuse if pool price moved more than 2 % from EMA.
        // absDiff * 50 > ema  is equivalent to  absDiff / ema > 200/10000.
        OracleLib.OracleState storage o = _oracleStates[pid];
        uint256 ema = o.emaPriceX96;
        if (ema > 0) {
            uint256 spot = uint256(sqrtPriceX96);
            uint256 absDiff = spot > ema ? spot - ema : ema - spot;
            if (absDiff * 50 > ema) revert Genesis_HeartbeatPriceMoved();
        }

        // Apply the same oracle update used in _updateAfterSwap.
        uint256 weight = cfg.oracleWeightBps == 0 ? 1000 : uint256(cfg.oracleWeightBps);
        _oracleStates[pid] = OracleLib.update(o, uint256(sqrtPriceX96), block.number, weight);

        // Enforce one-per-block
        _lastHeartbeatBlock = block.number;

        emit OracleHeartbeat(PoolId.unwrap(pid), sqrtPriceX96, block.number);
    }

    function _isCorrectiveSwap(PoolId pid, bool zeroForOne) internal view returns (bool) {
        OracleLib.OracleState memory o = _oracleStates[pid];
        if (OracleLib.stalenessBlocks(o, block.number) > oracleStalenessBlocks) return false;
        return OracleLib.isConfirmedCorrectiveDirection(o, _actualSpotPriceX96(pid, o), zeroForOne);
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external onlyPoolManager notPaused returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96, int24)
        external
        onlyPoolManager
        notPaused
        returns (bytes4)
    {
        PoolId pid = key.toId();

        _oracleStates[pid] = OracleLib.initialize(uint256(sqrtPriceX96), block.number);

        FlowLib.FlowState memory emptyFlow =
            FlowLib.FlowState({accumulator: 0, lastBlock: block.number});

        _flowStates[pid] = emptyFlow;
        _flowStatesZeroForOne[pid] = emptyFlow;
        _flowStatesOneForZero[pid] = emptyFlow;

        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) external onlyPoolManager notPaused returns (bytes4) {
        PoolId pid = key.toId();
        PoolConfig memory cfg = _poolConfigs[pid];
        if (cfg.minHoldBlocks == 0) revert Genesis_InvalidConfig();

        // A top-up locks the whole fungible position until the later deadline.
        // Decreasing the pool policy cannot unlock an earlier top-up prematurely.
        bytes32 pkey = _positionKey(sender, pid, params);
        uint256 unlockAt = block.number + cfg.minHoldBlocks;
        if (unlockAt > _positionUnlockBlock[pkey]) _positionUnlockBlock[pkey] = unlockAt;

        IResearchLpBridge(researchLpBridge).beforeAddLiquidity(sender,key,params,"");
        emit LiquidityAdded(PoolId.unwrap(pid), sender, block.number);
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external onlyPoolManager notPaused returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) external onlyPoolManager returns (bytes4) {
        PoolId pid = key.toId();
        // Pause blocks new risk, not mature principal exits. Keep the deposit's
        // hold deadline and the adapter's ownership/accounting checks intact.
        if (block.number < _positionUnlockBlock[_positionKey(sender, pid, params)]) {
            revert Genesis_HoldPeriodActive();
        }

        IResearchLpBridge(researchLpBridge).beforeRemoveLiquidity(sender,key,params,"");
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    error Genesis_C3SimulatedInput(uint256 actualInput);

    // The external self-call deliberately reverts. All simulated pool state,
    // transient currency deltas, fee-cache changes and logs must roll back.
    // This is not a public quoting interface and cannot be called by other actors.
    function c3SimulateAmmInput(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        uint24 selectedLpFee
    ) external {
        if (msg.sender != address(this)) revert Genesis_Unauthorized();
        // A hook-self swap bypasses hook callbacks, including the LP override.
        // Reproduce the chosen override INSIDE the reverted call, dynamic pools only.
        if ((key.fee & uint24(0x800000)) != 0) {
            poolManager.updateDynamicLPFee(key, selectedLpFee);
        }
        BalanceDelta measured = poolManager.swap(key, params, "");
        int256 input = int256(params.zeroForOne ? measured.amount0() : measured.amount1());
        if (input > 0) revert Genesis_InvalidAmount();
        revert Genesis_C3SimulatedInput(uint256(-input));
    }

    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        notPaused
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId pid = key.toId();
        uint256 amountMagnitude = _requireExactInput(params.amountSpecified);
        bool exactInput = true;
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(pid);
        uint256 depth = _estimatedDepth(pid, sqrtPriceX96);
        uint24 feePips = _previewSwapFee(pid, amountMagnitude, depth, params.zeroForOne);

        // _requireExactInput above rejects exact-output and zero amountSpecified.
        // All supported swaps continue through exact-input accounting below.
        bool corrective = exactInput && _isCorrectiveSwap(pid, params.zeroForOne);
        if (exactInput) {
            // Retain the legacy model preview and its existing revert behavior.
            // Its output is not a promise of the subsequent native execution output.
            _afterSwapQuotePreview(key, params, feePips, depth);
        }

        (, uint256 rawSurcharge, uint256 normalizedSurcharge) =
            _toxicSurcharge(key, pid, amountMagnitude, feePips, corrective, params.zeroForOne);

        uint256 operatorFeeRaw = (amountMagnitude * operatorFeePips) / 1_000_000;

        // Selected policy: preserve gross input budget on full fills and scale
        // separately reserved hook fees by native input capacity on partial fills.
        uint256 reservedFees = operatorFeeRaw + rawSurcharge;
        if (reservedFees > 0) {
            if (reservedFees >= amountMagnitude) revert Genesis_InvalidAmount();
            uint256 simulatedInput;
            try this.c3SimulateAmmInput(key, params, feePips) {
                revert Genesis_InvalidAmount(); // simulation must never return normally
            } catch (bytes memory reason) {
                bytes4 selector;
                if (reason.length == 36) {
                    assembly ("memory-safe") {
                        selector := mload(add(reason, 0x20))
                        simulatedInput := mload(add(reason, 0x24))
                    }
                }
                if (reason.length != 36 || selector != Genesis_C3SimulatedInput.selector) {
                    assembly ("memory-safe") { revert(add(reason, 0x20), mload(reason)) }
                }
            }
            uint256 available = amountMagnitude - reservedFees;
            if (simulatedInput < available) {
                operatorFeeRaw = FullMath.mulDiv(operatorFeeRaw, simulatedInput, available);
                rawSurcharge = FullMath.mulDiv(rawSurcharge, simulatedInput, available);
                normalizedSurcharge = _valueNormalizedAmountIn(
                    pid, rawSurcharge, params.zeroForOne, sqrtPriceX96
                );
            }
        }

        uint256 nonce = _storeTransientSwapSnapshot(
            pid,
            sender,
            params.amountSpecified,
            params.zeroForOne,
            feePips,
            corrective,
            normalizedSurcharge,
            rawSurcharge
        );

        bool mayReward = _snapshotRofrPreSwap(
            pid,
            nonce,
            sqrtPriceX96,
            params.zeroForOne
        );

        _storeTransientOperatorFee(pid, nonce, operatorFeeRaw);

        uint256 totalHookDeltaRaw = rawSurcharge + operatorFeeRaw;
        BeforeSwapDelta hookDelta = totalHookDeltaRaw == 0
            ? BeforeSwapDeltaLibrary.ZERO_DELTA
            : toBeforeSwapDelta(int128(uint128(totalHookDeltaRaw)), 0);

        IPoolManager.SwapParams memory netParams=IPoolManager.SwapParams(
            params.zeroForOne,params.amountSpecified+int256(totalHookDeltaRaw),params.sqrtPriceLimitX96);
        IResearchLpBridge(researchLpBridge).captureBefore(key,netParams,feePips,mayReward);
        return (IHooks.beforeSwap.selector, hookDelta, _encodeDynamicFee(feePips));
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external onlyPoolManager notPaused returns (bytes4, int128) {
        PoolId pid = key.toId();
        _requireExactInput(params.amountSpecified);
        bool exactInput = true;

        (
            uint24 feePips,
            ,
            uint256 normalizedSurcharge,
            uint256 rawSurcharge,
            bool hasSnapshot,
            uint256 nonce
        ) = _loadAndClearTransientSwapSnapshot(
            pid,
            sender,
            params.amountSpecified,
            params.zeroForOne
        );

        if (!hasSnapshot) revert Genesis_MissingSwapSnapshot();

        address user = _beneficiaryFromHookData(sender, hookData);

        uint256 operatorFeeRaw = _loadAndClearTransientOperatorFee(pid, nonce);
        if (operatorFeeRaw > 0) {
            Currency specifiedCurrency = params.zeroForOne ? key.currency0 : key.currency1;
            specifiedCurrency.take(poolManager, address(this), operatorFeeRaw, false);
            uint256 currencyId = Currency.unwrap(specifiedCurrency) == address(0)
                ? 1
                : uint256(uint160(Currency.unwrap(specifiedCurrency)));
            operatorFeeAccruedByCurrency[currencyId] += operatorFeeRaw;
        }

        if (rawSurcharge > 0) {
            Currency surchargeCurrency = params.zeroForOne ? key.currency0 : key.currency1;
            surchargeCurrency.take(poolManager, address(this), rawSurcharge, false);
            _fundBackingRaw(pid, surchargeCurrency, rawSurcharge); // RAW payout gate
        }

        if (normalizedSurcharge > 0) {
            _fundVaultAccounting(pid, normalizedSurcharge); // analytics only
        }

        // Callback delta is AMM input (including LP fee), before hook-return deltas.
        int256 executedInputDelta = int256(params.zeroForOne ? delta.amount0() : delta.amount1());
        if (executedInputDelta > 0) revert Genesis_InvalidAmount();
        _updateAfterSwap(pid, uint256(-executedInputDelta), params.zeroForOne);

        (
            uint256 spotPre,
            uint256 dislocationPre,
            uint256 rofrImprovementBps
        ) = _consumeRofrSnapshot(
            pid,
            nonce,
            params.zeroForOne
        );

        int128 hookDeltaUnspecified = 0;

        if (rofrImprovementBps > 0) {
            // Analytics ROFR uses the SAME genuine external opportunity.
            _fundVaultFromRofrRecapture(
                pid,
                user,
                uint256(-executedInputDelta),
                feePips,
                params.zeroForOne,
                dislocationPre,
                rofrImprovementBps,
                spotPre
            );

            if (
                rewardsEnabled
                    && address(rewardsController) != address(0)
            ) {
                int128 outLeg =
                    params.zeroForOne
                        ? delta.amount1()
                        : delta.amount0();

                uint256 outputRaw =
                    outLeg > 0
                        ? uint256(uint128(outLeg))
                        : 0;

                if (outputRaw > 0) {
                    // SINGLE fail-open realization boundary preserved.
                    try this.realizeEconomics(
                        pid,
                        key,
                        sender,
                        user,
                        outputRaw,
                        feePips,
                        params.zeroForOne,
                        dislocationPre,
                        rofrImprovementBps
                    ) returns (uint256 paid) {
                        if (paid > 0) {
                            hookDeltaUnspecified =
                                -int128(uint128(paid));
                        }
                    } catch (bytes memory reason) {
                        bytes4 sel;

                        if (reason.length >= 4) {
                            assembly {
                                sel := mload(add(reason, 0x20))
                            }
                        }

                        emit EconomicsRealizationFailed(
                            PoolId.unwrap(pid),
                            sel
                        );
                    }
                }
            }
        }

        IResearchLpBridge(researchLpBridge).finishEmpty(key,params.zeroForOne);
        return (IHooks.afterSwap.selector, hookDeltaUnspecified);
    }

    function _afterSwapQuotePreview(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        uint24 knownFeePips,
        uint256 knownDepth
    ) internal view returns (uint256 amountOut, uint256 improvement, uint256 feePips, uint256 bonus) {
        uint256 amountIn = _requireExactInput(params.amountSpecified);
        return _quoteExactInputWithKnownFeeInternal(key, amountIn, params.zeroForOne, knownFeePips, knownDepth);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        onlyPoolManager
        notPaused
        returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        onlyPoolManager
        notPaused
        returns (bytes4)
    {
        return IHooks.afterDonate.selector;
    }

    function _quoteExactInputInternal(PoolKey calldata key, uint256 amountIn, bool zeroForOne)
        internal
        view
        returns (uint256 amountOut, uint256 improvement, uint256 feePips, uint256 bonus)
    {
        PoolId pid = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(pid);
        uint256 depth = _estimatedDepth(pid, sqrtPriceX96);
        uint24 dynamicFee = _previewSwapFee(pid, amountIn, depth, zeroForOne);

        return _quoteExactInputWithKnownFeeInternal(key, amountIn, zeroForOne, dynamicFee, depth);
    }

    function _quoteExactInputWithKnownFeeInternal(
        PoolKey calldata key,
        uint256 amountIn,
        bool zeroForOne,
        uint24 dynamicFee,
        uint256 depth
    ) internal view returns (uint256 amountOut, uint256 improvement, uint256 feePips, uint256 bonus) {
        PoolId pid = key.toId();
        PoolConfig memory cfg = _poolConfigs[pid];
        OracleLib.OracleState memory o = _oracleStates[pid];

        uint256 spot = _actualSpotPriceX96(pid, o);
        uint256 ref = OracleLib.referencePriceX96(o);

        (amountOut,) = AmpLib.exactOutput(
            amountIn,
            spot,
            ref,
            depth > type(uint128).max ? type(uint128).max : uint128(depth),
            dynamicFee,
            cfg.ampBandBps,
            cfg.ampFactorBps,
            cfg.oracleWeightBps,
            zeroForOne
        );

        uint256 operatorFeeRaw = (amountIn * operatorFeePips) / 1_000_000;
        if (operatorFeeRaw > 0 && amountIn > 0 && amountOut > 0) {
            uint256 operatorFeeOut = (operatorFeeRaw * amountOut) / amountIn;
            amountOut = amountOut > operatorFeeOut ? amountOut - operatorFeeOut : 0;
        }

        uint256 feePaid = (amountIn * dynamicFee) / 1_000_000;
        bool corrective = OracleLib.isConfirmedCorrectiveDirection(o, spot, zeroForOne);

        if (corrective) {
            uint256 availableBacking = _claimableBackingForPool(pid);
            if (availableBacking == 0) return (amountOut, 0, dynamicFee, 0);

            improvement = _lvrAwareImprovement(amountIn, feePaid, spot, ref, zeroForOne);

            if (improvement > availableBacking) improvement = availableBacking;

            bonus = _executionBonus(pid, amountIn, improvement);
        } else {
            improvement = 0;
            bonus = 0;
        }

        return (amountOut, improvement, dynamicFee, bonus);
    }

    uint256 internal constant IMPACT_DAMPENING_DIVISOR = 8;

    uint256 internal constant EXECUTION_BONUS_CAP_BPS = 500;

    function _executionBonus(PoolId pid, uint256 amountIn, uint256 improvement) internal view returns (uint256) {
        if (amountIn == 0 || improvement == 0) return 0;

        uint256 microThreshold = _bonusMicroThreshold[pid];
        uint256 maxThreshold = _bonusMaxThreshold[pid];

        if (microThreshold == 0 || maxThreshold == 0) return 0;

        if (amountIn > maxThreshold) return 0;

        uint256 shareBps = amountIn <= microThreshold ? EXECUTION_BONUS_MICRO_SHARE_BPS : EXECUTION_BONUS_BASE_SHARE_BPS;

        uint256 bonus = (improvement * shareBps) / 10_000;
        uint256 cap = (improvement * EXECUTION_BONUS_CAP_BPS) / 10_000;

        return bonus > cap ? cap : bonus;
    }

    function _lvrAwareImprovement(
        uint256 amountIn,
        uint256 feePaid,
        uint256 spotPriceX96,
        uint256 referencePriceX96,
        bool zeroForOne
    ) internal pure returns (uint256) {
        if (amountIn == 0 || feePaid == 0) return 0;
        if (spotPriceX96 == 0 || referencePriceX96 == 0) return feePaid;

        uint256 dislocationBps = OracleLib.dislocationBps(spotPriceX96, referencePriceX96);
        bool corrective = OracleLib.isCorrectiveDirection(spotPriceX96, referencePriceX96, zeroForOne);

        if (corrective) {
            uint256 estimatedLvr = (amountIn * dislocationBps) / 10_000;

            // PHASE 4.1: make corrective routing edge dislocation-aware.
            // Target: move from defensive-only to routing-competitive,
            // while final issuance remains capped by real vault / risk config / drain limiter.
            uint256 shareBps = 2_000 + (dislocationBps * 20);
            if (shareBps > 6_000) shareBps = 6_000;

            uint256 dislocationCredit = (estimatedLvr * shareBps) / 10_000;
            uint256 improvement = feePaid + dislocationCredit;

            // Sustainable issuance cap:
            // improvement credits must stay bounded by swap-paid revenue,
            // not by arbitrary input-side bps.
            uint256 hardCap = feePaid * 2;
            return improvement > hardCap ? hardCap : improvement;
        }

        uint256 estimatedLvrPenalty = (amountIn * dislocationBps) / 10_000;

        if (estimatedLvrPenalty >= feePaid) return 0;

        return feePaid - estimatedLvrPenalty;
    }

    /// @notice Model estimate only. It is not an executable router simulation.
    /// Actual execution depends on price limits, routing, settlement and live state.
    function quoteExactInput(PoolKey calldata key, uint256 amountIn, bool zeroForOne)
        external
        view
        returns (uint256 amountOut, uint256 improvement, uint256 feePips, uint256 bonus)
    {
        return _quoteExactInputInternal(key, amountIn, zeroForOne);
    }

    /// @notice Legacy model preview, not an execution guarantee. Exact-input only.
    function previewExecutionQuote(PoolKey calldata key, IPoolManager.SwapParams calldata params)
        external
        view
        returns (uint256 amountOut, uint256 improvement, uint256 feePips, uint256 bonus)
    {
        uint256 amountIn = _requireExactInput(params.amountSpecified);
        return _quoteExactInputInternal(key, amountIn, params.zeroForOne);
    }

    /// @notice Legacy model estimate; not an executable quote or payout entitlement.
    /// @dev Use the reviewed router simulation for execution bounds at a pinned block.
    function quoteExecutionEdge(PoolKey calldata key, uint256 amountIn, bool zeroForOne)
        external
        view
        returns (
            uint256 amountOut,
            uint256 vaultBackedImprovement,
            uint256 bonus,
            uint256 edgeBps,
            uint256 amountOutWithEdge
        )
    {
        uint256 rofrCredit;
        (amountOut,, vaultBackedImprovement, bonus, rofrCredit,, edgeBps,) =
            _quoteExecutionEdgeBreakdownInternal(key, amountIn, zeroForOne);

        rofrCredit;
        amountOutWithEdge = amountOut; // avoid mixing token units, use edgeBps externally
    }

    function _quoteExecutionEdgeBreakdownInternal(PoolKey calldata key, uint256 amountIn, bool zeroForOne)
        internal
        view
        returns (
            uint256 rawAmountOut,
            uint256 feePips,
            uint256 vaultBackedImprovement,
            uint256 bonus,
            uint256 rofrCredit,
            uint256 totalEdgeInputUnits,
            uint256 edgeBps,
            uint256 amountOutWithEdge
        )
    {
        PoolId pid = key.toId();

        (rawAmountOut, vaultBackedImprovement, feePips, bonus) = _quoteExactInputInternal(key, amountIn, zeroForOne);

        // Legacy MODEL edge: raw backing bounds the estimate, but this does not
        // simulate native fills, future payout caps or actual post-swap eligibility.
        // Do not present these values as guaranteed or immediately claimable output.
        // Synthetic ROFR accounting remains excluded from the model edge.
        Currency outCurrency = zeroForOne ? key.currency1 : key.currency0;
        uint256 rawBackingOut =
            _realBackingRaw[pid][_currencyIdFor(outCurrency)];

        uint256 claimableBacking =
            rawAmountOut == 0
                ? 0
                : FullMath.mulDiv(
                    rawBackingOut,
                    amountIn,
                    rawAmountOut
                );

        if (vaultBackedImprovement > claimableBacking) {
            vaultBackedImprovement = claimableBacking;
        }

        uint256 remainingBacking =
            claimableBacking - vaultBackedImprovement;

        if (bonus > remainingBacking) {
            bonus = remainingBacking;
        }

        PoolConfig memory cfg = _poolConfigs[pid];
        uint256 premiumPaid = feePips > cfg.baseFee ? (amountIn * (feePips - cfg.baseFee)) / 1_000_000 : 0;

        if (premiumPaid >= vaultBackedImprovement) {
            premiumPaid -= vaultBackedImprovement;
            vaultBackedImprovement = 0;
            bonus = premiumPaid >= bonus ? 0 : bonus - premiumPaid;
        } else {
            vaultBackedImprovement -= premiumPaid;
        }

        totalEdgeInputUnits = vaultBackedImprovement + bonus;
        edgeBps = amountIn == 0 ? 0 : (totalEdgeInputUnits * 10_000) / amountIn;

        amountOutWithEdge = rawAmountOut + ((rawAmountOut * edgeBps) / 10_000);
    }

    /// @notice Legacy model estimate; not an executable quote or payout entitlement.
    /// @dev Use the reviewed router simulation for execution bounds at a pinned block.
    function quoteExecutionEdgeBreakdown(PoolKey calldata key, uint256 amountIn, bool zeroForOne)
        external
        view
        returns (
            uint256 rawAmountOut,
            uint256 feePips,
            uint256 vaultBackedImprovement,
            uint256 bonus,
            uint256 rofrCredit,
            uint256 totalEdgeInputUnits,
            uint256 edgeBps,
            uint256 amountOutWithEdge
        )
    {
        return _quoteExecutionEdgeBreakdownInternal(key, amountIn, zeroForOne);
    }

    /// @notice Aggregator-friendly scoring function.
    /// @dev Fail-closed: executable trader credit requires post-swap state,
    ///      which this view quote cannot guarantee.
    function getAggregatorScore(PoolKey calldata key, uint256 amountIn, bool zeroForOne)
        external
        view
        returns (uint256 rawAmountOut, uint256 creditValueInOutputUnits, uint256 aggregatorScore, uint256 edgeBps)
    {
        (rawAmountOut,,,) =
            _quoteExactInputInternal(key, amountIn, zeroForOne);

        return (rawAmountOut, 0, rawAmountOut, 0);
    }
}
