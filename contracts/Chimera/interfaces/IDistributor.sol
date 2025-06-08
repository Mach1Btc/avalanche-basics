// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;

interface IDistributor {
    function info(
        uint256 index
    ) external view returns (uint256 rate, address recipient);

    function distribute() external returns (bool);
}
