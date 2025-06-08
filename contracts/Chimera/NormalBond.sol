// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;

import "./libraries/Ownable.sol";
import "./libraries/SafeMath.sol";
import "./libraries/Address.sol";
import "./libraries/ERC20.sol";
import "./libraries/Counters.sol";
import "./libraries/SafeERC20.sol";
import "./libraries/FullMath.sol";

import "./interfaces/ITreasury.sol";

import "./interfaces/IBondCalculator.sol";
import "./interfaces/IStaking.sol";

import "./interfaces/IStakingHelper.sol";
import "./interfaces/IWAVAX.sol";

contract NormalBond is Ownable {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    using SafeMath for uint32;

    /* ======== EVENTS ======== */

    event BondCreated(
        uint256 deposit,
        uint256 indexed payout,
        uint256 indexed expires,
        uint256 indexed priceInUSD
    );
    event BondRedeemed(
        address indexed recipient,
        uint256 payout,
        uint256 remaining
    );
    event BondPriceChanged(
        uint256 indexed priceInUSD,
        uint256 indexed internalPrice,
        uint256 indexed debtRatio
    );
    event cultPerTokenAdjustment(
        uint256 initialBCV,
        uint256 newBCV,
        uint256 adjustment,
        bool addition
    );

    /* ======== STATE VARIABLES ======== */

    address public immutable cult; // token given as payment for bond
    address public immutable principle; // token used to create bond
    address public immutable treasury; // mints OHM when receives principle
    address public immutable DAO; // receives profit share from bond
    address public WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;

    address public staking; // to auto-stake payout
    address public stakingHelper; // to stake and claim if no staking warmup
    bool public useHelper;

    Terms public terms; // stores terms for new bonds
    Adjust public adjustment; // stores adjustment to BCV data

    mapping(address => Bond) public bondInfo; // stores bond information for depositors

    uint256 public totalDebt; // total value of outstanding bonds; used for pricing
    uint32 public lastDecay; // reference cult for debt decay
    uint32 public principleDecimals;

    /* ======== STRUCTS ======== */

    // Info for creating new bonds
    struct Terms {
        uint256 cultPerToken; // 9 decimals
        uint256 minimumPrice; // vs principle value
        uint256 maxPayout; // in thousandths of a %. i.e. 500 = 0.5%
        uint256 fee; // as % of bond payout, in hundreths. ( 500 = 5% = 0.05 for every 1 paid)
        uint256 maxDebt; // 9 decimal debt ratio, max % total supply created as debt,
        uint256 debtRatioFactor; // 18 decimal, control the increaze in price relative to bond capacity. 5*10**18 means the bond price will be 5x higher at full capacity
        uint32 vestingTerm; // in seconds
    }

    // Info for bond holder
    struct Bond {
        uint256 payout; // OHM remaining to be paid
        uint32 vesting; // In DAI, for front end viewing
        uint32 lastInteractionTime; // Last interaction
        uint256 originalAmount; // Seconds left to vest
        uint256 originalPayout;
    }

    // Info for incremental adjustments to control variable
    struct Adjust {
        bool add; // addition or subtraction
        uint256 rate; // increment
        uint256 target; // BCV when adjustment finished
        uint32 buffer; // minimum length (in seconds) between adjustments
        uint32 lastInteractionTime; // cult when last adjustment made
    }

    /* ======== INITIALIZATION ======== */

    constructor(
        address _cult,
        address _principle,
        address _treasury,
        address _DAO
    ) {
        require(_cult != address(0));
        cult = _cult;
        require(_principle != address(0));
        principle = _principle;
        require(_treasury != address(0));
        treasury = _treasury;
        require(_DAO != address(0));
        DAO = _DAO;
        principleDecimals = IERC20(_principle).decimals();
    }

    /**
     *  @notice initializes bond parameters
     *  @param _cultPerToken uint
     *  @param _vestingTerm uint32
     *  @param _minimumPrice uint
     *  @param _maxPayout uint
     *  @param _fee uint
     *  @param _maxDebt uint
     *  @param _initialDebt uint
     */
    function initializeBondTerms(
        uint256 _cultPerToken,
        uint256 _minimumPrice,
        uint256 _maxPayout,
        uint256 _fee,
        uint256 _maxDebt,
        uint256 _initialDebt,
        uint256 _debtRatioFactor,
        uint32 _vestingTerm
    ) external onlyManager {
        require(terms.cultPerToken == 0, "Bonds must be initialized from 0");
        terms = Terms({
            cultPerToken: _cultPerToken,
            minimumPrice: _minimumPrice,
            maxPayout: _maxPayout,
            fee: _fee,
            maxDebt: _maxDebt,
            debtRatioFactor: _debtRatioFactor,
            vestingTerm: _vestingTerm
        });
        totalDebt = _initialDebt;
        lastDecay = uint32(block.timestamp);
    }

    /* ======== POLICY FUNCTIONS ======== */

    enum PARAMETER {
        VESTING,
        PAYOUT,
        FEE,
        DEBT,
        MINPRICE,
        BCV,
        DEBTFACTOR
    }

    /**
     *  @notice set parameters for new bonds
     *  @param _parameter PARAMETER
     *  @param _input uint
     */
    function setBondTerms(
        PARAMETER _parameter,
        uint256 _input
    ) external onlyManager {
        if (_parameter == PARAMETER.VESTING) {
            // 0
            require(_input >= 129600, "Vesting must be longer than 36 hours");
            terms.vestingTerm = uint32(_input);
        } else if (_parameter == PARAMETER.PAYOUT) {
            // 1
            terms.maxPayout = _input;
        } else if (_parameter == PARAMETER.FEE) {
            // 2
            require(_input <= 10000, "DAO fee cannot exceed payout");
            terms.fee = _input;
        } else if (_parameter == PARAMETER.DEBT) {
            // 3
            terms.maxDebt = _input;
        } else if (_parameter == PARAMETER.MINPRICE) {
            // 4
            terms.minimumPrice = _input;
        } else if (_parameter == PARAMETER.BCV) {
            // 5
            terms.cultPerToken = _input;
        } else if (_parameter == PARAMETER.DEBTFACTOR) {
            // 6
            terms.debtRatioFactor = _input;
        }
    }

    /**
     *  @notice set control variable adjustment
     *  @param _addition bool
     *  @param _increment uint
     *  @param _target uint
     *  @param _buffer uint
     */
    function setAdjustment(
        bool _addition,
        uint256 _increment,
        uint256 _target,
        uint32 _buffer
    ) external onlyManager {
        require(
            _increment <= terms.cultPerToken.mul(25).div(1000),
            "Increment too large"
        );

        adjustment = Adjust({
            add: _addition,
            rate: _increment,
            target: _target,
            buffer: _buffer,
            lastInteractionTime: uint32(block.timestamp)
        });
    }

    /**
     *  @notice set contract for auto stake
     *  @param _staking address
     *  @param _helper bool
     */
    function setStaking(address _staking, bool _helper) external onlyManager {
        require(_staking != address(0));
        if (_helper) {
            useHelper = true;
            stakingHelper = _staking;
        } else {
            useHelper = false;
            staking = _staking;
        }
    }

    /* ======== USER FUNCTIONS ======== */

    /**
     *  @notice deposit bond
     *  @param _amount uint
     *  @param _minPayout uint
     *  @param _depositor address
     *  @return uint
     */
    function deposit(
        uint256 _amount,
        uint256 _minPayout,
        address _depositor
    ) external payable returns (uint256) {
        require(_depositor != address(0), "Invalid address");
        decayDebt();

        if (principle == WAVAX && msg.value != 0) {
            _amount = msg.value;
            IWAVAX(WAVAX).deposit{value: _amount}();
        } else {
            require(msg.value == 0, "AVAX not accepted");
            IERC20(principle).safeTransferFrom(
                msg.sender,
                address(this),
                _amount
            );
        }

        // uint256 priceInUSD = bondPriceInUSD(); // Stored in bond info
        // uint256 nativePrice = _bondPrice();

        // uint256 value = ITreasury(treasury).valueOf(principle, _amount);
        uint256 payout = payoutForToken(_amount); // payout to bonder is computed
        require(_minPayout <= payout, "Slippage limit: amount < minAmount"); // slippage protection

        require(payout >= 10000000, "Bond too small"); // must be > 0.01 OHM ( underflow protection )
        require(payout <= maxPayout(), "Bond too large"); // size protection because there is no price impact

        // profits are calculated
        // uint256 fee = payout.mul(terms.fee).div(10000);
        // uint256 profit = payout.sub(fee);

        /**
            principle is transferred in
            approved and
            deposited into the treasury, returning (_amount - profit) OHM
         */

        IERC20(principle).approve(address(treasury), _amount);
        ITreasury(treasury).deposit(_amount, principle, payout);

        // if (fee != 0) {
        //     // fee is transferred to dao
        //     IERC20(cult).safeTransfer(DAO, fee);
        // }

        // total debt is increased
        totalDebt = totalDebt.add(payout);
        require(totalDebt <= maxDebt(), "Max capacity reached");

        if (bondInfo[_depositor].payout > 0) {
            redeem(_depositor, false);
        }

        // depositor info is stored
        bondInfo[_depositor] = Bond({
            payout: bondInfo[_depositor].payout.add(payout),
            vesting: terms.vestingTerm,
            lastInteractionTime: uint32(block.timestamp),
            originalAmount: bondInfo[_depositor].originalAmount.add(_amount),
            originalPayout: bondInfo[_depositor].originalPayout.add(payout)
        });

        // indexed events are emitted
        // emit BondCreated(_amount, payout, block.timestamp.add(terms.vestingTerm), priceInUSD);
        // emit BondPriceChanged(bondPriceInUSD(), _bondPrice(), debtRatio());

        adjust(); // control variable is adjusted
        return payout;
    }

    /**
     *  @notice redeem bond for user
     *  @param _recipient address
     *  @param _stake bool
     *  @return uint
     */
    function redeem(address _recipient, bool _stake) public returns (uint256) {
        Bond memory info = bondInfo[_recipient];
        // (seconds since last interaction / vesting term remaining)
        uint256 percentVested = percentVestedFor(_recipient);

        if (percentVested >= 10000) {
            // if fully vested
            delete bondInfo[_recipient]; // delete user info
            emit BondRedeemed(_recipient, info.payout, 0); // emit bond data
            return stakeOrSend(_recipient, _stake, info.payout); // pay user everything due
        } else {
            // if unfinished
            // calculate payout vested
            uint256 payout = info.payout.mul(percentVested).div(10000);
            // store updated deposit info
            bondInfo[_recipient] = Bond({
                payout: info.payout.sub(payout),
                vesting: info.vesting.sub32(
                    uint32(block.timestamp).sub32(info.lastInteractionTime)
                ),
                lastInteractionTime: uint32(block.timestamp),
                originalAmount: info.originalAmount,
                originalPayout: info.originalPayout
            });

            emit BondRedeemed(_recipient, payout, bondInfo[_recipient].payout);
            return stakeOrSend(_recipient, _stake, payout);
        }
    }

    /* ======== INTERNAL HELPER FUNCTIONS ======== */

    /**
     *  @notice allow user to stake payout automatically
     *  @param _stake bool
     *  @param _amount uint
     *  @return uint
     */
    function stakeOrSend(
        address _recipient,
        bool _stake,
        uint256 _amount
    ) internal returns (uint256) {
        if (!_stake) {
            // if user does not want to stake
            IERC20(cult).transfer(_recipient, _amount); // send payout
        } else {
            // if user wants to stake
            if (useHelper) {
                // use if staking warmup is 0
                IERC20(cult).approve(stakingHelper, _amount);
                IStakingHelper(stakingHelper).stake(_amount, _recipient);
            } else {
                IERC20(cult).approve(staking, _amount);
                IStaking(staking).stake(_amount, _recipient);
            }
        }
        return _amount;
    }

    /**
     *  @notice makes incremental adjustment to control variable
     */
    function adjust() internal {
        uint256 cultCanAdjust = adjustment.lastInteractionTime.add(
            adjustment.buffer
        );
        if (adjustment.rate != 0 && block.timestamp >= cultCanAdjust) {
            uint256 initial = terms.cultPerToken;
            if (adjustment.add) {
                terms.cultPerToken = terms.cultPerToken.add(adjustment.rate);
                if (terms.cultPerToken >= adjustment.target) {
                    adjustment.rate = 0;
                }
            } else {
                terms.cultPerToken = terms.cultPerToken.sub(adjustment.rate);
                if (terms.cultPerToken <= adjustment.target) {
                    adjustment.rate = 0;
                }
            }
            adjustment.lastInteractionTime = uint32(block.timestamp);
            emit cultPerTokenAdjustment(
                initial,
                terms.cultPerToken,
                adjustment.rate,
                adjustment.add
            );
        }
    }

    /**
     *  @notice reduce total debt
     */
    function decayDebt() internal {
        totalDebt = totalDebt.sub(debtDecay());
        lastDecay = uint32(block.timestamp);
    }

    /* ======== VIEW FUNCTIONS ======== */

    /**
     *  @notice determine maximum bond size
     *  @return uint
     */
    function maxPayout() public view returns (uint256) {
        return maxDebt().mul(terms.maxPayout).div(1e18);
    }

    function cultPerToken() public view returns (uint256) {
        return terms.cultPerToken;
    }

    function payoutForToken(uint256 amount) public view returns (uint256) {
        uint256 baseAmount = amount.mul(terms.cultPerToken).div(
            10 ** principleDecimals
        );
        uint256 debtFactor = debtRatio()
            .mul(terms.debtRatioFactor)
            .div(1e18)
            .add(1e18);
        return baseAmount.mul(1e18).div(debtFactor);
    }

    function bondPrice() public view returns (uint256) {
        return
            (10 ** principleDecimals).mul(1e9).div(
                payoutForToken(10 ** principleDecimals)
            );
    }

    function maxDebt() public view returns (uint256) {
        // return IERC20(cult).totalSupply().mul(terms.maxDebt).div(1e18);
        return terms.maxDebt;
    }

    /**
     *  @notice calculate debt factoring in decay
     *  @return uint
     */
    function currentDebt() public view returns (uint256) {
        return totalDebt.sub(debtDecay());
    }

    /**
     *  @notice amount to decay total debt by
     *  @return decay_ uint
     */
    function debtDecay() public view returns (uint256 decay_) {
        uint32 timeSinceLast = uint32(block.timestamp).sub32(lastDecay);
        decay_ = totalDebt.mul(timeSinceLast).div(terms.vestingTerm);
        if (decay_ > totalDebt) {
            decay_ = totalDebt;
        }
    }

    /**
     *  @notice calculate current ratio of debt to max debt, 18 decimals
     *  @return debtRatio_ uint
     */
    function debtRatio() public view returns (uint256 debtRatio_) {
        debtRatio_ = currentDebt().mul(10 ** 18).div(maxDebt());
    }

    /**
     *  @notice calculate how far into vesting a depositor is
     *  @param _depositor address
     *  @return percentVested_ uint
     */
    function percentVestedFor(
        address _depositor
    ) public view returns (uint256 percentVested_) {
        Bond memory bond = bondInfo[_depositor];
        uint256 secondsSinceLast = uint32(block.timestamp).sub(
            bond.lastInteractionTime
        );
        uint256 vesting = bond.vesting;

        if (vesting > 0) {
            percentVested_ = secondsSinceLast.mul(10000).div(vesting);
        } else {
            percentVested_ = 0;
        }
    }

    /**
     *  @notice calculate amount of OHM available for claim by depositor
     *  @param _depositor address
     *  @return pendingPayout_ uint
     */
    function pendingPayoutFor(
        address _depositor
    ) external view returns (uint256 pendingPayout_) {
        uint256 percentVested = percentVestedFor(_depositor);
        uint256 payout = bondInfo[_depositor].payout;

        if (percentVested >= 10000) {
            pendingPayout_ = payout;
        } else {
            pendingPayout_ = payout.mul(percentVested).div(10000);
        }
    }

    /* ======= AUXILLIARY ======= */

    /**
     *  @notice allow anyone to send lost tokens (excluding principle or OHM) to the DAO
     *  @return bool
     */
    function recoverLostToken(address _token) external returns (bool) {
        require(_token != cult);
        require(_token != principle);
        IERC20(_token).safeTransfer(
            DAO,
            IERC20(_token).balanceOf(address(this))
        );
        return true;
    }
}
