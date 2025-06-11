// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TokenTemplate} from "./TokenTemplate.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

contract TokenFactory {
    function deployToken(
        string memory name,
        string memory symbol,
        uint256 salt
    ) external returns (address) {
        bytes memory ERC20Bytecode = abi.encodePacked(
            type(TokenTemplate).creationCode,
            abi.encode(name, symbol, msg.sender)
        );

        address tokenContractAddress = Create2.deploy(
            0,
            bytes32(salt),
            ERC20Bytecode
        );

        return tokenContractAddress;
    }
}
