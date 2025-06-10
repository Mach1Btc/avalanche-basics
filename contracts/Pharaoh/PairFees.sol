// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./interfaces/IERC20.sol";
import "./interfaces/IVoter.sol";
import "./interfaces/IFeeDistributor.sol";

/// @notice Pair Fees contract is used as a 1:1 pair relationship to split out fees, this ensures that the curve does not need to be modified for LP shares
contract PairFees {
    address internal immutable pair; // The pair it is bonded to
    address internal immutable token0; // token0 of pair, saved localy and statically for gas optimization
    address internal immutable token1; // Token1 of pair, saved localy and statically for gas optimization
    address voter;
    address public feeDistributor;

    constructor(address _token0, address _token1, address _voter) {
        pair = msg.sender;
        token0 = _token0;
        token1 = _token1;
        voter = _voter;
    }

    function initialize(address _feeDistributor) external {
        require(msg.sender == voter, "!VOTER");
        feeDistributor = _feeDistributor;
        IERC20(token0).approve(_feeDistributor, type(uint256).max);
        IERC20(token1).approve(_feeDistributor, type(uint256).max);
    }

    function _safeTransfer(address token, address to, uint256 value) internal {
        require(token.code.length > 0);
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, value)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }

    /// @notice notifies all fees to feeDistributor
    function claimFeesFor() external returns (uint256, uint256) {
        if (feeDistributor == address(0)) {
            return (0, 0);
        }

        uint256 amount0 = IERC20(token0).balanceOf(address(this));
        uint256 amount1 = IERC20(token1).balanceOf(address(this));

        IFeeDistributor(feeDistributor).notifyRewardAmount(token0, amount0);
        IFeeDistributor(feeDistributor).notifyRewardAmount(token1, amount1);

        return (amount0, amount1);
    }

    /// @notice takes the entire balance of `token` and sends to `to`
    function recoverFees(address token, address to) external {
        require(msg.sender == voter, "!VOTER");

        address gauge = IVoter(voter).gauges(pair);
        bool isAlive = IVoter(voter).isAlive(gauge);
        require(feeDistributor == address(0) || !isAlive, "ACTIVE");

        IERC20 _token = IERC20(token);
        uint256 bal = _token.balanceOf(address(this));
        _token.transfer(to, bal);
    }
}
