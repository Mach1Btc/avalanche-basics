// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@oz-4.9.0/proxy/utils/Initializable.sol";
import "@oz-4.9.0/proxy/beacon/IBeacon.sol";

import "../PairBeaconProxy.sol";

import ".././interfaces/IPairFactory.sol";
import ".././interfaces/IPair.sol";

contract PairFactory is IPairFactory, Initializable, IBeacon {
    bool public isPaused;

    address public pauser;
    address public pendingPauser;
    address public voter;
    address public feeManager;
    address public pendingFeeManager;
    address public treasury;
    address public owner;
    address public implementation;

    uint256 public stableFee;
    uint256 public volatileFee;
    uint256 public constant MAX_FEE = 1000; // 10%

    /// @notice default fee split %
    uint8 public feeSplit;

    mapping(address => uint8) poolFeeSplit;

    mapping(address => mapping(address => mapping(bool => address)))
        public getPair;
    address[] public allPairs;
    mapping(address => bool) public isPair; // simplified check if its a pair, given that `stable` flag might not be available in peripherals

    // pair => fee
    mapping(address pair => uint256 fee) _pairFee;

    event SetFeeSplit(
        uint8 toFeesOld,
        uint8 toTreasuryOld,
        uint8 toFeesNew,
        uint8 toTreasuryNew
    );

    event SetPoolFeeSplit(
        address pool,
        uint8 toFeesOld,
        uint8 toTreasuryOld,
        uint8 toFeesNew,
        uint8 toTreasuryNew
    );

    /// @notice Emitted when pairs implementation is changed
    /// @param oldImplementation The previous implementation
    /// @param newImplementation The new implementation
    event ImplementationChanged(
        address indexed oldImplementation,
        address indexed newImplementation
    );

    /// @notice Emitted when the owner of the factory is changed
    /// @param oldOwner The owner before the owner was changed
    /// @param newOwner The owner after the owner was changed
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);

    event PairCreated(
        address indexed token0,
        address indexed token1,
        bool stable,
        address pair,
        uint256
    );

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _voter,
        address msig,
        address _owner,
        address _implementation
    ) external initializer {
        pauser = msig;
        isPaused = true;
        feeManager = msig;
        stableFee = 5; // 0.05%
        volatileFee = 25; //0.25%
        voter = _voter;
        treasury = msig;
        owner = _owner;
        implementation = _implementation;
    }

    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    function setPauser(address _pauser) external {
        require(msg.sender == pauser);
        pendingPauser = _pauser;
    }

    function acceptPauser() external {
        require(msg.sender == pendingPauser);
        pauser = pendingPauser;
    }

    function setPause(bool _state) external {
        require(msg.sender == pauser);
        isPaused = _state;
    }

    function setFeeManager(address _feeManager) external {
        require(msg.sender == feeManager, "not fee manager");
        pendingFeeManager = _feeManager;
    }

    function acceptFeeManager() external {
        require(msg.sender == pendingFeeManager, "not pending fee manager");
        feeManager = pendingFeeManager;
    }

    function setFee(bool _stable, uint256 _fee) external {
        require(msg.sender == feeManager, "not fee manager");
        require(_fee <= MAX_FEE, "fee too high");
        require(_fee != 0, "fee must be nonzero");
        if (_stable) {
            stableFee = _fee;
        } else {
            volatileFee = _fee;
        }
    }

    function setPairFee(address _pair, uint256 _fee) external {
        require(msg.sender == feeManager, "not fee manager");
        require(_fee <= MAX_FEE, "fee too high");
        _pairFee[_pair] = _fee;
    }

    function getFee(bool _stable) public view returns (uint256) {
        if (_pairFee[msg.sender] == 0) {
            return _stable ? stableFee : volatileFee;
        } else {
            return _pairFee[msg.sender];
        }
    }

    function pairFee(address _pool) external view returns (uint256 fee) {
        if (_pairFee[_pool] == 0) {
            fee = IPair(_pool).stable() ? stableFee : volatileFee;
        } else {
            fee = _pairFee[_pool];
        }
    }

    /// @notice set % of fees that will be compounded and % that will go to treasury
    /// @param _toFees percent of trade fees that will be sent to PairFees
    /// @param _toTreasury percent of trade fees that will be sent to treasury
    function setFeeSplit(uint8 _toFees, uint8 _toTreasury) external {
        require(msg.sender == feeManager, "!AUTH");

        require(_toFees <= 10 && _toTreasury <= 10, "FTL");

        require(((_toFees * 5) + (_toTreasury * 5)) <= 100);

        uint8 oldFeeSplit = feeSplit;

        feeSplit = _toFees + (_toTreasury << 4);

        emit SetFeeSplit(
            oldFeeSplit % 16,
            oldFeeSplit >> 4,
            _toFees,
            _toTreasury
        );
    }

    function setPoolFeeSplit(
        address _pool,
        uint8 _toFees,
        uint8 _toTreasury
    ) external {
        require(msg.sender == feeManager, "!AUTH");

        require(_toFees <= 10 && _toTreasury <= 10, "FTL");

        require(((_toFees * 5) + (_toTreasury * 5)) <= 100);

        uint8 oldFeeSplit = getPoolFeeSplit(_pool);

        poolFeeSplit[_pool] = _toFees + (_toTreasury << 4);

        emit SetPoolFeeSplit(
            _pool,
            oldFeeSplit % 16,
            oldFeeSplit >> 4,
            _toFees,
            _toTreasury
        );

        IPair(_pool).setFeeSplit();
    }

    function getPoolFeeSplit(
        address _pool
    ) public view returns (uint8 _poolFeeSplit) {
        _poolFeeSplit = poolFeeSplit[_pool];

        if (_poolFeeSplit == 0) {
            _poolFeeSplit = feeSplit;
        }
    }

    function setTreasury(address _treasury) external {
        require(msg.sender == treasury, "!AUTH");
        treasury = _treasury;
    }

    function pairCodeHash() external pure returns (bytes32) {
        return keccak256(abi.encodePacked(type(PairBeaconProxy).creationCode));
    }

    function createPair(
        address tokenA,
        address tokenB,
        bool stable
    ) external returns (address pair) {
        require(!isPaused, "PAUSED");
        require(tokenA != tokenB, "IA"); // Pair: IDENTICAL_ADDRESSES
        (address token0, address token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);
        require(token0 != address(0), "ZA"); // Pair: ZERO_ADDRESS
        require(getPair[token0][token1][stable] == address(0), "PE"); // Pair: PAIR_EXISTS - single check is sufficient

        bytes32 salt = keccak256(abi.encodePacked(token0, token1, stable));

        pair = address(new PairBeaconProxy{salt: salt}());

        IPair(pair).initialize(address(this), token0, token1, stable, voter);
        IPair(pair).setFeeSplit();

        getPair[token0][token1][stable] = pair;
        getPair[token1][token0][stable] = pair; // populate mapping in the reverse direction
        allPairs.push(pair);
        isPair[pair] = true;

        emit PairCreated(token0, token1, stable, pair, allPairs.length);
    }

    function setImplementation(address _implementation) external {
        require(msg.sender == owner, "AUTH");
        emit ImplementationChanged(implementation, _implementation);
        implementation = _implementation;
    }

    function setOwner(address _owner) external {
        require(msg.sender == owner, "AUTH");
        emit OwnerChanged(owner, _owner);
        owner = _owner;
    }
}
