// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;

import "@oz-3.4.2/proxy/BeaconProxy.sol";

contract ClBeaconProxy is BeaconProxy {
    // Doing so the CREATE2 hash is easier to calculate
    constructor() payable BeaconProxy(msg.sender, "") {}
}
