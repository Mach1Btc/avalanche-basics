// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.19;

import "../QiToken.sol";

// The commonly structures and events for the MultiRewardDistributor
interface MultiRewardDistributorCommon {
    struct MarketConfig {
        // The owner/admin of the emission config
        address owner;
        // The emission token
        address emissionToken;
        // Scheduled to end at this time
        uint endTime;
        // Supplier global state
        uint224 supplyGlobalIndex;
        uint32 supplyGlobalTimestamp;
        // Borrower global state
        uint224 borrowGlobalIndex;
        uint32 borrowGlobalTimestamp;
        uint supplyEmissionsPerSec;
        uint borrowEmissionsPerSec;
    }

    struct MarketEmissionConfig {
        MarketConfig config;
        mapping(address => uint) supplierIndices;
        mapping(address => uint) supplierRewardsAccrued;
        mapping(address => uint) borrowerIndices;
        mapping(address => uint) borrowerRewardsAccrued;
    }

    struct RewardInfo {
        address emissionToken;
        uint totalAmount;
        uint supplySide;
        uint borrowSide;
    }

    struct IndexUpdate {
        uint224 newIndex;
        uint32 newTimestamp;
    }

    struct QiTokenData {
        uint qiTokenBalance;
        uint borrowBalanceStored;
    }

    struct RewardWithQiToken {
        address qiToken;
        RewardInfo[] rewards;
    }

    // Global index updates
    event GlobalSupplyIndexUpdated(
        QiToken qiToken,
        address emissionToken,
        uint newSupplyIndex,
        uint32 newSupplyGlobalTimestamp
    );
    event GlobalBorrowIndexUpdated(
        QiToken qiToken,
        address emissionToken,
        uint newIndex,
        uint32 newTimestamp
    );

    // Reward Disbursal
    event DisbursedSupplierRewards(
        QiToken indexed qiToken,
        address indexed supplier,
        address indexed emissionToken,
        uint totalAccrued
    );
    event DisbursedBorrowerRewards(
        QiToken indexed qiToken,
        address indexed borrower,
        address indexed emissionToken,
        uint totalAccrued
    );

    // Admin update events
    event NewConfigCreated(
        QiToken indexed qiToken,
        address indexed owner,
        address indexed emissionToken,
        uint supplySpeed,
        uint borrowSpeed,
        uint endTime
    );
    event NewPauseGuardian(address oldPauseGuardian, address newPauseGuardian);
    event NewEmissionCap(uint oldEmissionCap, uint newEmissionCap);
    event NewEmissionConfigOwner(
        QiToken indexed qiToken,
        address indexed emissionToken,
        address currentOwner,
        address newOwner
    );
    event NewRewardEndTime(
        QiToken indexed qiToken,
        address indexed emissionToken,
        uint currentEndTime,
        uint newEndTime
    );
    event NewSupplyRewardSpeed(
        QiToken indexed qiToken,
        address indexed emissionToken,
        uint oldRewardSpeed,
        uint newRewardSpeed
    );
    event NewBorrowRewardSpeed(
        QiToken indexed qiToken,
        address indexed emissionToken,
        uint oldRewardSpeed,
        uint newRewardSpeed
    );
    event FundsRescued(address token, uint amount);

    // Pause guardian stuff
    event RewardsPaused();
    event RewardsUnpaused();

    // Errors
    event InsufficientTokensToEmit(
        address user,
        address rewardToken,
        uint amount
    );
}
