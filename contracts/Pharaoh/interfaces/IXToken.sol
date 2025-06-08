// SPDX-License-Identifier: MIT
pragma solidity >=0.7.0 <0.9.0;

interface IXToken {
    event CancelVesting(
        address indexed user,
        uint256 indexed vestId,
        uint256 amount
    );
    event ExitVesting(
        address indexed user,
        uint256 indexed vestId,
        uint256 amount
    );
    event InstantExit(address indexed user, uint256);

    event NewExitRatios(uint256 exitRatio, uint256 veExitRatio);

    event NewVest(
        address indexed user,
        uint256 indexed vestId,
        uint256 indexed amount
    );
    event NewVestingTimes(uint256 min, uint256 max, uint256 veMaxVest);

    event Converted(address indexed user, uint256);

    event WhitelistStatus(address indexed candidate, bool status);

    event XTokensRedeemed(address indexed user, uint256);

    function MAXTIME() external view returns (uint256);

    function PRECISION() external view returns (uint256);

    function addWhitelist(address _whitelistee) external;

    function adjustWhitelist(
        address[] memory _candidates,
        bool[] memory _status
    ) external;

    function alterExitRatios(
        uint256 _newExitRatio,
        uint256 _newVeExitRatio
    ) external;

    function changeMaximumVestingLength(uint256 _maxVest) external;

    function changeMinimumVestingLength(uint256 _minVest) external;

    function changeVeMaximumVestingLength(uint256 _veMax) external;

    function changeWhitelistOperator(address _newOperator) external;

    function convertEmissionsToken(uint256 _amount) external;

    function createVest(uint256 _amount) external;

    function protocolWhitelist() external view returns (address);

    function exitRatio() external view returns (uint256);

    function exitVest(uint256 _vestID, bool _ve) external returns (bool);

    function getBalanceResiding() external view returns (uint256);

    function initialize(
        address _emissionsToken,
        address _votingEscrow,
        address _voter,
        address _timelock,
        address _multisig,
        address _whitelistOperator,
        address _enneadWhitelist
    ) external;

    function instantExit(uint256 _amount, uint256 maxPayAmount) external;

    function isWhitelisted(address) external view returns (bool);

    function maxVest() external view returns (uint256);

    function migrateProtocolWhitelist(address _enneadWhitelist) external;

    function migrateMultisig(address _multisig) external;

    function migrateTimelock(address _timelock) external;

    function minVest() external view returns (uint256);

    function multisig() external view returns (address);

    function multisigRedeem(uint256 _amount) external;

    function emissionsToken() external view returns (address);

    function reinitializeVestingParameters(
        uint256 _min,
        uint256 _max,
        uint256 _veMax
    ) external;

    function removeWhitelist(address _whitelistee) external;

    function rescueTrappedTokens(
        address[] memory _tokens,
        uint256[] memory _amounts
    ) external;

    function syncAndCheckIsWhitelisted(
        address _address
    ) external returns (bool);

    function timelock() external view returns (address);

    function usersTotalVests(address _user) external view returns (uint256);

    function veExitRatio() external view returns (uint256);

    function veMaxVest() external view returns (uint256);

    function votingEscrow() external view returns (address);

    function vestInfo(
        address user,
        uint256
    )
        external
        view
        returns (uint256 amount, uint256 start, uint256 maxEnd, uint256 vestID);

    function voter() external view returns (address);

    function whitelistOperator() external view returns (address);

    function xTokenConvertToNft(
        uint256 _amount
    ) external returns (uint256 veRaTokenId);

    function xTokenIncreaseNft(uint256 _amount, uint256 _tokenID) external;

    function setPool(address newPool) external;

    function useLegacyPair(bool legacy) external;
}
