// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

import "../interfaces/IPeripheryImmutableState.sol";
import "@oz-3.4.2-up/proxy/Initializable.sol";

/// @title Immutable state
/// @notice Immutable state used by periphery contracts
abstract contract PeripheryStateUpgradeable is
    Initializable,
    IPeripheryImmutableState
{
    /// @inheritdoc IPeripheryImmutableState
    address public override factory;
    /// @inheritdoc IPeripheryImmutableState
    address public override WETH9;

    function __Periphery_init_unchained(
        address _factory,
        address _WETH9
    ) internal initializer {
        factory = _factory;
        WETH9 = _WETH9;
    }
}
