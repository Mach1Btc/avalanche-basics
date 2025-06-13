// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13 || =0.7.6;

interface IPair {
    function initialize(
        address _factory,
        address _token0,
        address _token1,
        bool _stable,
        address _voter
    ) external;

    function metadata()
        external
        view
        returns (
            uint256 dec0,
            uint256 dec1,
            uint256 r0,
            uint256 r1,
            bool st,
            address t0,
            address t1
        );

    function claimFees() external returns (uint256, uint256);

    function tokens() external view returns (address, address);

    function transferFrom(
        address src,
        address dst,
        uint256 amount
    ) external returns (bool);

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;

    function burn(
        address to
    ) external returns (uint256 amount0, uint256 amount1);

    function mint(address to) external returns (uint256 liquidity);

    function getReserves()
        external
        view
        returns (
            uint256 _reserve0,
            uint256 _reserve1,
            uint256 _blockTimestampLast
        );

    function getAmountOut(
        uint256 amountIn,
        address tokenIn
    ) external view returns (uint256);

    function symbol() external view returns (string memory);

    function fees() external view returns (address);

    function setActiveGauge(bool isActive) external;

    function setFeeSplit() external;

    function feeSplit() external view returns (uint8 _feeSplit);

    function stable() external view returns (bool stable);
}
