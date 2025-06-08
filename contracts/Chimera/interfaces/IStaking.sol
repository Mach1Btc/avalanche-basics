// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;

interface IStaking {
    function stake(uint256 _amount, address _recipient) external returns (bool);

    function unstake(uint256 _amount, bool _trigger) external;

    function claim(address _recipient) external;

    function epoch()
        external
        view
        returns (uint256 number, uint256 amount, uint32 length, uint32 endTime);

    function distributor() external view returns (address _distributor);
}
