// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

import "./interfaces/IClPoolDeployer.sol";
import "./interfaces/IClPool.sol";
import "../ClBeaconProxy.sol";
import "@oz-3.4.2/proxy/IBeacon.sol";

contract ClPoolDeployer is IClPoolDeployer, IBeacon {
    /// @inheritdoc IBeacon
    address public override implementation;

    /// @dev Deploys a pool with the given parameters by transiently setting the parameters storage slot and then
    /// clearing it after deploying the pool.
    /// @param nfpManager The contract address of the CL NFP Manager
    /// @param votingEscrow The contract address of Voting Escrow
    /// @param voter The contract address of Voter
    /// @param token0 The first token of the pool by address sort order
    /// @param token1 The second token of the pool by address sort order
    /// @param fee The fee collected upon every swap in the pool, denominated in hundredths of a bip
    /// @param tickSpacing The spacing between usable ticks
    function _deploy(
        address factory,
        address nfpManager,
        address votingEscrow,
        address voter,
        address token0,
        address token1,
        uint24 fee,
        int24 tickSpacing
    ) internal returns (address pool) {
        pool = address(
            new ClBeaconProxy{
                salt: keccak256(abi.encode(token0, token1, fee))
            }()
        );
        IClPool(pool).initialize(
            factory,
            nfpManager,
            votingEscrow,
            voter,
            token0,
            token1,
            fee,
            tickSpacing
        );
    }
}
