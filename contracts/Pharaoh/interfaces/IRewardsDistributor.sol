// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IRewardsDistributor {
    function checkpointToken() external;

    function checkpointTotalSupply() external;

    function claimable(uint256 _tokenId) external view returns (uint256);

    function claim(uint256 _tokenId) external returns (uint256);

    function claimMany(uint256[] memory _tokenIds) external returns (bool);
}
