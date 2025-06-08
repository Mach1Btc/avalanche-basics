// SPDX-License-Identifier: MIT
pragma solidity =0.7.6 || ^0.8.13;
pragma abicoder v2;

interface IVoter {
    function _ve() external view returns (address);

    function governor() external view returns (address);

    function attachTokenToGauge(uint256 _tokenId, address account) external;

    function detachTokenFromGauge(uint256 _tokenId, address account) external;

    function emitDeposit(
        uint256 _tokenId,
        address account,
        uint256 amount
    ) external;

    function emitWithdraw(
        uint256 _tokenId,
        address account,
        uint256 amount
    ) external;

    function isWhitelisted(address token) external view returns (bool);

    function notifyRewardAmount(uint256 amount) external;

    function distribute(address _gauge) external;

    function gauges(address pool) external view returns (address);

    function feeDistributors(address gauge) external view returns (address);

    function gaugefactory() external view returns (address);

    function feeDistributorFactory() external view returns (address);

    function minter() external view returns (address);

    function factory() external view returns (address);

    function length() external view returns (uint256);

    function pools(uint256) external view returns (address);

    function isAlive(address) external view returns (bool);

    function setXRatio(uint256 _xRatio) external;

    function setGaugeXRatio(
        address[] calldata _gauges,
        uint256[] calldata _xRaRatios
    ) external;

    function resetGaugeXRatio(address[] calldata _gauges) external;

    function whitelist(address _token) external;

    function forbid(address _token, bool _status) external;

    function whitelistOperator() external view returns (address);

    function gaugeXRatio(address gauge) external view returns (uint256);

    function isGauge(address gauge) external view returns (bool);

    function killGauge(address _gauge) external;

    function reviveGauge(address _gauge) external;

    function stale(uint256 _tokenID) external view returns (bool);

    function partnerNFT(uint256 _tokenID) external view returns (bool);

    function newStale(uint256 _tokenID) external view returns (bool);

    function base() external view returns (address);

    function xToken() external view returns (address);

    function addClGaugeReward(address gauge, address reward) external;

    function removeClGaugeReward(address gauge, address reward) external;

    function clawBackUnusedEmissions(address[] calldata _gauges) external;

    function addInitialRewardPerGauge(address _gauge, address token) external;

    function customGaugeForPool(
        address pool
    ) external view returns (address customGauge);
}
