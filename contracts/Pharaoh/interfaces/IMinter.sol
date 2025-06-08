// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./IRewardsDistributor.sol";

interface IMinter {
    function updatePeriod() external returns (uint256);

    function activePeriod() external view returns (uint256);

    function rewardsDistributor() external view returns (IRewardsDistributor);

    function timelock() external view returns (address);

    function updateFlation(uint256 _flation) external;

    function updateGrowthCap(uint256 _newGrowthCap) external;

    function updateIncentivesSize(uint256 _newGrowth) external;
}
