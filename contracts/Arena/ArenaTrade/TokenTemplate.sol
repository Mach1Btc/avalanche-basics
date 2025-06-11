// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.0.0
pragma solidity 0.8.23;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract TokenTemplate is ERC20, Ownable {
    mapping(address => bool) public blacklistedAddresses;
    uint256 public constant MAX_NAME_BYTE_LENGTH = 50;
    uint256 public constant MAX_SYMBOL_BYTE_LENGTH = 30;

    event ArenaTokenTransfer(
        address indexed from,
        address indexed to,
        uint256 value
    );

    constructor(
        string memory name,
        string memory symbol,
        address _admin
    ) ERC20(name, symbol) Ownable(_admin) {
        require(
            bytes(name).length <= MAX_NAME_BYTE_LENGTH,
            "Name string length exceeds max byte size"
        );
        require(
            bytes(symbol).length <= MAX_SYMBOL_BYTE_LENGTH,
            "Symbol string length exceeds max byte size"
        );
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burn(address account, uint256 value) external onlyOwner {
        _burn(account, value);
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        require(!blacklistedAddresses[to], "Sender is blacklisted");
        super._update(from, to, value);
        emit ArenaTokenTransfer(from, to, value);
    }

    function setBlacklistStatus(
        address _address,
        bool _isBlacklisted
    ) external onlyOwner {
        blacklistedAddresses[_address] = _isBlacklisted;
    }
}
