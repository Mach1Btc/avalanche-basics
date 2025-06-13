// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title An interface for a contract that is capable of deploying CL Pools
/// @notice A contract that constructs a pool must implement this to pass arguments to the pool
/// @dev The store and retrieve method of supplying constructor arguments for CREATE2 isn't needed anymore
/// since we now use a beacon pattern
interface IClPoolDeployer {

}
