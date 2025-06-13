// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./interfaces/IPairFactory.sol";
import "./interfaces/IVoter.sol";
import "./interfaces/IVotingEscrow.sol";
import "./interfaces/IMinter.sol";
import "./interfaces/IPair.sol";
import "./interfaces/IFeeDistributor.sol";
import "./interfaces/IGauge.sol";
import "./interfaces/IRewardsDistributor.sol";
import "@oz-4.9.0-up/proxy/utils/Initializable.sol";

import "./v2-staking/interfaces/INonfungiblePositionManager.sol";
import "./v2-staking/interfaces/IGaugeV2.sol";
import "./v2-staking/libraries/PoolAddress.sol";

contract Lens is Initializable {
    IVoter public voter;
    IVotingEscrow public ve;
    IMinter public minter;

    address public router; // router address

    address public v2Factory;
    address public v2Nfp;
    address public v2Router;
    address public v2QuoterV2;
    address public v2PairFlash;

    struct Pool {
        address id;
        string symbol;
        bool stable;
        address token0;
        address token1;
        address gauge;
        address feeDistributor;
        address pairFees;
        uint256 pairBps;
    }

    struct ProtocolMetadata {
        address veAddress;
        address emissionsTokenAddress;
        address voterAddress;
        address poolsFactoryAddress;
        address gaugesFactoryAddress;
        address minterAddress;
    }

    struct vePosition {
        uint256 tokenId;
        uint256 balanceOf;
        uint256 locked;
    }

    struct tokenRewardData {
        address token;
        uint256 rewardRate;
    }

    struct gaugeRewardsData {
        address gauge;
        tokenRewardData[] rewardData;
    }

    // user earned per token
    struct userGaugeTokenData {
        address token;
        uint256 earned;
    }

    struct userGaugeRewardData {
        address gauge;
        uint256 balance;
        uint256 derivedBalance;
        userGaugeTokenData[] userRewards;
    }

    // user earned per token for feeDist
    struct userBribeTokenData {
        address token;
        uint256 earned;
    }

    struct userFeeDistData {
        address feeDistributor;
        userBribeTokenData[] bribeData;
    }
    // the amount of nested structs for bribe lmao
    struct userBribeData {
        uint256 tokenId;
        userFeeDistData[] feeDistRewards;
    }

    struct userVeData {
        uint256 tokenId;
        uint256 lockedAmount;
        uint256 votingPower;
        uint256 lockEnd;
    }

    struct Earned {
        address poolAddress;
        address token;
        uint256 amount;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        IVoter _voter,
        address _router,
        address _v2Factory,
        address _v2Nfp,
        address _v2Router,
        address _v2QuoterV2,
        address _v2PairFlash
    ) external initializer {
        voter = _voter;
        router = _router;
        ve = IVotingEscrow(voter._ve());
        minter = IMinter(voter.minter());

        v2Factory = _v2Factory;
        v2Nfp = _v2Nfp;
        v2Router = _v2Router;
        v2QuoterV2 = _v2QuoterV2;
        v2PairFlash = _v2PairFlash;
    }

    function reinitializeCore(
        address _router,
        address _votingEscrow
    ) external reinitializer(2) {
        router = _router;
        ve = IVotingEscrow(_votingEscrow);
    }

    /**
     * @notice returns the pool factory address
     */
    function poolFactory() public view returns (address pool) {
        pool = voter.factory();
    }

    /**
     * @notice returns the gauge factory address
     */
    function gaugeFactory() public view returns (address _gaugeFactory) {
        _gaugeFactory = voter.gaugefactory();
    }

    /**
     * @notice returns the fee distributor factory address
     */
    function feeDistributorFactory()
        public
        view
        returns (address _gaugeFactory)
    {
        _gaugeFactory = voter.feeDistributorFactory();
    }

    /**
     * @notice returns ra address
     */
    function emissionsTokenAddress()
        public
        view
        returns (address emissionsToken)
    {
        emissionsToken = ve.emissionsToken();
    }

    /**
     * @notice returns the voter address
     */
    function voterAddress() public view returns (address _voter) {
        _voter = address(voter);
    }

    /**
     * @notice returns rewardsDistributor address
     */
    function rewardsDistributor()
        public
        view
        returns (address _rewardsDistributor)
    {
        _rewardsDistributor = address(minter.rewardsDistributor());
    }

    /**
     * @notice returns the minter address
     */
    function minterAddress() public view returns (address _minter) {
        _minter = address(minter);
    }

    /**
     * @notice returns core contract addresses
     */
    function protocolMetadata()
        external
        view
        returns (ProtocolMetadata memory)
    {
        return
            ProtocolMetadata({
                veAddress: voter._ve(),
                voterAddress: voterAddress(),
                emissionsTokenAddress: emissionsTokenAddress(),
                poolsFactoryAddress: poolFactory(),
                gaugesFactoryAddress: gaugeFactory(),
                minterAddress: minterAddress()
            });
    }

    /**
     * @notice returns all RA pool addresses
     */
    function allPools() public view returns (address[] memory pools) {
        IPairFactory _factory = IPairFactory(poolFactory());
        uint256 len = _factory.allPairsLength();

        pools = new address[](len);
        for (uint256 i; i < len; ++i) {
            pools[i] = _factory.allPairs(i);
        }
    }

    /**
     * @notice returns all RA pools that have active gauges
     */
    function allActivePools() public view returns (address[] memory pools) {
        uint256 len = voter.length();
        pools = new address[](len);

        for (uint256 i; i < len; ++i) {
            pools[i] = voter.pools(i);
        }
    }

    /**
     * @notice returns the gauge address for a pool
     * @param pool pool address to check
     */
    function gaugeForPool(address pool) public view returns (address gauge) {
        gauge = voter.gauges(pool);
    }

    /**
     * @notice returns the feeDistributor address for a pool
     * @param pool pool address to check
     */
    function feeDistributorForPool(
        address pool
    ) public view returns (address feeDistributor) {
        address gauge = gaugeForPool(pool);
        feeDistributor = voter.feeDistributors(gauge);
    }

    /**
     * @notice returns current fee rate of a Ra pool
     * @param pool pool address to check
     */
    function pairBps(address pool) public view returns (uint256 bps) {
        bps = IPairFactory(poolFactory()).pairFee(pool);
    }

    /**
     * @notice returns useful information for a pool
     * @param pool pool address to check
     */
    function poolInfo(
        address pool
    ) public view returns (Pool memory _poolInfo) {
        IPair pair = IPair(pool);
        _poolInfo.id = pool;
        _poolInfo.symbol = pair.symbol();
        (_poolInfo.token0, _poolInfo.token1) = pair.tokens();
        _poolInfo.gauge = gaugeForPool(pool);
        _poolInfo.feeDistributor = feeDistributorForPool(pool);
        _poolInfo.pairFees = pair.fees();
        _poolInfo.pairBps = pairBps(pool);
    }

    /**
     * @notice returns useful information for all RA pools
     */
    function allPoolsInfo() public view returns (Pool[] memory _poolsInfo) {
        address[] memory pools = allPools();
        uint256 len = pools.length;

        _poolsInfo = new Pool[](len);
        for (uint256 i; i < len; ++i) {
            _poolsInfo[i] = poolInfo(pools[i]);
        }
    }

    /**
     * @notice returns the gauge address for all active pairs
     */
    function allGauges() public view returns (address[] memory gauges) {
        address[] memory pools = allActivePools();
        uint256 len = pools.length;
        gauges = new address[](len);

        for (uint256 i; i < len; ++i) {
            gauges[i] = gaugeForPool(pools[i]);
        }
    }

    /**
     * @notice returns the feeDistributor address for all active pairs
     */
    function allFeeDistributors()
        public
        view
        returns (address[] memory feeDistributors)
    {
        address[] memory pools = allActivePools();
        uint256 len = pools.length;
        feeDistributors = new address[](len);

        for (uint256 i; i < len; ++i) {
            feeDistributors[i] = feeDistributorForPool(pools[i]);
        }
    }

    /**
     * @notice returns all reward tokens for the fee distributor of a pool
     * @param pool pool address to check
     */
    function bribeRewardsForPool(
        address pool
    ) public view returns (address[] memory rewards) {
        IFeeDistributor feeDist = IFeeDistributor(feeDistributorForPool(pool));
        rewards = feeDist.getRewardTokens();
    }

    /**
     * @notice returns all reward tokens for the gauge of a pool
     * @param pool pool address to check
     */
    function gaugeRewardsForPool(
        address pool
    ) public view returns (address[] memory rewards) {
        IGauge gauge = IGauge(gaugeForPool(pool));
        if (address(gauge) == address(0)) return rewards;

        rewards = gauge.rewardsList();
    }

    /**
     * @notice returns all token id's of a user
     * @param user account address to check
     */
    function veNFTsOf(
        address user
    ) public view returns (uint256[] memory NFTs) {
        uint256 len = ve.balanceOf(user);
        NFTs = new uint256[](len);

        for (uint256 i; i < len; ++i) {
            NFTs[i] = ve.tokenOfOwnerByIndex(user, i);
        }
    }

    /**
     * @notice returns bribes data of a token id per pool
     * @param tokenId the veNFT token id to check
     * @param pool the pool address
     */
    function bribesPositionOf(
        uint256 tokenId,
        address pool
    ) public view returns (userFeeDistData memory rewardsData) {
        IFeeDistributor feeDist = IFeeDistributor(feeDistributorForPool(pool));
        if (address(feeDist) == address(0)) {
            return rewardsData;
        }

        address[] memory rewards = bribeRewardsForPool(pool);
        uint256 len = rewards.length;

        rewardsData.feeDistributor = address(feeDist);
        userBribeTokenData[] memory _userRewards = new userBribeTokenData[](
            len
        );

        for (uint256 i; i < len; ++i) {
            _userRewards[i].token = rewards[i];
            _userRewards[i].earned = feeDist.earned(rewards[i], tokenId);
        }
        rewardsData.bribeData = _userRewards;
    }

    /**
     * @notice returns gauge reward data for a pool
     * @param pool pool address
     */
    function poolRewardsData(
        address pool
    ) public view returns (gaugeRewardsData memory rewardData) {
        address gauge = gaugeForPool(pool);
        if (gauge == address(0)) {
            return rewardData;
        }

        address[] memory rewards = gaugeRewardsForPool(pool);
        uint256 len = rewards.length;
        tokenRewardData[] memory _rewardData = new tokenRewardData[](len);

        for (uint256 i; i < len; ++i) {
            _rewardData[i].token = rewards[i];
            _rewardData[i].rewardRate = IGauge(gauge)
                .rewardData(rewards[i])
                .rewardRate;
        }
        rewardData.gauge = gauge;
        rewardData.rewardData = _rewardData;
    }

    /**
     * @notice returns gauge reward data for multiple Ra pools
     * @param pools RA pools addresses
     */
    function poolsRewardsData(
        address[] memory pools
    ) public view returns (gaugeRewardsData[] memory rewardsData) {
        uint256 len = pools.length;
        rewardsData = new gaugeRewardsData[](len);

        for (uint256 i; i < len; ++i) {
            rewardsData[i] = poolRewardsData(pools[i]);
        }
    }

    /**
     * @notice returns gauge reward data for all Ra pools
     */
    function allPoolsRewardData()
        public
        view
        returns (gaugeRewardsData[] memory rewardsData)
    {
        address[] memory pools = allActivePools();
        rewardsData = poolsRewardsData(pools);
    }

    /**
     * @notice returns veNFT lock data for a token id
     * @param user account address of the user
     */
    function vePositionsOf(
        address user
    ) public view returns (userVeData[] memory veData) {
        uint256[] memory ids = veNFTsOf(user);
        uint256 len = ids.length;
        veData = new userVeData[](len);

        for (uint256 i; i < len; ++i) {
            veData[i].tokenId = ids[i];
            (uint256 amount, uint256 unlockTime) = ve.locked(ids[i]);
            veData[i].lockedAmount = amount;
            veData[i].lockEnd = unlockTime;
            veData[i].votingPower = ve.balanceOfNFT(ids[i]);
        }
    }

    function tokenIdEarned(
        uint256 tokenId,
        address[] memory poolAddresses,
        address[][] memory rewardTokens,
        uint256 maxReturn
    ) external view returns (Earned[] memory earnings) {
        earnings = new Earned[](maxReturn);
        uint256 earningsIndex = 0;
        uint256 amount;

        for (uint256 i; i < poolAddresses.length; ++i) {
            IGauge gauge = IGauge(voter.gauges(poolAddresses[i]));

            if (address(gauge) != address(0)) {
                IFeeDistributor feeDistributor = IFeeDistributor(
                    voter.feeDistributors(address(gauge))
                );

                for (uint256 j; j < rewardTokens[i].length; ++j) {
                    amount = feeDistributor.earned(rewardTokens[i][j], tokenId);
                    if (amount > 0) {
                        earnings[earningsIndex++] = Earned({
                            poolAddress: poolAddresses[i],
                            token: rewardTokens[i][j],
                            amount: amount
                        });
                        require(
                            earningsIndex < maxReturn,
                            "Increase maxReturn"
                        );
                    }
                }
            }
        }
    }

    function addressEarned(
        address user,
        address[] memory poolAddresses,
        uint256 maxReturn
    ) external view returns (Earned[] memory earnings) {
        earnings = new Earned[](maxReturn);
        uint256 earningsIndex = 0;
        uint256 amount;

        for (uint256 i; i < poolAddresses.length; ++i) {
            IGauge gauge = IGauge(voter.gauges(poolAddresses[i]));

            if (address(gauge) != address(0)) {
                address[] memory rewards = gauge.rewardsList();
                uint256 len = rewards.length;
                for (uint256 j; j < len; ++j) {
                    address token = rewards[i];
                    amount = gauge.earned(token, user);
                    if (amount > 0) {
                        earnings[earningsIndex++] = Earned({
                            poolAddress: poolAddresses[i],
                            token: token,
                            amount: amount
                        });
                        require(
                            earningsIndex < maxReturn,
                            "Increase maxReturn"
                        );
                    }
                }
            }
        }
    }

    function addressEarnedCl(
        address user,
        uint256 maxReturn
    ) external view returns (Earned[] memory earnings) {
        earnings = new Earned[](maxReturn);
        uint256 earningsIndex = 0;
        uint256 amount;

        // fetch user NFPs
        uint256 nfpAmount = INonfungiblePositionManager(v2Nfp).balanceOf(user);

        for (uint256 i = 0; i < nfpAmount; ++i) {
            uint256 tokenId = INonfungiblePositionManager(v2Nfp)
                .tokenOfOwnerByIndex(user, i);

            (
                ,
                ,
                address token0,
                address token1,
                uint24 fee,
                ,
                ,
                ,
                ,
                ,
                ,

            ) = INonfungiblePositionManager(v2Nfp).positions(tokenId);

            address poolAddress = PoolAddress.computeAddress(
                v2Factory,
                PoolAddress.PoolKey({token0: token0, token1: token1, fee: fee})
            );

            IGaugeV2 gauge = IGaugeV2(voter.gauges(poolAddress));
            if (address(gauge) != address(0)) {
                address[] memory rewards = gauge.getRewardTokens();

                for (uint256 j = 0; j < rewards.length; ++j) {
                    amount = gauge.earned(rewards[j], tokenId);

                    if (amount > 0) {
                        earnings[earningsIndex++] = Earned({
                            poolAddress: poolAddress,
                            token: rewards[j],
                            amount: amount
                        });
                        require(
                            earningsIndex < maxReturn,
                            "Increase maxReturn"
                        );
                    }
                }
            }
        }
    }

    /// @notice Returns an address's earned cl gauge rewards
    /// @param user User address
    /// @param skip Number of the user's NFPs tokenIds to skip
    /// @param rewardTokens The list of reward tokens interested, returns all tokens if undefined
    /// @param maxReturn Max length of the returned earnings array
    /// @return finished Specifies whether the function has processed all potential rewards
    /// @return currentNfpIndex Specifies the currently processing NFP if finished is false, 0 if finished
    /// @return earnings Earnings for the address
    function addressEarnedClPageable(
        address user,
        uint256 skip,
        address[] calldata rewardTokens,
        uint256 maxReturn
    )
        external
        view
        returns (
            bool finished,
            uint256 currentNfpIndex,
            Earned[] memory earnings
        )
    {
        earnings = new Earned[](maxReturn);
        uint256 earningsIndex = 0;
        uint256 amount;
        uint256 rewardTokensLength = rewardTokens.length;

        // fetch user NFPs
        uint256 nfpAmount = INonfungiblePositionManager(v2Nfp).balanceOf(user);

        for (uint256 i = skip; i < nfpAmount; ++i) {
            uint256 tokenId = INonfungiblePositionManager(v2Nfp)
                .tokenOfOwnerByIndex(user, i);

            (
                ,
                ,
                address token0,
                address token1,
                uint24 fee,
                ,
                ,
                ,
                ,
                ,
                ,

            ) = INonfungiblePositionManager(v2Nfp).positions(tokenId);

            address poolAddress = PoolAddress.computeAddress(
                v2Factory,
                PoolAddress.PoolKey({token0: token0, token1: token1, fee: fee})
            );

            IGaugeV2 gauge = IGaugeV2(voter.gauges(poolAddress));
            if (address(gauge) != address(0)) {
                // construct rewards list
                address[] memory rewards;

                // if rewardTokens is defined, check if elements from list of reward to get is a reward in the gauge
                if (rewardTokensLength > 0) {
                    address[] memory _rewards = new address[](
                        rewardTokensLength
                    );
                    uint256 _reawrdsCount = 0;
                    for (uint256 j = 0; j < rewardTokensLength; j++) {
                        address _reward = rewardTokens[j];
                        if (gauge.isReward(_reward)) {
                            _rewards[_reawrdsCount] = _reward;
                            _reawrdsCount += 1;
                        }
                    }

                    rewards = new address[](_reawrdsCount);
                    for (uint256 j = 0; j < _reawrdsCount; j++) {
                        rewards[j] = _rewards[j];
                    }
                }
                // use all reward tokens reported by the gauge otherwise
                else {
                    rewards = gauge.getRewardTokens();
                }

                // retrieve earned from the gauge for each reward in the rewards array
                for (uint256 j = 0; j < rewards.length; ++j) {
                    amount = gauge.earned(rewards[j], tokenId);
                    // preemptive return if gas left is low
                    if (gasleft() < 1_000_000) {
                        return (false, i, earnings);
                    }

                    if (amount > 0) {
                        earnings[earningsIndex++] = Earned({
                            poolAddress: poolAddress,
                            token: rewards[j],
                            amount: amount
                        });
                        if (earningsIndex == maxReturn) {
                            return (false, i, earnings);
                        }
                    }
                }
            }
        }
        finished = true;
    }

    function tokenIdRebase(
        uint256 tokenId
    ) external view returns (uint256 rebase) {
        rebase = IRewardsDistributor(rewardsDistributor()).claimable(tokenId);
    }

    function tokenIdEarnedSingle(
        uint256 tokenId,
        address feeDistributorAddress,
        address rewardToken
    ) external view returns (uint256 amount) {
        IFeeDistributor feeDistributor = IFeeDistributor(feeDistributorAddress);
        amount = feeDistributor.earned(rewardToken, tokenId);
    }

    function addressEarnedSingle(
        address user,
        address gaugeAddress,
        address rewardToken
    ) external view returns (uint256 amount) {
        IGauge gauge = IGauge(gaugeAddress);
        if (address(gauge) != address(0)) {
            amount = gauge.earned(rewardToken, user);
        }
    }

    function addressEarnedClSingle(
        uint256 tokenId,
        address gaugeAddress,
        address rewardToken
    ) external view returns (uint256 amount) {
        IGaugeV2 gauge = IGaugeV2(gaugeAddress);
        if (address(gauge) != address(0)) {
            amount = gauge.earned(rewardToken, tokenId);
        }
    }
}
