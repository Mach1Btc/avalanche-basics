// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@oz-4.9.0/proxy/utils/Initializable.sol";
import "@oz-4.9.0/utils/math/Math.sol";

import "./interfaces/IFeeDistributor.sol";
import "./interfaces/IFeeDistributorFactory.sol";
import "./interfaces/IGauge.sol";
import "./interfaces/IGaugeFactory.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IMinter.sol";
import "./interfaces/IPair.sol";
import "./interfaces/IPairFactory.sol";
import "./interfaces/IVoter.sol";
import "./interfaces/IVotingEscrow.sol";
import "./interfaces/IXToken.sol";
import "./interfaces/IPairFees.sol";
import "./interfaces/ICustomGaugeFactory.sol";
import "./interfaces/ICustomGauge.sol";

import "./v2/interfaces/IClPoolFactory.sol";
import "./v2/interfaces/IClPool.sol";
import "./v2-staking/interfaces/IClGaugeFactory.sol";
import "./v2-staking/interfaces/INonfungiblePositionManager.sol";
import "./v2-staking/interfaces/IGaugeV2.sol";

contract Voter is IVoter, Initializable {
    address public _ve; // the ve token that governs these contracts
    address public factory; // the PairFactory
    address public base;
    address public gaugefactory;
    address public feeDistributorFactory;
    address public minter;
    address public governor; // should be set to an IGovernor
    address internal deprecated; // credibly neutral party similar to Curve's Emergency DAO
    address public clFactory;
    address public clGaugeFactory;
    address public nfpManager;
    address public whitelistOperator;
    address public xToken;
    address[] public pools; // all pools viable for incentives
    address public timelock;

    uint256 public totalWeight; // total voting weight
    uint256 internal constant DURATION = 7 days; // rewards are released over 7 days
    uint256 internal _unlocked;
    uint256 internal index;
    uint256 public constant BASIS = 10000;
    uint256 public xRatio; // default xToken ratio

    mapping(address => address) public gauges; // pool => gauge
    mapping(address => address) public poolForGauge; // gauge => pool
    mapping(address => address) public feeDistributors; // gauge => fees
    mapping(address => uint256) public weights; // pool => weight
    mapping(uint256 => mapping(address => uint256)) public votes; // nft => pool => votes
    mapping(uint256 => address[]) public poolVote; // nft => pools
    mapping(uint256 => uint256) public usedWeights; // nft => total voting weight of user
    mapping(uint256 => uint256) public lastVoted; // nft => timestamp of last vote, to ensure one vote per epoch
    mapping(address => bool) public isGauge;
    mapping(address => bool) public isWhitelisted;
    mapping(address => bool) public isAlive;
    mapping(address => uint256) internal supplyIndex;
    mapping(address => uint256) public claimable;
    mapping(address => uint256) _gaugeXRatio; // mapping for specific gauge xToken ratios
    mapping(address => bool) _gaugeXRatioWritten; // mapping for indicating if a gauge has its own xToken ratio
    mapping(address => bool) public isForbidden;
    mapping(uint256 => bool) public partnerNFT;
    mapping(uint256 => bool) public stale; // deprecated
    // v1.2 newStale
    mapping(uint256 => bool) public newStale;

    address public customGaugeFactory;
    mapping(address pool => address customGauge) public customGaugeForPool;

    // End of storage slots //

    ////////////
    // Events //
    ////////////

    event GaugeCreated(
        address indexed gauge,
        address creator,
        address feeDistributor,
        address indexed pool
    );
    event GaugeKilled(address indexed gauge);
    event GaugeRevived(address indexed gauge);
    event Voted(address indexed voter, uint256 tokenId, uint256 weight);
    event Abstained(uint256 tokenId, uint256 weight);
    event Deposit(
        address indexed lp,
        address indexed gauge,
        uint256 tokenId,
        uint256 amount
    );
    event Withdraw(
        address indexed lp,
        address indexed gauge,
        uint256 tokenId,
        uint256 amount
    );
    event NotifyReward(
        address indexed sender,
        address indexed reward,
        uint256 amount
    );
    event DistributeReward(
        address indexed sender,
        address indexed gauge,
        uint256 amount
    );
    event Attach(address indexed owner, address indexed gauge, uint256 tokenId);
    event Detach(address indexed owner, address indexed gauge, uint256 tokenId);
    event Whitelisted(address indexed whitelister, address indexed token);
    event Forbidden(
        address indexed forbidder,
        address indexed token,
        bool status
    );

    event EmissionsRatio(
        address indexed gauge,
        uint256 oldRatio,
        uint256 newRatio
    );

    event CustomGaugeCreated(
        address indexed gauge,
        address creator,
        address feeDistributor,
        address indexed pool,
        address indexed token
    );

    //////////////////
    // Initializers //
    //////////////////

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address __ve,
        address _factory,
        address _gauges,
        address _feeDistributorFactory,
        address _minter,
        address _msig,
        address[] calldata _tokens,
        address _clFactory,
        address _clGaugeFactory,
        address _nfpManager,
        address _xToken
    ) external initializer {
        _ve = __ve;
        factory = _factory;
        base = IVotingEscrow(__ve).emissionsToken();
        gaugefactory = _gauges;
        feeDistributorFactory = _feeDistributorFactory;
        minter = _minter;
        governor = _msig;
        timelock = IMinter(minter).timelock();

        for (uint256 i = 0; i < _tokens.length; ++i) {
            _whitelist(_tokens[i]);
        }

        clFactory = _clFactory;
        clGaugeFactory = _clGaugeFactory;
        nfpManager = _nfpManager;

        xToken = _xToken;
        xRatio = 5000;
        emit EmissionsRatio(address(0), 0, 5000);
        IERC20(base).approve(_xToken, type(uint256).max);

        _unlocked = 1;
        index = 1;
    }

    function reinitializeFactory(address _factory) external reinitializer(7) {
        factory = _factory;
    }

    function initializeCustomGaugeFactory(
        address _factory
    ) external reinitializer(8) {
        customGaugeFactory = _factory;
    }

    function allPools() external view returns (address[] memory _pools) {
        _pools = pools;
    }

    ///////////////
    // Modifiers //
    ///////////////

    // simple re-entrancy check
    modifier lock() {
        require(_unlocked == 1);
        _unlocked = 2;
        _;
        _unlocked = 1;
    }

    modifier onlyNewEpoch(uint256 _tokenId) {
        // ensure minter is synced
        require(
            block.timestamp < IMinter(minter).activePeriod() + 1 weeks,
            "!EPOCH"
        );
        _;
    }

    modifier onlyTimelock() {
        require(msg.sender == timelock, "AUTH");
        _;
    }

    modifier onlyWhitelistOperators() {
        require(
            msg.sender == whitelistOperator || msg.sender == governor,
            "AUTH"
        );
        _;
    }

    ////////////////////////////////
    // Governance Gated Functions //
    ////////////////////////////////

    function setGovernor(address _governor) public {
        require(msg.sender == governor);
        governor = _governor;
    }

    function setWhitelistOperator(address _whitelistOperator) public {
        require(msg.sender == governor);
        whitelistOperator = _whitelistOperator;
    }

    /// @notice sets the default xTokenRatio
    function setXRatio(uint256 _xRatio) external onlyWhitelistOperators {
        require(_xRatio <= BASIS, ">100%");

        emit EmissionsRatio(address(0), xRatio, _xRatio);
        xRatio = _xRatio;
    }

    /// @notice sets the xTokenRatio of specifics gauges
    function setGaugeXRatio(
        address[] calldata _gauges,
        uint256[] calldata _xRatios
    ) external onlyWhitelistOperators {
        uint256 _length = _gauges.length;
        require(_length == _xRatios.length, "length mismatch");

        for (uint256 i = 0; i < _length; ++i) {
            uint256 _xRatio = _xRatios[i];
            require(_xRatio <= BASIS, ">100%");

            // fetch old xToken ratio for later event
            address _gauge = _gauges[i];
            uint256 oldXRatio = gaugeXRatio(_gauge);

            // write gauge specific xToken ratio
            _gaugeXRatio[_gauge] = _xRatio;
            _gaugeXRatioWritten[_gauge] = true;

            emit EmissionsRatio(_gauge, oldXRatio, _xRatio);
        }
    }

    /// @notice resets the xTokenRatio of specifics gauges back to default
    function resetGaugeXRatio(
        address[] calldata _gauges
    ) external onlyWhitelistOperators {
        uint256 _xRatio = xRatio;
        uint256 _length = _gauges.length;
        for (uint256 i = 0; i < _length; ++i) {
            // fetch old xToken ratio for later event
            address _gauge = _gauges[i];
            uint256 oldXTokenRatio = gaugeXRatio(_gauge);

            // reset _gaugexTokenRatioWritten
            _gaugeXRatioWritten[_gauge] = false;
            // it's ok to leave _gaugexTokenRatio dirty, it's going to be overwriten when it's activated again

            emit EmissionsRatio(_gauge, oldXTokenRatio, _xRatio);
        }
    }

    function whitelist(address _token) public onlyWhitelistOperators {
        _whitelist(_token);
    }

    function forbid(
        address _token,
        bool forbidden
    ) public onlyWhitelistOperators {
        _forbid(_token, forbidden);
    }

    function _whitelist(address _token) internal {
        require(!isWhitelisted[_token]);
        isWhitelisted[_token] = true;
        emit Whitelisted(msg.sender, _token);
    }

    function _forbid(address _token, bool _status) internal {
        // forbid can happen before whitelisting
        if (isForbidden[_token] != _status) {
            isForbidden[_token] = _status;
            emit Forbidden(msg.sender, _token, _status);
        }
    }

    function killGauge(address _gauge) external onlyWhitelistOperators {
        require(isAlive[_gauge], "DEAD");
        isAlive[_gauge] = false;
        address pool = poolForGauge[_gauge];

        // we call a function that doesn't exist in a CL pool to confirm that it is a legacy pool
        (bool success, ) = pool.staticcall(
            abi.encodeWithSelector(IPair.feeSplit.selector)
        );

        // If it is a legacy pool we set activeGauge to false so most fees are compounded into the pool
        if (success) {
            IPair(pool).setActiveGauge(false);
        }

        emit GaugeKilled(_gauge);
    }

    function reviveGauge(address _gauge) external onlyWhitelistOperators {
        require(!isAlive[_gauge], "ALIVE");
        isAlive[_gauge] = true;
        address pool = poolForGauge[_gauge];

        // we call a function that doesn't exist in a CL pool to confirm that it is a legacy pool
        (bool success, ) = pool.staticcall(
            abi.encodeWithSelector(IPair.feeSplit.selector)
        );

        // If it is a legacy pool we set activeGauge to true
        if (success) {
            IPair(pool).setActiveGauge(true);
        }
        emit GaugeRevived(_gauge);
    }

    function recoverFees(
        address[] calldata fees,
        address[][] calldata tokens
    ) external {
        address _governor = governor;
        require(msg.sender == _governor, "AUTH");
        for (uint256 i; i < fees.length; ++i) {
            for (uint256 j; j < tokens[i].length; ++j) {
                IPairFees(fees[i]).recoverFees(tokens[i][j], _governor);
            }
        }
    }

    ///@dev designates a partner veNFT as stale
    function designateStale(uint256 _tokenId, bool _status) external {
        require(msg.sender == governor, "!GOV");
        require(partnerNFT[_tokenId] == true, "!P");
        newStale[_tokenId] = _status;
        _reset(_tokenId);
    }

    function designateStaleLegacy(uint256 _tokenId) external {
        require(
            msg.sender == 0xAAA3fB20e0bE25F09E80D02681b6a99d600403Ba,
            "!rectifier"
        );
        stale[_tokenId] = true;
        _reset(_tokenId);
    }

    ///@dev designates a veNFT as a partner veNFT
    function designatePartnerNFT(uint256 _tokenId, bool _status) external {
        require(msg.sender == governor, "!GOV");
        if (!_status && newStale[_tokenId]) {
            newStale[_tokenId] = false;
        }
        partnerNFT[_tokenId] = _status;
    }

    ///@dev in case of emission stuck due to killed gauges and unsupported operations
    function stuckEmissionsRecovery(address _gauge) external {
        require(msg.sender == governor, "!GOV");

        IMinter(minter).updatePeriod();
        _updateFor(_gauge);

        if (!isAlive[_gauge]) {
            uint256 _claimable = claimable[_gauge];
            delete claimable[_gauge];
            if (_claimable > 0) {
                IERC20(base).transfer(governor, _claimable);
            }
        }
    }

    function addInitialRewardPerGauge(
        address _gauge,
        address _token
    ) external onlyWhitelistOperators {
        IGauge(_gauge).addInitialReward(_token);
    }

    function addClGaugeReward(
        address gauge,
        address reward
    ) external onlyWhitelistOperators {
        IGaugeV2(gauge).addRewards(reward);
    }

    function removeClGaugeReward(
        address gauge,
        address reward
    ) external onlyWhitelistOperators {
        IGaugeV2(gauge).removeRewards(reward);
    }

    /// @notice clawback claimable for dead gauges to treasury
    function clawBackUnusedEmissions(
        address[] calldata _gauges
    ) external onlyWhitelistOperators {
        IMinter(minter).updatePeriod();

        for (uint256 i; i < _gauges.length; i++) {
            _updateFor(_gauges[i]);

            if (!isAlive[_gauges[i]]) {
                uint256 _claimable = claimable[_gauges[i]];
                delete claimable[_gauges[i]];
                if (_claimable > 0) {
                    IERC20(base).transfer(governor, _claimable);
                }
            }
        }
    }

    ////////////
    // Voting //
    ////////////

    function reset(uint256 _tokenId) external onlyNewEpoch(_tokenId) {
        require(
            IVotingEscrow(_ve).isApprovedOrOwner(msg.sender, _tokenId) ||
                IVotingEscrow(_ve).isDelegate(msg.sender, _tokenId),
            "!approved"
        );
        lastVoted[_tokenId] = (block.timestamp / DURATION) * DURATION;
        _reset(_tokenId);
        IVotingEscrow(_ve).abstain(_tokenId);
    }

    function _reset(uint256 _tokenId) internal {
        address[] storage _poolVote = poolVote[_tokenId];
        uint256 _poolVoteCnt = _poolVote.length;
        uint256 _totalWeight = 0;

        for (uint256 i = 0; i < _poolVoteCnt; ++i) {
            address _pool = _poolVote[i];
            uint256 _votes = votes[_tokenId][_pool];

            if (_votes != 0) {
                _updateFor(gauges[_pool]);
                weights[_pool] -= _votes;
                votes[_tokenId][_pool] -= _votes;
                if (_votes > 0) {
                    IFeeDistributor(feeDistributors[gauges[_pool]])._withdraw(
                        uint256(_votes),
                        _tokenId
                    );
                    _totalWeight += _votes;
                } else {
                    _totalWeight -= _votes;
                }
                emit Abstained(_tokenId, _votes);
            }
        }
        totalWeight -= uint256(_totalWeight);
        usedWeights[_tokenId] = 0;
        delete poolVote[_tokenId];
    }

    function poke(uint256 _tokenId) external {
        address[] memory _poolVote = poolVote[_tokenId];
        uint256 _poolCnt = _poolVote.length;
        uint256[] memory _weights = new uint256[](_poolCnt);

        for (uint256 i = 0; i < _poolCnt; ++i) {
            _weights[i] = votes[_tokenId][_poolVote[i]];
        }

        _vote(_tokenId, _poolVote, _weights);
    }

    function _vote(
        uint256 _tokenId,
        address[] memory _poolVote,
        uint256[] memory _weights
    ) internal {
        require(!newStale[_tokenId], "Stale NFT, please contact the team");
        _reset(_tokenId);
        uint256 _poolCnt = _poolVote.length;
        uint256 _weight = IVotingEscrow(_ve).balanceOfNFT(_tokenId);
        uint256 _totalVoteWeight = 0;
        uint256 _totalWeight = 0;
        uint256 _usedWeight = 0;

        for (uint256 i = 0; i < _poolCnt; ++i) {
            _totalVoteWeight += _weights[i];
        }

        for (uint256 i = 0; i < _poolCnt; ++i) {
            address _pool = _poolVote[i];
            address _gauge = gauges[_pool];

            if (isGauge[_gauge] && isAlive[_gauge]) {
                uint256 _poolWeight = (_weights[i] * _weight) /
                    _totalVoteWeight;
                require(votes[_tokenId][_pool] == 0);
                require(_poolWeight != 0);
                _updateFor(_gauge);

                poolVote[_tokenId].push(_pool);

                weights[_pool] += _poolWeight;
                votes[_tokenId][_pool] += _poolWeight;
                IFeeDistributor(feeDistributors[_gauge])._deposit(
                    uint256(_poolWeight),
                    _tokenId
                );
                _usedWeight += _poolWeight;
                _totalWeight += _poolWeight;
                emit Voted(msg.sender, _tokenId, _poolWeight);
            }
        }
        if (_usedWeight > 0) IVotingEscrow(_ve).voting(_tokenId);
        totalWeight += uint256(_totalWeight);
        usedWeights[_tokenId] = uint256(_usedWeight);
    }

    function vote(
        uint256 tokenId,
        address[] calldata _poolVote,
        uint256[] calldata _weights
    ) external onlyNewEpoch(tokenId) {
        require(
            IVotingEscrow(_ve).isApprovedOrOwner(msg.sender, tokenId) ||
                IVotingEscrow(_ve).isDelegate(msg.sender, tokenId),
            "!approved"
        );
        require(_poolVote.length == _weights.length);
        lastVoted[tokenId] = (block.timestamp / DURATION) * DURATION;
        _vote(tokenId, _poolVote, _weights);
    }

    ////////////////////
    // Gauge Creation //
    ////////////////////

    function createGauge(
        address _pool
    ) external onlyWhitelistOperators returns (address) {
        require(gauges[_pool] == address(0x0), "exists");
        bool isPair = IPairFactory(factory).isPair(_pool);
        require(isPair, "!_pool");

        address tokenA;
        address tokenB;

        address[] memory initialRewards = new address[](2);

        if (isPair) {
            (tokenA, tokenB) = IPair(_pool).tokens();
            initialRewards[0] = base;
            initialRewards[1] = address(xToken);
        }

        if (msg.sender != governor) {
            // prevent gauge creation for forbidden tokens
            require(!isForbidden[tokenA] && !isForbidden[tokenB], "Forbidden");
            require(
                isWhitelisted[tokenA] && isWhitelisted[tokenB],
                "!whitelisted"
            );
        }

        address pairFees = IPair(_pool).fees();
        address _feeDistributor = IFeeDistributorFactory(feeDistributorFactory)
            .createFeeDistributor(pairFees);
        IPairFees(pairFees).initialize(_feeDistributor);
        IPair(_pool).setActiveGauge(true);
        address _gauge = IGaugeFactory(gaugefactory).createGauge(
            _pool,
            _feeDistributor,
            _ve,
            isPair,
            initialRewards
        );

        IERC20(base).approve(_gauge, type(uint256).max);
        IERC20(xToken).approve(_gauge, type(uint256).max);
        feeDistributors[_gauge] = _feeDistributor;
        gauges[_pool] = _gauge;
        poolForGauge[_gauge] = _pool;
        isGauge[_gauge] = true;
        isAlive[_gauge] = true;
        _updateFor(_gauge);
        pools.push(_pool);
        emit GaugeCreated(_gauge, msg.sender, _feeDistributor, _pool);
        return _gauge;
    }

    function createCLGauge(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external onlyWhitelistOperators returns (address) {
        address _pool = IClPoolFactory(clFactory).getPool(tokenA, tokenB, fee);
        require(_pool != address(0), "NO POOL");
        (, , , , , , bool unlocked) = IClPool(_pool).slot0();
        require(unlocked, "Uninitialized pool!");
        require(gauges[_pool] == address(0x0), "EXISTS");

        if (msg.sender != governor) {
            // gov can create for any cl pool
            // for arbitrary gauges without a pool, use createGauge()

            // prevent gauge creation for forbidden tokens
            require(!isForbidden[tokenA] && !isForbidden[tokenB], "FORBIDDEN");
            require(isWhitelisted[tokenA] && isWhitelisted[tokenB], "!WL");
        }
        address _feeCollector = IClPoolFactory(clFactory).feeCollector();
        address _feeDistributor = IFeeDistributorFactory(feeDistributorFactory)
            .createFeeDistributor(_feeCollector);
        // return address(0);
        address _gauge = IClGaugeFactory(clGaugeFactory).createGauge(_pool);

        IERC20(base).approve(_gauge, type(uint256).max);
        IERC20(xToken).approve(_gauge, type(uint256).max);
        feeDistributors[_gauge] = _feeDistributor;
        gauges[_pool] = _gauge;
        poolForGauge[_gauge] = _pool;
        isGauge[_gauge] = true;
        isAlive[_gauge] = true;
        _updateFor(_gauge);
        pools.push(_pool);
        IClPoolOwnerActions(_pool).setFeeProtocol();
        emit GaugeCreated(_gauge, msg.sender, _feeDistributor, _pool);
        return _gauge;
    }

    function createCustomGauge(
        address _token,
        address _pool,
        address[] calldata whitelistedRewards
    ) external returns (address) {
        require(msg.sender == governor, "!AUTH");

        address feeCollector = IClPoolFactory(clFactory).feeCollector();

        address _feeDistributor = IFeeDistributorFactory(feeDistributorFactory)
            .createFeeDistributor(feeCollector);

        address _gauge = ICustomGaugeFactory(customGaugeFactory)
            .createCustomGauge(_token);

        for (uint256 i; i < whitelistedRewards.length; i++) {
            ICustomGauge(_gauge).whitelistReward(whitelistedRewards[i]);
        }

        IERC20(base).approve(_gauge, type(uint256).max);
        IERC20(xToken).approve(_gauge, type(uint256).max);
        feeDistributors[_gauge] = _feeDistributor;
        gauges[_token] = _gauge;
        poolForGauge[_gauge] = _token;
        isGauge[_gauge] = true;
        isAlive[_gauge] = true;
        _updateFor(_gauge);
        pools.push(_token);
        if (_pool != address(0)) {
            require(!isAlive[gauges[_pool]], "Active gauge");
            require(customGaugeForPool[_pool] == address(0), "exists");
            customGaugeForPool[_pool] = _gauge;
        }
        emit CustomGaugeCreated(
            _gauge,
            msg.sender,
            _feeDistributor,
            _pool,
            _token
        );
        return _gauge;
    }

    ////////////////////
    // Event Emitters //
    ////////////////////
    function attachTokenToGauge(uint256 tokenId, address account) external {
        require(isGauge[msg.sender] || isGauge[gauges[msg.sender]]);
        require(isAlive[msg.sender] || isGauge[gauges[msg.sender]]); // killed gauges cannot attach tokens to themselves
        if (tokenId > 0) IVotingEscrow(_ve).attach(tokenId);
        emit Attach(account, msg.sender, tokenId);
    }

    function emitDeposit(
        uint256 tokenId,
        address account,
        uint256 amount
    ) external {
        require(isGauge[msg.sender]);
        require(isAlive[msg.sender]);
        emit Deposit(account, msg.sender, tokenId, amount);
    }

    function detachTokenFromGauge(uint256 tokenId, address account) external {
        require(isGauge[msg.sender] || isGauge[gauges[msg.sender]]);
        if (tokenId > 0) IVotingEscrow(_ve).detach(tokenId);
        emit Detach(account, msg.sender, tokenId);
    }

    function emitWithdraw(
        uint256 tokenId,
        address account,
        uint256 amount
    ) external {
        require(isGauge[msg.sender]);
        emit Withdraw(account, msg.sender, tokenId, amount);
    }

    /////////////////////////////
    // One-stop Reward Claimer //
    /////////////////////////////

    function claimClGaugeRewards(
        address[] calldata _gauges,
        address[][] calldata _tokens,
        uint256[][] calldata _nfpTokenIds
    ) external {
        address _nfpManager = nfpManager;
        for (uint256 i = 0; i < _gauges.length; ++i) {
            for (uint256 j = 0; j < _nfpTokenIds[i].length; ++j) {
                require(
                    msg.sender ==
                        INonfungiblePositionManager(_nfpManager).ownerOf(
                            _nfpTokenIds[i][j]
                        ) ||
                        msg.sender ==
                        INonfungiblePositionManager(_nfpManager).getApproved(
                            _nfpTokenIds[i][j]
                        )
                );
                IFeeDistributor(_gauges[i]).getRewardForOwner(
                    _nfpTokenIds[i][j],
                    _tokens[i]
                );
            }
        }
    }

    function claimIncentives(
        address[] calldata _incentives,
        address[][] calldata _tokens,
        uint256 _tokenId
    ) external {
        require(IVotingEscrow(_ve).isApprovedOrOwner(msg.sender, _tokenId));
        for (uint256 i = 0; i < _incentives.length; ++i) {
            IFeeDistributor(_incentives[i]).getRewardForOwner(
                _tokenId,
                _tokens[i]
            );
        }
    }

    function claimFees(
        address[] calldata _fees,
        address[][] calldata _tokens,
        uint256 _tokenId
    ) external {
        require(IVotingEscrow(_ve).isApprovedOrOwner(msg.sender, _tokenId));
        for (uint256 i = 0; i < _fees.length; ++i) {
            IFeeDistributor(_fees[i]).getRewardForOwner(_tokenId, _tokens[i]);
        }
    }

    function claimRewards(
        address[] calldata _gauges,
        address[][] calldata _tokens
    ) external {
        for (uint256 i = 0; i < _gauges.length; ++i) {
            IGauge(_gauges[i]).getReward(msg.sender, _tokens[i]);
        }
    }

    //////////////////////////
    // Emission Calculation //
    //////////////////////////

    function notifyRewardAmount(uint256 amount) external {
        if (totalWeight > 0) {
            _safeTransferFrom(base, msg.sender, address(this), amount); // transfer the distro in
            uint256 _ratio = (amount * 1e18) / totalWeight; // 1e18 adjustment is removed during claim
            if (_ratio > 0) {
                index += _ratio;
            }
            emit NotifyReward(msg.sender, base, amount);
        }
    }

    function updateFor(address[] calldata _gauges) external {
        for (uint256 i = 0; i < _gauges.length; ++i) {
            _updateFor(_gauges[i]);
        }
    }

    function updateForRange(uint256 start, uint256 end) public {
        for (uint256 i = start; i < end; ++i) {
            _updateFor(gauges[pools[i]]);
        }
    }

    function updateAll() external {
        updateForRange(0, pools.length);
    }

    function updateGauge(address _gauge) external {
        _updateFor(_gauge);
    }

    function _updateFor(address _gauge) internal {
        address _pool = poolForGauge[_gauge];
        uint256 _supplyIndex = supplyIndex[_gauge];

        // only new pools will have 0 _supplyIndex
        if (_supplyIndex > 0) {
            uint256 _supplied = weights[_pool];
            uint256 _index = index; // get global index0 for accumulated distro
            supplyIndex[_gauge] = _index; // update _gauge current position to global position
            uint256 _delta = _index - _supplyIndex; // see if there is any difference that need to be accrued
            if (_delta > 0 && _supplied > 0) {
                uint256 _share = (uint256(_supplied) * _delta) / 1e18; // add accrued difference for each supplied token
                claimable[_gauge] += _share;
            }
        } else {
            supplyIndex[_gauge] = index; // new users are set to the default global state
        }
    }

    ///////////////////////////
    // Emission Distribution //
    ///////////////////////////

    function distributeFees(address[] memory _gauges) external {
        for (uint256 i = 0; i < _gauges.length; ++i) {
            IGauge(_gauges[i]).claimFees();
        }
    }

    function distribute(address _gauge) public lock {
        IMinter(minter).updatePeriod();
        _updateFor(_gauge);

        // dead gauges should be handled by a different function
        if (isAlive[_gauge]) {
            uint256 _claimable = claimable[_gauge];
            if (_claimable == 0) {
                return;
            }

            // calculate _xTokenClaimable
            address _xToken = address(xToken);
            uint256 _xTokenClaimable = (_claimable * gaugeXRatio(_gauge)) /
                BASIS;
            _claimable -= _xTokenClaimable;

            // can only distribute if the distributed amount / week > 0 and is > left()
            bool canDistribute = true;

            // _claimable could be 0 if emission is 100% xToken
            if (_claimable > 0) {
                if (
                    _claimable / DURATION == 0 ||
                    _claimable < IGauge(_gauge).left(base)
                ) {
                    canDistribute = false;
                }
            }
            // _xTokenClaimable could be 0 if ratio is 100% emissions
            if (_xTokenClaimable > 0) {
                if (
                    _xTokenClaimable / DURATION == 0 ||
                    _xTokenClaimable < IGauge(_gauge).left(_xToken)
                ) {
                    canDistribute = false;
                }
            }

            if (canDistribute) {
                // reset claimable
                claimable[_gauge] = 0;

                if (_claimable > 0) {
                    // notify emissions
                    IGauge(_gauge).notifyRewardAmount(base, _claimable);
                }

                if (_xTokenClaimable > 0) {
                    // convert, then notify xToken
                    IXToken(_xToken).convertEmissionsToken(_xTokenClaimable);
                    IGauge(_gauge).notifyRewardAmount(
                        _xToken,
                        _xTokenClaimable
                    );
                }

                emit DistributeReward(
                    msg.sender,
                    _gauge,
                    _claimable + _xTokenClaimable
                );
            }
        }
    }

    function distributeAllUnchecked() external {
        distributeRangeUnchecked(0, pools.length);
    }

    function distributeRangeUnchecked(uint256 start, uint256 finish) public {
        for (uint256 x = start; x < finish; ) {
            distribute(gauges[pools[x]]);
            unchecked {
                ++x;
            }
        }
    }

    function distributeGaugeUnchecked(address[] calldata _gauges) external {
        for (uint256 x = 0; x < _gauges.length; ++x) {
            distribute(_gauges[x]);
        }
    }

    ////////////////////
    // View Functions //
    ////////////////////
    function length() external view returns (uint256) {
        return pools.length;
    }

    function getVotes(
        uint256 fromTokenId,
        uint256 toTokenId
    )
        external
        view
        returns (
            address[][] memory tokensVotes,
            uint256[][] memory tokensWeights
        )
    {
        uint256 tokensCount = toTokenId - fromTokenId + 1;
        tokensVotes = new address[][](tokensCount);
        tokensWeights = new uint256[][](tokensCount);
        for (uint256 i = 0; i < tokensCount; ++i) {
            uint256 tokenId = fromTokenId + i;
            tokensVotes[i] = new address[](poolVote[tokenId].length);
            tokensVotes[i] = poolVote[tokenId];

            tokensWeights[i] = new uint256[](poolVote[tokenId].length);
            for (uint256 j = 0; j < tokensVotes[i].length; ++j) {
                tokensWeights[i][j] = votes[tokenId][tokensVotes[i][j]];
            }
        }
    }

    /// @notice returns the xTokenRatio applicable to a gauge
    /// @dev for default ratios, call this with address(0) or call xTokenRatio
    function gaugeXRatio(address gauge) public view returns (uint256) {
        // return gauge specific xToken Ratio if writter
        if (_gaugeXRatioWritten[gauge]) {
            return _gaugeXRatio[gauge];
        }

        // otherwise return default xTokenRatio
        return xRatio;
    }

    //////////////////////
    // safeTransferFrom //
    //////////////////////

    function _safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 value
    ) internal {
        require(token.code.length > 0);
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(
                IERC20.transferFrom.selector,
                from,
                to,
                value
            )
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }
}
