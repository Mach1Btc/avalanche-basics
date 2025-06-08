// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IFeeDistributorFactory {
    function createFeeDistributor(address pairFees) external returns (address);
}
