// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;

import "./libraries/SafeMath.sol";
import "./libraries/ERC20.sol";
import "./libraries/Address.sol";
import "./libraries/Ownable.sol";
import "./libraries/SafeERC20.sol";

import "./interfaces/IDistributor.sol";
import "./libraries/IsCult.sol";

interface IMemo {
    function rebase(
        uint256 ohmProfit_,
        uint256 epoch_
    ) external returns (uint256);

    function circulatingSupply() external view returns (uint256);

    function balanceOf(address who) external view returns (uint256);

    function gonsForBalance(uint256 amount) external view returns (uint256);

    function balanceForGons(uint256 gons) external view returns (uint256);

    function index() external view returns (uint256);
}

interface IWarmup {
    function retrieve(address staker_, uint256 amount_) external;
}

contract Staking is Ownable {
    using SafeMath for uint256;
    using SafeMath for uint32;
    using SafeERC20 for IERC20;

    uint256 public PRAYER_INTERVAL = 9;

    address public immutable cult;
    address public immutable sCult;

    struct Epoch {
        uint256 number;
        uint256 distribute;
        uint32 length;
        uint32 endTime;
    }
    Epoch public epoch;

    address public distributor;

    address public locker;
    uint256 public totalBonus;

    address public warmupContract;
    uint256 public warmupPeriod;

    uint256 public generationRate;
    uint256 public baseRate;
    uint256 public increasePerRebaseGenerationRate;
    uint256 public constant GENERATION_DENOMINATOR = 100;
    mapping(address => uint256) public lastGenerationRate;

    uint256 public totalFaith;
    mapping(address => uint256) public lastInteraction;
    mapping(address => uint256) public veBalance;
    mapping(address => uint256) public foundationOfFaith;

    struct Claim {
        uint256 deposit;
        uint256 gons;
        uint256 expiry;
        bool lock; // prevents malicious delays
    }
    mapping(address => Claim) public warmupInfo;
    uint256 public DENOMINATOR = 10000;
    event Rebased(uint256 indexed epoch);

    constructor(
        address _cult,
        address _sCult,
        uint32 _epochLength,
        uint256 _firstEpochNumber,
        uint32 _firstEpochTime
    ) {
        require(_cult != address(0));
        cult = _cult;
        require(_sCult != address(0));
        sCult = _sCult;

        epoch = Epoch({
            length: _epochLength,
            number: _firstEpochNumber,
            endTime: _firstEpochTime,
            distribute: 0
        });
    }

    function setGenerationRate(
        uint256 _baseRate,
        uint256 _generationRate,
        uint256 _increasePerRebase
    ) public onlyManager {
        baseRate = _baseRate;
        generationRate = _generationRate;
        increasePerRebaseGenerationRate = _increasePerRebase;
    }

    function setPrayerCatchupPeriod(uint256 _period) public onlyManager {
        PRAYER_INTERVAL = _period;
    }

    function nextPrayerFaith(
        address user
    ) public view returns (uint256, uint256) {
        uint256 currentEpoch = epoch.number;
        uint256 lastUserInteraction = lastInteraction[user];
        uint256 faithFoundation = foundationOfFaith[user];
        uint256 currentFaith = veBalance[user];
        uint256 lastUserGenerationRate = lastGenerationRate[user];
        lastUserGenerationRate = lastUserGenerationRate < baseRate
            ? baseRate
            : lastUserGenerationRate;
        for (uint256 i = 0; i < PRAYER_INTERVAL - 1; i++) {
            if (lastUserInteraction + i >= currentEpoch || currentEpoch <= 1) {
                break;
            }
            (, uint256 rebasePercent, , , , , ) = IsCult(sCult).rebases(
                lastUserInteraction + i - 1
            );
            currentFaith = currentFaith.add(
                faithFoundation.mul(lastUserGenerationRate).div(
                    GENERATION_DENOMINATOR
                )
            );
            faithFoundation = faithFoundation.add(
                faithFoundation.mul(rebasePercent).div(10 ** 18)
            );
        }
        if (lastUserInteraction + PRAYER_INTERVAL - 1 < currentEpoch) {
            currentFaith = currentFaith.add(
                faithFoundation
                    .mul(lastUserGenerationRate)
                    .div(GENERATION_DENOMINATOR)
                    .mul(
                        (
                            currentEpoch
                                .sub(lastUserInteraction)
                                .sub(PRAYER_INTERVAL)
                                .add(1)
                        )
                    )
            );
        }

        return (currentFaith, faithFoundation);
    }

    function effectiveSCultBalance(address user) public view returns (uint256) {
        Claim memory info = warmupInfo[user];
        uint256 balance = IERC20(sCult).balanceOf(user);
        balance = balance.add(IMemo(sCult).balanceForGons(info.gons));
        return balance;
    }

    function resetPrayers() internal {
        totalFaith = totalFaith.sub(veBalance[msg.sender]);
        veBalance[msg.sender] = 0;
        lastInteraction[msg.sender] = epoch.number;
        lastGenerationRate[msg.sender] = generationRate;
        foundationOfFaith[msg.sender] = effectiveSCultBalance(msg.sender);
    }

    function pray() public {
        prayFor(msg.sender);
    }

    function prayFor(address recipient) internal {
        (uint256 nextFaith, uint256 nextFaithFoundation) = nextPrayerFaith(
            recipient
        );
        totalFaith = totalFaith.add(nextFaith).sub(veBalance[recipient]);
        veBalance[recipient] = nextFaith;
        lastInteraction[recipient] = epoch.number;
        lastGenerationRate[recipient] = generationRate;
        foundationOfFaith[recipient] = effectiveSCultBalance(recipient);
    }

    function faithInfo(
        address user
    )
        external
        view
        returns (
            uint256 nextFaith,
            uint256 nextFaithFoundation,
            uint256 effectiveFaith,
            uint256 effectiveFoundation,
            uint256 lastPrayerPeriod
        )
    {
        (nextFaith, nextFaithFoundation) = nextPrayerFaith(user);
        effectiveFaith = veBalance[user];
        lastPrayerPeriod = lastInteraction[user];
        effectiveFoundation = foundationOfFaith[user];
    }

    /**
        @notice stake cult to enter warmup
        @param _amount uint
        @return bool
     */
    function stake(
        uint256 _amount,
        address _recipient
    ) external returns (bool) {
        rebase();
        claim(_recipient);

        IERC20(cult).safeTransferFrom(msg.sender, address(this), _amount);

        Claim memory info = warmupInfo[_recipient];
        require(!info.lock, "Deposits for account are locked");

        warmupInfo[_recipient] = Claim({
            deposit: info.deposit.add(_amount),
            gons: info.gons.add(IMemo(sCult).gonsForBalance(_amount)),
            expiry: block.timestamp.add(warmupPeriod),
            lock: false
        });
        IERC20(sCult).safeTransfer(warmupContract, _amount);
        foundationOfFaith[_recipient] = effectiveSCultBalance(_recipient);
        return true;
    }

    /**
        @notice retrieve sCult from warmup
        @param _recipient address
     */
    function claim(address _recipient) public {
        Claim memory info = warmupInfo[_recipient];
        if (block.timestamp >= info.expiry && info.expiry != 0) {
            delete warmupInfo[_recipient];
            IWarmup(warmupContract).retrieve(
                _recipient,
                IMemo(sCult).balanceForGons(info.gons)
            );
        }
        if (msg.sender == _recipient) {
            prayFor(_recipient);
        }
    }

    /**
        @notice forfeit sCult in warmup and retrieve cult
     */
    function forfeit() external {
        Claim memory info = warmupInfo[msg.sender];
        delete warmupInfo[msg.sender];
        veBalance[msg.sender] = 0;
        lastInteraction[msg.sender] = epoch.number;
        IWarmup(warmupContract).retrieve(
            address(this),
            IMemo(sCult).balanceForGons(info.gons)
        );
        IERC20(cult).safeTransfer(msg.sender, info.deposit);
        resetPrayers();
    }

    /**
        @notice prevent new deposits to address (protection from malicious activity)
     */
    function toggleDepositLock() external {
        warmupInfo[msg.sender].lock = !warmupInfo[msg.sender].lock;
    }

    /**
        @notice redeem sOHM for OHM
        @param _amount uint
        @param _trigger bool
     */
    function unstake(uint256 _amount, bool _trigger) external {
        if (_trigger) {
            rebase();
        }
        claim(msg.sender);
        lastInteraction[msg.sender] = epoch.number;
        IERC20(sCult).safeTransferFrom(msg.sender, address(this), _amount);
        IERC20(cult).safeTransfer(msg.sender, _amount);
        resetPrayers();
    }

    /**
        @notice returns the sOHM index, which tracks rebase growth
        @return uint
     */
    function index() public view returns (uint256) {
        return IMemo(sCult).index();
    }

    /**
        @notice trigger rebase if epoch over
     */
    function rebase() public {
        if (epoch.endTime <= uint32(block.timestamp)) {
            IMemo(sCult).rebase(epoch.distribute, epoch.number);

            epoch.endTime = epoch.endTime.add32(epoch.length);
            epoch.number++;

            if (distributor != address(0)) {
                IDistributor(distributor).distribute();
            }

            uint256 balance = contractBalance();
            uint256 staked = IMemo(sCult).circulatingSupply();

            if (balance <= staked) {
                epoch.distribute = 0;
            } else {
                epoch.distribute = balance.sub(staked);
            }
            emit Rebased(epoch.number);
            generationRate = generationRate.add(
                increasePerRebaseGenerationRate
            );
        }
    }

    /**
        @notice returns contract OHM holdings, including bonuses provided
        @return uint
     */
    function contractBalance() public view returns (uint256) {
        return IERC20(cult).balanceOf(address(this)).add(totalBonus);
    }

    enum DEPENDENCIES {
        DISTRIBUTOR,
        WARMUP,
        LOCKER
    }

    /**
        @notice sets the contract address for LP staking
        @param _dependency address
     */
    function setContract(
        DEPENDENCIES _dependency,
        address _address
    ) external onlyManager {
        if (_dependency == DEPENDENCIES.DISTRIBUTOR) {
            // 0
            distributor = _address;
        } else if (_dependency == DEPENDENCIES.WARMUP) {
            // 1
            require(
                warmupContract == address(0),
                "Warmup cannot be set more than once"
            );
            warmupContract = _address;
        } else if (_dependency == DEPENDENCIES.LOCKER) {
            // 2
            require(
                locker == address(0),
                "Locker cannot be set more than once"
            );
            locker = _address;
        }
    }

    /**
     * @notice set warmup period in epoch's numbers for new stakers
     * @param _warmupPeriod uint
     */
    function setWarmup(uint256 _warmupPeriod) external onlyManager {
        warmupPeriod = _warmupPeriod;
    }
}
