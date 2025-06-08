// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IVeArtProxy {
    function _tokenURI(
        uint256 _tokenId,
        uint256 _lockedAmount,
        uint256 _votingPower,
        uint256 _locked_end
    ) external pure returns (string memory output);
}
