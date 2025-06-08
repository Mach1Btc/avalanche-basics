// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IPairFees {
    function initialize(address _feeDistributor) external;

    function recoverFees(address token, address to) external;
}
