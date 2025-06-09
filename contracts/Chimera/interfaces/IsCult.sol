// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;

interface IsCult {
    function index() external view returns (uint256);

    function rebases(
        uint256 index
    )
        external
        view
        returns (
            uint256 epoch,
            uint256 rebasePercent,
            uint256 stakedBefore,
            uint256 stakedAfter,
            uint256 amount,
            uint256 rebaseIndex,
            uint32 time
        );

    function transfer(
        address _recipient,
        uint256 _amount
    ) external returns (bool);
}
