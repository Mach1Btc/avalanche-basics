// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ITokenFactory {
    function deployToken(
        string memory name,
        string memory symbol,
        uint256 salt
    ) external returns (address);
}
