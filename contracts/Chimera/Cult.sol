// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;

import "./libraries/SafeMath.sol";
import "./libraries/Counters.sol";
import "./libraries/ERC20.sol";
import "./libraries/ERC20Permit.sol";
import "./libraries/Ownable.sol";

contract VaultOwned is Ownable {
    address internal _vault;

    function setVault(address vault_) external onlyManager returns (bool) {
        _vault = vault_;

        return true;
    }

    function vault() public view returns (address) {
        return _vault;
    }

    modifier onlyVault() {
        require(_vault == msg.sender, "VaultOwned: caller is not the Vault");
        _;
    }
}

contract Cult is ERC20Permit, VaultOwned {
    using SafeMath for uint256;

    uint256 public LAUNCH_CAP;
    uint256 public DENOMINATOR = 10000;
    uint256 public startTime;
    uint256 public CAP_LENGTH;
    address public initializer;
    mapping(address => bool) public whitelist;

    constructor(
        uint256 _cap,
        uint256 _capLength,
        uint256 initialMint,
        string memory _name,
        string memory _symbol
    ) ERC20(_name, _symbol, 9) {
        initializer = msg.sender;
        LAUNCH_CAP = _cap;
        CAP_LENGTH = _capLength;
        startTime = block.timestamp;
        _mint(msg.sender, initialMint);
    }

    function mint(address account_, uint256 amount_) external onlyVault {
        _mint(account_, amount_);
    }

    function burn(uint256 amount) public virtual {
        _burn(msg.sender, amount);
    }

    function burnFrom(address account_, uint256 amount_) public virtual {
        _burnFrom(account_, amount_);
    }

    function _burnFrom(address account_, uint256 amount_) public virtual {
        uint256 decreasedAllowance_ = allowance(account_, msg.sender).sub(
            amount_,
            "ERC20: burn amount exceeds allowance"
        );

        _approve(account_, msg.sender, decreasedAllowance_);
        _burn(account_, amount_);
    }

    function setInitializer(address _account) external {
        require(msg.sender == initializer);
        initializer = _account;
    }

    function setWhitelist(address _account, bool _flag) external {
        require(msg.sender == initializer);
        whitelist[_account] = _flag;
    }

    function _afterTokenTransfer(
        address from_,
        address to_,
        uint256 amount_
    ) internal virtual override {
        if (block.timestamp <= startTime + CAP_LENGTH) {
            require(
                whitelist[to_] ||
                    (balanceOf(to_) <=
                        (totalSupply() * LAUNCH_CAP) / DENOMINATOR),
                "balance exceeds launch cap"
            );
        }
    }
}
