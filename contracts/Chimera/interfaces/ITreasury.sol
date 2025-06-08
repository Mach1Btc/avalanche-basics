// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;

interface ITreasury {
    function deposit(
        uint256 _amount,
        address _token,
        uint256 _profit
    ) external returns (bool);

    function valueOf(
        address _token,
        uint256 _amount
    ) external view returns (uint256 value_);

    function mintRewards(address _recipient, uint256 _amount) external;

    function queue(uint256 index, address _to) external returns (bool);

    function toggle(uint256, address, address) external returns (bool);

    function policy() external view returns (address);
}
