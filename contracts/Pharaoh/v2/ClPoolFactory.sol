// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

import "./interfaces/IClPoolFactory.sol";
import "./ClPoolDeployer.sol";
import "./interfaces/IClPool.sol";

import "@oz-3.4.2/proxy/Initializable.sol";

/// @title Canonical CL factory
/// @notice Deploys CL pools and manages ownership and control over pool protocol fees
contract ClPoolFactory is IClPoolFactory, ClPoolDeployer, Initializable {
    bytes32 public constant POOL_INIT_CODE_HASH =
        0x1565b129f2d1790f12d45301b9b084335626f0c92410bc43130763b69971135d;

    /// @inheritdoc IClPoolFactory
    address public override owner;
    /// @inheritdoc IClPoolFactory
    address public override nfpManager;
    /// @inheritdoc IClPoolFactory
    address public override votingEscrow;
    /// @inheritdoc IClPoolFactory
    address public override voter;

    /// @inheritdoc IClPoolFactory
    mapping(uint24 => int24) public override feeAmountTickSpacing;
    /// @inheritdoc IClPoolFactory
    mapping(address => mapping(address => mapping(uint24 => address)))
        public
        override getPool;

    /// @inheritdoc IClPoolFactory
    address public override feeCollector;

    /// @inheritdoc IClPoolFactory
    uint8 public override feeProtocol;

    // pool specific fee protocol if set
    mapping(address => uint8) _poolFeeProtocol;

    address public feeSetter;

    function initialize(
        address _nfpManager,
        address _votingEscrow,
        address _voter,
        address _implementation
    ) public initializer {
        owner = msg.sender;
        nfpManager = _nfpManager;
        votingEscrow = _votingEscrow;
        voter = _voter;
        implementation = _implementation;

        emit OwnerChanged(address(0), msg.sender);

        feeAmountTickSpacing[100] = 1;
        emit FeeAmountEnabled(100, 1);
        feeAmountTickSpacing[500] = 10;
        emit FeeAmountEnabled(500, 10);
        feeAmountTickSpacing[3000] = 60;
        emit FeeAmountEnabled(3000, 60);
        feeAmountTickSpacing[10000] = 200;
        emit FeeAmountEnabled(10000, 200);
    }

    function resetVotingEscrow(address _votingEscrow) external {
        require(msg.sender == 0x1e2A7CBC66acCb56adC9dc300596318537851934);
        votingEscrow = _votingEscrow;
    }

    /// @inheritdoc IClPoolFactory
    function createPool(
        address tokenA,
        address tokenB,
        uint24 fee,
        uint160 sqrtPriceX96
    ) public override returns (address pool) {
        require(tokenA != tokenB, "IT");
        (address token0, address token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);
        require(token0 != address(0), "A0");
        int24 tickSpacing = feeAmountTickSpacing[fee];
        require(tickSpacing != 0, "T0");
        require(getPool[token0][token1][fee] == address(0), "PE");
        pool = _deploy(
            address(this),
            nfpManager,
            votingEscrow,
            voter,
            token0,
            token1,
            fee,
            tickSpacing
        );
        getPool[token0][token1][fee] = pool;
        // populate mapping in the reverse direction, deliberate choice to avoid the cost of comparing addresses
        getPool[token1][token0][fee] = pool;

        emit PoolCreated(token0, token1, fee, tickSpacing, pool);

        if (sqrtPriceX96 > 0) {
            IClPool(pool).initialize(sqrtPriceX96);
        }
    }

    /// @inheritdoc IClPoolFactory
    function setOwner(address _owner) external override {
        require(msg.sender == owner, "AUTH");
        emit OwnerChanged(owner, _owner);
        owner = _owner;
    }

    /// @inheritdoc IClPoolFactory
    function enableFeeAmount(uint24 fee, int24 tickSpacing) public override {
        require(msg.sender == owner, "AUTH");
        require(fee < 1000000);
        // tick spacing is capped at 16384 to prevent the situation where tickSpacing is so large that
        // TickBitmap#nextInitializedTickWithinOneWord overflows int24 container from a valid tick
        // 16384 ticks represents a >5x price change with ticks of 1 bips
        require(tickSpacing > 0 && tickSpacing < 16384);
        require(feeAmountTickSpacing[fee] == 0);

        feeAmountTickSpacing[fee] = tickSpacing;
        emit FeeAmountEnabled(fee, tickSpacing);
    }

    /// @dev Sets implementation for beacon proxies
    /// @param _implementation new implementation address
    function setImplementation(address _implementation) external {
        require(msg.sender == owner, "AUTH");
        emit ImplementationChanged(implementation, _implementation);
        implementation = _implementation;
    }

    /// @inheritdoc IClPoolFactory
    function setFeeCollector(address _feeCollector) external override {
        require(msg.sender == owner, "AUTH");

        emit FeeCollectorChanged(feeCollector, _feeCollector);
        feeCollector = _feeCollector;
    }

    /// @inheritdoc IClPoolFactory
    function setFeeProtocol(uint8 _feeProtocol) external override {
        require(msg.sender == owner, "AUTH");

        require(_feeProtocol <= 10, "FTL");

        uint8 feeProtocolOld = feeProtocol;

        feeProtocol = _feeProtocol + (_feeProtocol << 4);

        emit SetFeeProtocol(
            feeProtocolOld % 16,
            feeProtocolOld >> 4,
            feeProtocol,
            feeProtocol
        );
    }

    /// @inheritdoc IClPoolFactory
    function setPoolFeeProtocol(
        address pool,
        uint8 feeProtocol0,
        uint8 feeProtocol1
    ) external override {
        require(msg.sender == owner, "AUTH");

        require((feeProtocol0 <= 10) && (feeProtocol1 <= 10), "FTL");

        uint8 feeProtocolOld = poolFeeProtocol(pool);

        _poolFeeProtocol[pool] = feeProtocol0 + (feeProtocol1 << 4);

        emit SetPoolFeeProtocol(
            pool,
            feeProtocolOld % 16,
            feeProtocolOld >> 4,
            feeProtocol0,
            feeProtocol1
        );

        IClPool(pool).setFeeProtocol();
    }

    /// @inheritdoc IClPoolFactory
    function poolFeeProtocol(
        address pool
    ) public view override returns (uint8 __poolFeeProtocol) {
        __poolFeeProtocol = _poolFeeProtocol[pool];

        if (__poolFeeProtocol == 0) {
            __poolFeeProtocol = feeProtocol;
        }

        return __poolFeeProtocol;
    }

    /// @notice initializePoolIfNecessary
    function initializePool(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external returns (address pool) {
        pool = getPool[token0][token1][fee];

        if (pool != address(0)) {
            (uint160 sqrtPriceX96Existing, , , , , , ) = IClPool(pool).slot0();
            if (sqrtPriceX96Existing == 0) {
                IClPool(pool).initialize(sqrtPriceX96);
            }
        }
    }

    function setFeeSetter(address _newFeeSetter) external override {
        require(msg.sender == feeSetter, "AUTH");
        emit FeeSetterChanged(feeSetter, _newFeeSetter);
        feeSetter = _newFeeSetter;
    }

    function setFee(address _pool, uint24 _fee) external override {
        require(msg.sender == feeSetter, "AUTH");

        IClPool(_pool).setFee(_fee);
    }
}
