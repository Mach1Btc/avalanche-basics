// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@oz-4.9.0/proxy/beacon/IBeacon.sol";
import "@oz-4.9.0/proxy/beacon/BeaconProxy.sol";

import "@oz-4.9.0/proxy/utils/Initializable.sol";

import "./../interfaces/IFeeDistributor.sol";

contract FeeDistributorFactory is IBeacon, Initializable {
    address public lastFeeDistributor;
    address public implementation;
    address public owner;

    /// @notice Emitted when pairs implementation is changed
    /// @param oldImplementation The previous implementation
    /// @param newImplementation The new implementation
    event ImplementationChanged(
        address indexed oldImplementation,
        address indexed newImplementation
    );

    /// @notice Emitted when the owner of the factory is changed
    /// @param oldOwner The owner before the owner was changed
    /// @param newOwner The owner after the owner was changed
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _owner,
        address _implementation
    ) external initializer {
        owner = _owner;
        implementation = _implementation;
        emit OwnerChanged(address(0), msg.sender);
    }

    function createFeeDistributor(address pairFees) external returns (address) {
        lastFeeDistributor = address(
            new BeaconProxy(
                address(this),
                abi.encodeWithSelector(
                    IFeeDistributor.initialize.selector,
                    msg.sender,
                    pairFees
                )
            )
        );

        return lastFeeDistributor;
    }

    function setImplementation(address _implementation) external {
        require(msg.sender == owner, "AUTH");
        emit ImplementationChanged(implementation, _implementation);
        implementation = _implementation;
    }

    function setOwner(address _owner) external {
        require(msg.sender == owner, "AUTH");
        emit OwnerChanged(owner, _owner);
        owner = _owner;
    }
}
