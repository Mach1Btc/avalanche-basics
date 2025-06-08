// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IFeeDistributor {
    function initialize(address _voter, address _pairFees) external;

    function _deposit(uint256 amount, uint256 tokenId) external;

    function _withdraw(uint256 amount, uint256 tokenId) external;

    function getRewardForOwner(
        uint256 tokenId,
        address[] memory tokens
    ) external;

    function notifyRewardAmount(address token, uint256 amount) external;

    function getRewardTokens() external view returns (address[] memory);

    function earned(
        address token,
        uint256 tokenId
    ) external view returns (uint256 reward);

    function incentivize(address token, uint256 amount) external;
}
