// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IGenesisClaimVault {
    function payout(address user, uint256 amount, uint256 currencyId) external;
    function tokenBalance(uint256 currencyId) external view returns (uint256);
}

interface IGenesisSystem {
    struct PoolConfig {
        uint24 baseFee;
        uint24 flowCoefficient;
        uint24 dislocationCoefficient;
        uint16 oracleWeightBps;
        uint16 ampBandBps;
        uint16 ampFactorBps;
        uint32 minHoldBlocks;
        address vault;
    }

    struct IntentSignal {
        bool isDislocated;
        bool isCorrectiveDirection;
        uint256 dislocationBps;
        uint256 flowPressure;
        uint256 referencePriceX96;
        uint256 spotPriceX96;
    }

    struct PendingClaim {
        address user;
        uint256 amount;
        uint256 currencyId;
        bool active;
    }

    struct RiskConfig {
        uint16 executionImprovementMaxShareBps;
        uint16 rofrMaxRecaptureToFeeBps;
        uint16 rofrMaxRecaptureToAmountBps;
    }

    error Genesis_Unauthorized();
    error Genesis_InvalidConfig();
    error Genesis_HoldPeriodActive();
    error Genesis_ZeroAddress();
    error Genesis_InvalidAmount();
    error Genesis_NoCredits();
    error Genesis_NoActiveClaim();
    error Genesis_ClaimAlreadyPending();
    error Genesis_ClaimSettlementFailed();
    error Genesis_CreditsExpired(uint256 expired);

    event PoolConfigured(bytes32 indexed poolId, PoolConfig config);
    event PoolRiskConfigured(bytes32 indexed poolId, RiskConfig config);
    event ImprovementAccrued(bytes32 indexed poolId, address indexed user, uint256 amount);
    event ImprovementClaimRequested(bytes32 indexed poolId, address indexed user, uint256 amount);
    event ImprovementClaimSettled(bytes32 indexed poolId, address indexed user, uint256 amount);
    event ImprovementClaimAccountingSettled(bytes32 indexed poolId, address indexed user, uint256 amount);
    event LiquidityAdded(bytes32 indexed poolId, address indexed lp, uint256 entryBlock);
}
