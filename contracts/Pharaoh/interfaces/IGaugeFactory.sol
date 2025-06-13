// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IGaugeFactory {
    function createGauge(
        address,
        address,
        address,
        bool,
        address[] calldata
    ) external returns (address);
}
