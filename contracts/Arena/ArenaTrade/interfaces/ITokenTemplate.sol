// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface ITokenTemplate {
    event ArenaTokenTransfer(
        address indexed from,
        address indexed to,
        uint256 value
    );

    function mint(address to, uint256 amount) external;

    function burn(address account, uint256 value) external;

    function setBlacklistStatus(address _address, bool _isBlacklisted) external;

    function totalSupply() external view returns (uint256);

    function blacklistedAddresses(
        address _address
    ) external view returns (bool);

    function nonces(address owner) external view returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);

    function transfer(address to, uint256 amount) external returns (bool);

    function balanceOf(address account) external view returns (uint256);
}
