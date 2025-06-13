// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import "./pool/IClPoolImmutables.sol";
import "./pool/IClPoolState.sol";
import "./pool/IClPoolDerivedState.sol";
import "./pool/IClPoolActions.sol";
import "./pool/IClPoolOwnerActions.sol";
import "./pool/IClPoolEvents.sol";

/// @title The interface for a CL V2 Pool
/// @notice A CL pool facilitates swapping and automated market making between any two assets that strictly conform
/// to the ERC20 specification
/// @dev The pool interface is broken up into many smaller pieces
interface IClPool is
    IClPoolImmutables,
    IClPoolState,
    IClPoolDerivedState,
    IClPoolActions,
    IClPoolOwnerActions,
    IClPoolEvents
{
    /// @notice Initializes a pool with parameters provided
    function initialize(
        address _factory,
        address _nfpManager,
        address _veRam,
        address _voter,
        address _token0,
        address _token1,
        uint24 _fee,
        int24 _tickSpacing
    ) external;

    function _advancePeriod() external;
}
