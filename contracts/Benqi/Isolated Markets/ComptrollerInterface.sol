// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.19;

abstract contract ComptrollerInterface {
    /// @notice Indicator that this is a Comptroller contract (for inspection)
    bool public constant isComptroller = true;

    /*** Assets You Are In ***/

    function enterMarkets(
        address[] calldata qiTokens
    ) external virtual returns (uint[] memory);

    function exitMarket(address qiToken) external virtual returns (uint);

    /*** Policy Hooks ***/

    function mintAllowed(
        address qiToken,
        address minter,
        uint mintAmount
    ) external virtual returns (uint);

    function redeemAllowed(
        address qiToken,
        address redeemer,
        uint redeemTokens
    ) external virtual returns (uint);

    // Do not remove, still used by QiToken
    function redeemVerify(
        address qiToken,
        address redeemer,
        uint redeemAmount,
        uint redeemTokens
    ) external pure virtual;

    function borrowAllowed(
        address qiToken,
        address borrower,
        uint borrowAmount
    ) external virtual returns (uint);

    function repayBorrowAllowed(
        address qiToken,
        address payer,
        address borrower,
        uint repayAmount
    ) external virtual returns (uint);

    function liquidateBorrowAllowed(
        address qiTokenBorrowed,
        address qiTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount
    ) external view virtual returns (uint);

    function seizeAllowed(
        address qiTokenCollateral,
        address qiTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens
    ) external virtual returns (uint);

    function transferAllowed(
        address qiToken,
        address src,
        address dst,
        uint transferTokens
    ) external virtual returns (uint);

    /*** Liquidity/Liquidation Calculations ***/

    function liquidateCalculateSeizeTokens(
        address qiTokenBorrowed,
        address qiTokenCollateral,
        uint repayAmount
    ) external view virtual returns (uint, uint);
}

// The hooks that were patched out of the comptroller to make room for the supply caps, if we need them
abstract contract ComptrollerInterfaceWithAllVerificationHooks is
    ComptrollerInterface
{
    function mintVerify(
        address qiToken,
        address minter,
        uint mintAmount,
        uint mintTokens
    ) external virtual;

    // Included in ComptrollerInterface already
    // function redeemVerify(address qiToken, address redeemer, uint redeemAmount, uint redeemTokens) virtual external;

    function borrowVerify(
        address qiToken,
        address borrower,
        uint borrowAmount
    ) external virtual;

    function repayBorrowVerify(
        address qiToken,
        address payer,
        address borrower,
        uint repayAmount,
        uint borrowerIndex
    ) external virtual;

    function liquidateBorrowVerify(
        address qiTokenBorrowed,
        address qiTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount,
        uint seizeTokens
    ) external virtual;

    function seizeVerify(
        address qiTokenCollateral,
        address qiTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens
    ) external virtual;

    function transferVerify(
        address qiToken,
        address src,
        address dst,
        uint transferTokens
    ) external virtual;
}
