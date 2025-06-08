// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@oz-4.9.0/proxy/beacon/BeaconProxy.sol";

contract PairBeaconProxy is BeaconProxy(msg.sender, "") {}
