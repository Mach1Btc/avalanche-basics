// SPDX-License-Identifier: MIT
pragma solidity =0.7.6 || ^0.8.13;
pragma abicoder v2;

interface IVotingEscrow {
    struct Point {
        int128 bias;
        int128 slope; // # -dweight / dt
        uint256 ts;
        uint256 blk; // block
    }

    struct LockedBalance {
        int128 amount;
        uint256 end;
    }

    function emissionsToken() external view returns (address);

    function team() external returns (address);

    function epoch() external view returns (uint256);

    function pointHistory(uint256 loc) external view returns (Point memory);

    function userPointHistory(
        uint256 tokenId,
        uint256 loc
    ) external view returns (Point memory);

    function userPointEpoch(uint256 tokenId) external view returns (uint256);

    function ownerOf(uint256) external view returns (address);

    function isApprovedOrOwner(address, uint256) external view returns (bool);

    function transferFrom(address, address, uint256) external;

    function voting(uint256 tokenId) external;

    function abstain(uint256 tokenId) external;

    function attach(uint256 tokenId) external;

    function detach(uint256 tokenId) external;

    function checkpoint() external;

    function depositFor(uint256 tokenId, uint256 value) external;

    function createLockFor(
        uint256,
        uint256,
        address
    ) external returns (uint256);

    function balanceOfNFT(uint256) external view returns (uint256);

    function balanceOfNFTAt(uint256, uint256) external view returns (uint256);

    function totalSupply() external view returns (uint256);

    function locked__end(uint256) external view returns (uint256);

    function balanceOf(address) external view returns (uint256);

    function tokenOfOwnerByIndex(
        address,
        uint256
    ) external view returns (uint256);

    function increaseUnlockTime(uint256 tokenID, uint256 duration) external;

    function locked(
        uint256 tokenID
    ) external view returns (uint256 amount, uint256 unlockTime);

    function increaseAmount(uint256 _tokenId, uint256 _value) external;

    function isDelegate(
        address _operator,
        uint256 _tokenId
    ) external view returns (bool);
}
