// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.13;

import "@oz-4.9.0-up/utils/math/MathUpgradeable.sol";
import "@oz-4.9.0-up/proxy/utils/Initializable.sol";

import "./interfaces/IERC20.sol";
import "./interfaces/IRewardsDistributor.sol";
import "./interfaces/IVotingEscrow.sol";

/*

@title Curve Fee Distribution modified for ve(3,3) emissions
@author Curve Finance, andrecronje
@license MIT

*/

contract RewardsDistributor is IRewardsDistributor, Initializable {
    event CheckpointToken(uint256 time, uint256 tokens);

    event Claimed(
        uint256 tokenId,
        uint256 amount,
        uint256 claim_epoch,
        uint256 max_epoch
    );

    event ClaimedFromMerged(uint256 tokenId, uint256 amount);

    uint256 constant WEEK = 1 weeks;

    uint256 public startTime;
    uint256 public timeCursor;
    uint256 public lastTokenTime;
    uint256 public tokenLastBalance;

    uint256[1000000000000000] public tokensPerWeek;
    uint256[1000000000000000] public veSupply;

    mapping(uint256 => uint256) public timeCursorOf;
    mapping(uint256 => uint256) public userEpochOf;
    mapping(uint256 => uint256) public claimableFromMerged; /// @dev tokenId => claimable amount

    address public votingEscrow;
    address public emissionsToken;

    address public minter;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _votingEscrow,
        address _minter
    ) external initializer {
        uint256 _t = (block.timestamp / WEEK) * WEEK;
        startTime = _t;
        lastTokenTime = _t;
        timeCursor = _t;
        address _emissionsToken = IVotingEscrow(_votingEscrow).emissionsToken();
        emissionsToken = _emissionsToken;
        votingEscrow = _votingEscrow;
        minter = _minter;
        IERC20(_emissionsToken).approve(_votingEscrow, type(uint256).max);
    }

    function timestamp() external view returns (uint256) {
        return (block.timestamp / WEEK) * WEEK;
    }

    function _checkpointToken() internal {
        uint256 tokenBalance = IERC20(emissionsToken).balanceOf(address(this));
        uint256 toDistribute = tokenBalance - tokenLastBalance;
        tokenLastBalance = tokenBalance;

        uint256 t = lastTokenTime;
        /// @dev uint256 since_last = block.timestamp - t;
        lastTokenTime = block.timestamp;
        uint256 thisWeek = (t / WEEK) * WEEK;
        uint256 nextWeek = 0;
        uint256 weeksToCatchUp = ((block.timestamp / WEEK) * WEEK - thisWeek) /
            WEEK;

        for (uint256 i = 0; i < 20; i++) {
            nextWeek = thisWeek + WEEK;

            if (block.timestamp < nextWeek) {
                break;
            }
            tokensPerWeek[nextWeek] += toDistribute / weeksToCatchUp;
            thisWeek = nextWeek;
        }
        emit CheckpointToken(block.timestamp, toDistribute);
    }

    function checkpointToken() external {
        assert(msg.sender == minter);
        _checkpointToken();
    }

    function _findTimestampEpoch(
        address ve,
        uint256 _timestamp
    ) internal view returns (uint256) {
        uint256 _min = 0;
        uint256 _max = IVotingEscrow(ve).epoch();
        for (uint256 i = 0; i < 128; i++) {
            if (_min >= _max) {
                break;
            }
            uint256 _mid = (_min + _max + 2) / 2;
            IVotingEscrow.Point memory pt = IVotingEscrow(ve).pointHistory(
                _mid
            );
            if (pt.ts <= _timestamp) {
                _min = _mid;
            } else {
                _max = _mid - 1;
            }
        }
        return _min;
    }

    function _findTimestampUserEpoch(
        address ve,
        uint256 tokenId,
        uint256 _timestamp,
        uint256 max_user_epoch
    ) internal view returns (uint256) {
        uint256 _min = 0;
        uint256 _max = max_user_epoch;
        for (uint256 i = 0; i < 128; i++) {
            if (_min >= _max) {
                break;
            }
            uint256 _mid = (_min + _max + 2) / 2;
            IVotingEscrow.Point memory pt = IVotingEscrow(ve).userPointHistory(
                tokenId,
                _mid
            );
            if (pt.ts <= _timestamp) {
                _min = _mid;
            } else {
                _max = _mid - 1;
            }
        }
        return _min;
    }

    function veForAt(
        uint256 _tokenId,
        uint256 _timestamp
    ) external view returns (uint256) {
        address ve = votingEscrow;
        uint256 maxUserEpoch = IVotingEscrow(ve).userPointEpoch(_tokenId);
        uint256 epoch = _findTimestampUserEpoch(
            ve,
            _tokenId,
            _timestamp,
            maxUserEpoch
        );
        IVotingEscrow.Point memory pt = IVotingEscrow(ve).userPointHistory(
            _tokenId,
            epoch
        );
        return
            MathUpgradeable.max(
                uint256(
                    int256(
                        pt.bias -
                            pt.slope *
                            (int128(int256(_timestamp - pt.ts)))
                    )
                ),
                0
            );
    }

    function _checkpointTotalSupply() internal {
        address ve = votingEscrow;
        uint256 t = timeCursor;
        uint256 roundedTimestamp = ((block.timestamp - 1) / WEEK) * WEEK; /// @dev to ensure ve balance cannot change anymore
        IVotingEscrow(ve).checkpoint();

        for (uint256 i = 0; i < 20; i++) {
            if (t > roundedTimestamp) {
                break;
            } else {
                uint256 epoch = _findTimestampEpoch(ve, t);
                IVotingEscrow.Point memory pt = IVotingEscrow(ve).pointHistory(
                    epoch
                );
                int128 dt = 0;
                if (t > pt.ts) {
                    dt = int128(int256(t - pt.ts));
                }
                veSupply[t] = MathUpgradeable.max(
                    uint256(int256(pt.bias - pt.slope * dt)),
                    0
                );
            }
            t += WEEK;
        }
        timeCursor = t;
    }

    function checkpointTotalSupply() external {
        _checkpointTotalSupply();
    }

    function _claim(
        uint256 _tokenId,
        address ve,
        uint256 _lastTokenTime
    ) internal returns (uint256) {
        uint256 userEpoch = 0;
        uint256 toDistribute = 0;

        uint256 maxUserEpoch = IVotingEscrow(ve).userPointEpoch(_tokenId);
        uint256 _startTime = startTime;

        if (maxUserEpoch == 0) {
            return 0;
        }

        uint256 weekCursor = timeCursorOf[_tokenId];

        if (weekCursor == 0) {
            userEpoch = _findTimestampUserEpoch(
                ve,
                _tokenId,
                _startTime,
                maxUserEpoch
            );
        } else {
            userEpoch = userEpochOf[_tokenId];
        }

        if (userEpoch == 0) {
            userEpoch = 1;
        }

        IVotingEscrow.Point memory user_point = IVotingEscrow(ve)
            .userPointHistory(_tokenId, userEpoch);

        if (weekCursor == 0) {
            weekCursor = ((user_point.ts + WEEK - 1) / WEEK) * WEEK;
        }

        if (weekCursor > lastTokenTime) {
            return 0;
        }

        if (weekCursor < _startTime) {
            weekCursor = _startTime;
        }

        /// @dev IVotingEscrow.Point memory old_user_point;

        for (uint256 i = 0; i < 50; i++) {
            if (weekCursor > _lastTokenTime) {
                break;
            }

            uint256 balance_of = IVotingEscrow(ve).balanceOfNFTAt(
                _tokenId,
                weekCursor
            );
            if (balance_of == 0 && userEpoch > maxUserEpoch) {
                break;
            }
            if (balance_of > 0 && veSupply[weekCursor] > 0) {
                toDistribute +=
                    (balance_of * tokensPerWeek[weekCursor]) /
                    veSupply[weekCursor];
            }
            weekCursor += WEEK;
        }

        userEpoch = MathUpgradeable.min(maxUserEpoch, userEpoch - 1);
        userEpochOf[_tokenId] = userEpoch;
        timeCursorOf[_tokenId] = weekCursor;

        emit Claimed(_tokenId, toDistribute, userEpoch, maxUserEpoch);

        return toDistribute;
    }

    function _claimable(
        uint256 _tokenId,
        address ve,
        uint256 _lastTokenTime
    ) internal view returns (uint256) {
        uint256 userEpoch = 0;
        uint256 toDistribute = 0;

        /// @dev Add claimable from merged tokenIds
        toDistribute += claimableFromMerged[_tokenId];

        uint256 maxUserEpoch = IVotingEscrow(ve).userPointEpoch(_tokenId);
        uint256 _startTime = startTime;

        if (maxUserEpoch == 0) {
            return toDistribute;
        }

        uint256 weekCursor = timeCursorOf[_tokenId];
        if (weekCursor == 0) {
            userEpoch = _findTimestampUserEpoch(
                ve,
                _tokenId,
                _startTime,
                maxUserEpoch
            );
        } else {
            userEpoch = userEpochOf[_tokenId];
        }

        if (userEpoch == 0) {
            userEpoch = 1;
        }

        IVotingEscrow.Point memory user_point = IVotingEscrow(ve)
            .userPointHistory(_tokenId, userEpoch);

        if (weekCursor == 0) {
            weekCursor = ((user_point.ts + WEEK - 1) / WEEK) * WEEK;
        }
        if (weekCursor > lastTokenTime) {
            return toDistribute;
        }
        if (weekCursor < _startTime) {
            weekCursor = _startTime;
        }

        /// @dev IVotingEscrow.Point memory old_user_point;

        for (uint256 i = 0; i < 50; i++) {
            if (weekCursor > _lastTokenTime) {
                break;
            }

            uint256 balance_of = IVotingEscrow(ve).balanceOfNFTAt(
                _tokenId,
                weekCursor
            );
            if (balance_of == 0 && userEpoch > maxUserEpoch) {
                break;
            }
            if (balance_of > 0 && veSupply[weekCursor] > 0) {
                toDistribute +=
                    (balance_of * tokensPerWeek[weekCursor]) /
                    veSupply[weekCursor];
            }
            weekCursor += WEEK;
        }

        return toDistribute;
    }

    function claimable(uint256 _tokenId) external view returns (uint256) {
        uint256 _last_token_time = (lastTokenTime / WEEK) * WEEK;
        return _claimable(_tokenId, votingEscrow, _last_token_time);
    }

    function claim(uint256 _tokenId) public returns (uint256) {
        IVotingEscrow ve = IVotingEscrow(votingEscrow);

        /// @notice Only owner can claim expansion, if not expired/merged
        require(
            ve.isApprovedOrOwner(msg.sender, _tokenId) ||
                ve.ownerOf(_tokenId) == address(0),
            "ve !AUTH"
        );

        /// @dev > instead of >= timeCursor, to ensure veRA balance cannot change anymore
        if (block.timestamp > timeCursor) {
            _checkpointTotalSupply();
        }
        uint256 _lastTokenTime = lastTokenTime;
        _lastTokenTime = (_lastTokenTime / WEEK) * WEEK;
        uint256 amount = _claim(_tokenId, votingEscrow, _lastTokenTime);

        /// @dev Add claimable from merged tokenIds
        uint256 _claimableFromMerged = claimableFromMerged[_tokenId];
        if (_claimableFromMerged > 0) {
            amount += claimableFromMerged[_tokenId];
            claimableFromMerged[_tokenId] = 0;
            emit ClaimedFromMerged(_tokenId, _claimableFromMerged);
        }

        if (amount != 0) {
            tokenLastBalance -= amount;

            /// @dev Deposit into ve if not expired
            if (ve.locked__end(_tokenId) > block.timestamp) {
                ve.depositFor(_tokenId, amount);
            } else {
                // Check if merged, if not, send tokens
                // If merged, attribute claimable to mergedInto tokenId
                IERC20(emissionsToken).transfer(ve.ownerOf(_tokenId), amount);
                // uint256 mergedInto = ve.mergedInto(_tokenId);
                // if (mergedInto == 0) {
                //     IERC20(token).transfer(ve.ownerOf(_tokenId), amount);
                // } else {
                //     claimableFromMerged[mergedInto] += amount;
                // }
            }
        }
        return amount;
    }

    /// @notice Claims multiple ve rebases simulatenously in a loop
    function claimMany(uint256[] memory _tokenIds) external returns (bool) {
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            claim(_tokenIds[i]);
        }

        return true;
    }
}
