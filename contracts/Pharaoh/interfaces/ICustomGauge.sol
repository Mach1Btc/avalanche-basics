// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ICustomGauge {
    error ZeroAmount();

    error NotifyStakingToken();

    error RewardTooHigh();

    error NotWhitelisted();

    error Unauthorized();

    event Deposit(address indexed from, uint256 amount);

    event Withdraw(address indexed from, uint256 amount);

    event NotifyReward(
        address indexed from,
        address indexed reward,
        uint256 amount
    );

    event ClaimRewards(
        address indexed from,
        address indexed reward,
        uint256 amount
    );

    event RewardWhitelisted(address indexed reward, bool whitelisted);

    function initialize(address _stake, address _voter) external;

    function rewardsList() external view returns (address[] memory);

    function rewardsListLength() external view returns (uint256);

    function lastTimeRewardApplicable(
        address token
    ) external view returns (uint256);

    function rewardData(
        address token
    ) external view returns (Reward memory data);

    function earned(
        address token,
        address account
    ) external view returns (uint256);

    function getReward(address account, address[] calldata tokens) external;

    function rewardPerToken(address token) external view returns (uint256);

    function depositAll() external;

    function deposit(uint256 amount) external;

    function withdrawAll() external;

    function left(address token) external view returns (uint256);

    function whitelistReward(address _reward) external;

    function removeRewardWhitelist(address _reward) external;

    function notifyRewardAmount(address token, uint256 amount) external;

    function balanceOf(address) external view returns (uint256);

    struct Reward {
        uint256 rewardRate;
        uint256 periodFinish;
        uint256 lastUpdateTime;
        uint256 rewardPerTokenStored;
    }
}
