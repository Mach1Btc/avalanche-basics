// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@oz-4.9.0-up/utils/math/MathUpgradeable.sol";
import "@oz-4.9.0/proxy/utils/Initializable.sol";

import "./interfaces/IPair.sol";
import "./interfaces/IPairCallee.sol";
import "./interfaces/IPairFactory.sol";

import "./PairFees.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IVoter.sol";

/// @notice The base pair of pools, either stable or volatile
contract Pair is IPair, Initializable {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint8 public feeSplit;

    /// @notice Used to denote stable (correlated) or volatile pairs.
    /// @notice Not immutable since construction happens in the initialize method for CREATE2 deterministic addresses
    bool public stable;
    bool hasActiveGauge;

    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public balanceOf;

    bytes32 internal DOMAIN_SEPARATOR;
    // keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 internal constant PERMIT_TYPEHASH =
        0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
    mapping(address => uint256) public nonces;

    address public token0;
    address public token1;
    address public fees;
    address factory;
    address voter;

    /// @notice Structure to capture time period obervations every 30 minutes, used for local oracles
    struct Observation {
        uint256 timestamp;
        uint256 reserve0Cumulative;
        uint256 reserve1Cumulative;
    }

    Observation[] public observations;

    /// @notice Capture oracle reading every 30 minutes
    uint256 constant periodSize = 1800;
    uint256 internal constant MINIMUM_LIQUIDITY = 10 ** 3;
    uint256 internal constant MINIMUM_K = 1e9;
    uint256 internal decimals0;
    uint256 internal decimals1;
    uint256 public reserve0;
    uint256 public reserve1;
    uint256 public blockTimestampLast;
    uint256 public reserve0CumulativeLast;
    uint256 public reserve1CumulativeLast;
    uint256 internal _unlocked;
    uint256 public totalSupply;

    event Fees(address indexed sender, uint256 amount0, uint256 amount1);
    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(
        address indexed sender,
        uint256 amount0,
        uint256 amount1,
        address indexed to
    );
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Sync(uint256 reserve0, uint256 reserve1);
    event Claim(
        address indexed sender,
        address indexed recipient,
        uint256 amount0,
        uint256 amount1
    );

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 amount
    );

    event SetFeeSplit(
        uint8 toFeesOld,
        uint8 toTreasuryOld,
        uint8 toFeesNew,
        uint8 toTreasuryNew
    );

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _factory,
        address _token0,
        address _token1,
        bool _stable,
        address _voter
    ) external initializer {
        factory = _factory;
        token0 = _token0;
        token1 = _token1;
        stable = _stable;
        voter = _voter;

        fees = address(new PairFees(token0, token1, _voter));

        if (stable) {
            name = string(
                abi.encodePacked(
                    "Correlated Pair - ",
                    IERC20(_token0).symbol(),
                    "/",
                    IERC20(_token1).symbol()
                )
            );
            symbol = string(
                abi.encodePacked(
                    "cAMM-",
                    IERC20(token0).symbol(),
                    "/",
                    IERC20(token1).symbol()
                )
            );
        } else {
            name = string(
                abi.encodePacked(
                    "Volatile Pair - ",
                    IERC20(token0).symbol(),
                    "/",
                    IERC20(token1).symbol()
                )
            );
            symbol = string(
                abi.encodePacked(
                    "vAMM-",
                    IERC20(token0).symbol(),
                    "/",
                    IERC20(token1).symbol()
                )
            );
        }

        decimals0 = 10 ** IERC20(token0).decimals();
        decimals1 = 10 ** IERC20(token1).decimals();

        observations.push(Observation(block.timestamp, 0, 0));

        _unlocked = 1;
    }

    /// @dev simple re-entrancy check
    modifier lock() {
        require(_unlocked == 1);
        _unlocked = 2;
        _;
        _unlocked = 1;
    }

    function observationLength() external view returns (uint256) {
        return observations.length;
    }

    function lastObservation() public view returns (Observation memory) {
        return observations[observations.length - 1];
    }

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
        )
    {
        return (
            decimals0,
            decimals1,
            reserve0,
            reserve1,
            stable,
            token0,
            token1
        );
    }

    function tokens() external view returns (address, address) {
        return (token0, token1);
    }

    /* Since the indexing system was removed, all fees must only go to the proper contracts for fee distribution.
     * If a gauge does not exist, fees will keep accruing inside the PairFees contract.
     * This function is unguarded and anybody can call it to push fees to the proper contracts.
     */
    function claimFees() external returns (uint256 claimed0, uint256 claimed1) {
        (claimed0, claimed1) = PairFees(fees).claimFeesFor();

        emit Claim(msg.sender, msg.sender, claimed0, claimed1);
        return (claimed0, claimed1);
    }

    /// @dev Accrue fees on token0
    function _update0(uint256 amount) internal {
        uint8 _feeSplit = feeSplit;
        uint256 amountToFees = (amount * (_feeSplit % 16) * 5) / 100;
        uint256 amountToTreasury = (amount * (_feeSplit >> 4) * 5) / 100;

        if (hasActiveGauge) {
            _safeTransfer(token0, fees, amountToFees); // transfer the fees out to PairFees
            _safeTransfer(
                token0,
                IPairFactory(factory).treasury(),
                amountToTreasury
            );
        } else {
            _safeTransfer(
                token0,
                IPairFactory(factory).treasury(),
                amountToTreasury
            );
        }
        emit Fees(msg.sender, amount, 0);
    }

    /// @dev Accrue fees on token1
    function _update1(uint256 amount) internal {
        uint8 _feeSplit = feeSplit;
        uint256 amountToFees = (amount * (_feeSplit % 16) * 5) / 100;
        uint256 amountToTreasury = (amount * (_feeSplit >> 4) * 5) / 100;

        if (hasActiveGauge) {
            _safeTransfer(token1, fees, amountToFees); // transfer the fees out to PairFees
            _safeTransfer(
                token1,
                IPairFactory(factory).treasury(),
                amountToTreasury
            );
        } else {
            _safeTransfer(
                token1,
                IPairFactory(factory).treasury(),
                amountToTreasury
            );
        }
        emit Fees(msg.sender, amount, 0);
    }

    function getReserves()
        public
        view
        returns (
            uint256 _reserve0,
            uint256 _reserve1,
            uint256 _blockTimestampLast
        )
    {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    /// @dev update reserves and, on the first call per block, price accumulators
    function _update(
        uint256 balance0,
        uint256 balance1,
        uint256 _reserve0,
        uint256 _reserve1
    ) internal {
        uint256 blockTimestamp = block.timestamp;
        uint256 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            reserve0CumulativeLast += _reserve0 * timeElapsed;
            reserve1CumulativeLast += _reserve1 * timeElapsed;
        }

        Observation memory _point = lastObservation();
        timeElapsed = blockTimestamp - _point.timestamp; /// @dev compare the last observation with current timestamp, if greater than 30 minutes, record a new event
        if (timeElapsed > periodSize) {
            observations.push(
                Observation(
                    blockTimestamp,
                    reserve0CumulativeLast,
                    reserve1CumulativeLast
                )
            );
        }
        reserve0 = balance0;
        reserve1 = balance1;
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    /// @dev produces the cumulative price using counterfactuals to save gas and avoid a call to sync.
    function currentCumulativePrices()
        public
        view
        returns (
            uint256 reserve0Cumulative,
            uint256 reserve1Cumulative,
            uint256 blockTimestamp
        )
    {
        blockTimestamp = block.timestamp;
        reserve0Cumulative = reserve0CumulativeLast;
        reserve1Cumulative = reserve1CumulativeLast;

        /// @dev if time has elapsed since the last update on the pair, mock the accumulated price values
        (
            uint256 _reserve0,
            uint256 _reserve1,
            uint256 _blockTimestampLast
        ) = getReserves();
        if (_blockTimestampLast != blockTimestamp) {
            /// @dev subtraction overflow is desired
            uint256 timeElapsed = blockTimestamp - _blockTimestampLast;
            reserve0Cumulative += _reserve0 * timeElapsed;
            reserve1Cumulative += _reserve1 * timeElapsed;
        }
    }

    /// @dev gives the current twap price measured from amountIn * tokenIn gives amountOut
    function current(
        address tokenIn,
        uint256 amountIn
    ) external view returns (uint256 amountOut) {
        Observation memory _observation = lastObservation();
        (
            uint256 reserve0Cumulative,
            uint256 reserve1Cumulative,

        ) = currentCumulativePrices();
        if (block.timestamp == _observation.timestamp) {
            _observation = observations[observations.length - 2];
        }

        uint256 timeElapsed = block.timestamp - _observation.timestamp;
        uint256 _reserve0 = (reserve0Cumulative -
            _observation.reserve0Cumulative) / timeElapsed;
        uint256 _reserve1 = (reserve1Cumulative -
            _observation.reserve1Cumulative) / timeElapsed;
        amountOut = _getAmountOut(amountIn, tokenIn, _reserve0, _reserve1);
    }

    /// @dev as per `current`, however allows user configured granularity, up to the full window size
    function quote(
        address tokenIn,
        uint256 amountIn,
        uint256 granularity
    ) external view returns (uint256 amountOut) {
        uint256[] memory _prices = sample(tokenIn, amountIn, granularity, 1);
        uint256 priceAverageCumulative;
        for (uint256 i = 0; i < _prices.length; ++i) {
            priceAverageCumulative += _prices[i];
        }
        return priceAverageCumulative / granularity;
    }

    /// @dev returns a memory set of twap prices
    function prices(
        address tokenIn,
        uint256 amountIn,
        uint256 points
    ) external view returns (uint256[] memory) {
        return sample(tokenIn, amountIn, points, 1);
    }

    function sample(
        address tokenIn,
        uint256 amountIn,
        uint256 points,
        uint256 window
    ) public view returns (uint256[] memory) {
        uint256[] memory _prices = new uint256[](points);

        uint256 length = observations.length - 1;
        uint256 i = length - (points * window);
        uint256 nextIndex = 0;
        uint256 index = 0;

        for (; i < length; i += window) {
            nextIndex = i + window;
            uint256 timeElapsed = observations[nextIndex].timestamp -
                observations[i].timestamp;
            uint256 _reserve0 = (observations[nextIndex].reserve0Cumulative -
                observations[i].reserve0Cumulative) / timeElapsed;
            uint256 _reserve1 = (observations[nextIndex].reserve1Cumulative -
                observations[i].reserve1Cumulative) / timeElapsed;
            _prices[index] = _getAmountOut(
                amountIn,
                tokenIn,
                _reserve0,
                _reserve1
            );
            /// @dev index < length; length cannot overflow
            unchecked {
                index = index + 1;
            }
        }
        return _prices;
    }

    /// @dev this low-level function should be called by addLiquidity functions in Router.sol, which performs important safety checks
    /// @dev standard uniswap v2 implementation
    function mint(address to) external lock returns (uint256 liquidity) {
        require(!IPairFactory(factory).isPaused(), "PAUSED");

        (uint256 _reserve0, uint256 _reserve1) = (reserve0, reserve1);
        uint256 _balance0 = IERC20(token0).balanceOf(address(this));
        uint256 _balance1 = IERC20(token1).balanceOf(address(this));
        uint256 _amount0 = _balance0 - _reserve0;
        uint256 _amount1 = _balance1 - _reserve1;

        uint256 _totalSupply = totalSupply; /// @dev gas savings, must be defined here since totalSupply can update in _mintFee
        if (_totalSupply == 0) {
            liquidity =
                MathUpgradeable.sqrt(_amount0 * _amount1) -
                MINIMUM_LIQUIDITY;
            _mint(address(0), MINIMUM_LIQUIDITY); /// @dev permanently lock the first MINIMUM_LIQUIDITY tokens
            if (stable) {
                require(_k(_amount0, _amount1) > MINIMUM_K, "K"); /// @dev minimum K needs to be acheived for stable pairs
            }
        } else {
            liquidity = MathUpgradeable.min(
                (_amount0 * _totalSupply) / _reserve0,
                (_amount1 * _totalSupply) / _reserve1
            );
        }
        require(liquidity > 0, "ILM"); /// @dev Pair: INSUFFICIENT_LIQUIDITY_MINTED
        _mint(to, liquidity);

        _update(_balance0, _balance1, _reserve0, _reserve1);
        emit Mint(msg.sender, _amount0, _amount1);
    }

    /// @dev this low-level function should be called from a contract which performs important safety checks
    /// @dev standard uniswap v2 implementation
    function burn(
        address to
    ) external lock returns (uint256 amount0, uint256 amount1) {
        require(!IPairFactory(factory).isPaused(), "PAUSED");

        (uint256 _reserve0, uint256 _reserve1) = (reserve0, reserve1);
        (address _token0, address _token1) = (token0, token1);
        uint256 _balance0 = IERC20(_token0).balanceOf(address(this));
        uint256 _balance1 = IERC20(_token1).balanceOf(address(this));
        uint256 _liquidity = balanceOf[address(this)];

        uint256 _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        amount0 = (_liquidity * _balance0) / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = (_liquidity * _balance1) / _totalSupply; // using balances ensures pro-rata distribution
        require(amount0 > 0 && amount1 > 0, "ILB"); // Pair: INSUFFICIENT_LIQUIDITY_BURNED
        _burn(address(this), _liquidity);
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);
        _balance0 = IERC20(_token0).balanceOf(address(this));
        _balance1 = IERC20(_token1).balanceOf(address(this));

        _update(_balance0, _balance1, _reserve0, _reserve1);
        emit Burn(msg.sender, amount0, amount1, to);
    }

    /// @dev this low-level function should be called from a contract which performs important safety checks
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external lock {
        require(!IPairFactory(factory).isPaused(), "PAUSED");
        require(amount0Out > 0 || amount1Out > 0, "IOA"); // Pair: INSUFFICIENT_OUTPUT_AMOUNT
        (uint256 _reserve0, uint256 _reserve1) = (reserve0, reserve1);
        require(amount0Out < _reserve0 && amount1Out < _reserve1, "IL"); // Pair: INSUFFICIENT_LIQUIDITY

        uint256 _balance0;
        uint256 _balance1;
        {
            /// @dev scope for _token{0,1}, avoids stack too deep errors
            (address _token0, address _token1) = (token0, token1);
            require(to != _token0 && to != _token1, "IT"); // Pair: INVALID_TO
            if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); /// @dev optimistically transfer tokens
            if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); /// @dev optimistically transfer tokens
            if (data.length > 0)
                IPairCallee(to).hook(msg.sender, amount0Out, amount1Out, data); /// @dev callback, used for flash loans
            _balance0 = IERC20(_token0).balanceOf(address(this));
            _balance1 = IERC20(_token1).balanceOf(address(this));
        }
        uint256 amount0In = _balance0 > _reserve0 - amount0Out
            ? _balance0 - (_reserve0 - amount0Out)
            : 0;
        uint256 amount1In = _balance1 > _reserve1 - amount1Out
            ? _balance1 - (_reserve1 - amount1Out)
            : 0;
        require(amount0In > 0 || amount1In > 0, "IIA"); // Pair: INSUFFICIENT_INPUT_AMOUNT
        {
            /// @dev scope for reserve{0,1}Adjusted, avoids stack too deep errors
            (address _token0, address _token1) = (token0, token1);
            if (amount0In > 0)
                _update0(
                    (amount0In * IPairFactory(factory).getFee(stable)) / 10000
                ); /// @dev accrue fees for token0 and move them out of pool
            if (amount1In > 0)
                _update1(
                    (amount1In * IPairFactory(factory).getFee(stable)) / 10000
                ); /// @dev accrue fees for token1 and move them out of pool
            _balance0 = IERC20(_token0).balanceOf(address(this)); /// @dev since we removed tokens, we need to reconfirm balances, can also simply use previous balance - amountIn/ 10000, but doing balanceOf again as safety check
            _balance1 = IERC20(_token1).balanceOf(address(this));
            /// @dev The curve, either x3y+y3x for stable pools, or x*y for volatile pools
            require(_k(_balance0, _balance1) >= _k(_reserve0, _reserve1), "K"); // Pair: K
        }

        _update(_balance0, _balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    /// @dev force balances to match reserves
    function skim(address to) external lock {
        (address _token0, address _token1) = (token0, token1);
        _safeTransfer(
            _token0,
            to,
            IERC20(_token0).balanceOf(address(this)) - (reserve0)
        );
        _safeTransfer(
            _token1,
            to,
            IERC20(_token1).balanceOf(address(this)) - (reserve1)
        );
    }

    /// @dev force reserves to match balances
    function sync() external lock {
        _update(
            IERC20(token0).balanceOf(address(this)),
            IERC20(token1).balanceOf(address(this)),
            reserve0,
            reserve1
        );
    }

    function _f(uint256 x0, uint256 y) internal pure returns (uint256) {
        uint256 _a = (x0 * y) / 1e18;
        uint256 _b = ((x0 * x0) / 1e18 + (y * y) / 1e18);
        return (_a * _b) / 1e18;
    }

    function _d(uint256 x0, uint256 y) internal pure returns (uint256) {
        return
            (3 * x0 * ((y * y) / 1e18)) /
            1e18 +
            ((((x0 * x0) / 1e18) * x0) / 1e18);
    }

    function _get_y(
        uint256 x0,
        uint256 xy,
        uint256 y
    ) internal view returns (uint256 _y) {
        for (uint256 i = 0; i < 255; i++) {
            uint256 k = _f(x0, y);
            if (k < xy) {
                uint256 dy = ((xy - k) * 1e18) / _d(x0, y);
                if (dy == 0) {
                    if (k == xy) {
                        return y;
                    }
                    if (_k(x0, y + 1) > xy) {
                        return y + 1;
                    }
                    dy = 1;
                }
                y = y + dy;
            } else {
                uint256 dy = ((k - xy) * 1e18) / _d(x0, y);
                if (dy == 0) {
                    if (k == xy || _f(x0, y - 1) < xy) {
                        return y;
                    }
                    dy = 1;
                }
                y = y - dy;
            }
        }
    }

    function getAmountOut(
        uint256 amountIn,
        address tokenIn
    ) external view returns (uint256) {
        (uint256 _reserve0, uint256 _reserve1) = (reserve0, reserve1);
        amountIn -= (amountIn * IPairFactory(factory).getFee(stable)) / 10000; /// @dev remove fee from amount received
        return _getAmountOut(amountIn, tokenIn, _reserve0, _reserve1);
    }

    function _getAmountOut(
        uint256 amountIn,
        address tokenIn,
        uint256 _reserve0,
        uint256 _reserve1
    ) internal view returns (uint256) {
        if (stable) {
            uint256 xy = _k(_reserve0, _reserve1);
            _reserve0 = (_reserve0 * 1e18) / decimals0;
            _reserve1 = (_reserve1 * 1e18) / decimals1;
            (uint256 reserveA, uint256 reserveB) = tokenIn == token0
                ? (_reserve0, _reserve1)
                : (_reserve1, _reserve0);
            amountIn = tokenIn == token0
                ? (amountIn * 1e18) / decimals0
                : (amountIn * 1e18) / decimals1;
            uint256 y = reserveB - _get_y(amountIn + reserveA, xy, reserveB);
            return (y * (tokenIn == token0 ? decimals1 : decimals0)) / 1e18;
        } else {
            (uint256 reserveA, uint256 reserveB) = tokenIn == token0
                ? (_reserve0, _reserve1)
                : (_reserve1, _reserve0);
            return (amountIn * reserveB) / (reserveA + amountIn);
        }
    }

    function _k(uint256 x, uint256 y) internal view returns (uint256) {
        if (stable) {
            uint256 _x = (x * 1e18) / decimals0;
            uint256 _y = (y * 1e18) / decimals1;
            uint256 _a = (_x * _y) / 1e18;
            uint256 _b = ((_x * _x) / 1e18 + (_y * _y) / 1e18);
            return (_a * _b) / 1e18; // x3y+y3x >= k
        } else {
            return x * y; // xy >= k
        }
    }

    function _mint(address dst, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[dst] += amount;
        emit Transfer(address(0), dst, amount);
    }

    function _burn(address dst, uint256 amount) internal {
        totalSupply -= amount;
        balanceOf[dst] -= amount;
        emit Transfer(dst, address(0), amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;

        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(deadline >= block.timestamp, "Pair: EXPIRED");
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes(name)),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(
                    abi.encode(
                        PERMIT_TYPEHASH,
                        owner,
                        spender,
                        value,
                        nonces[owner]++,
                        deadline
                    )
                )
            )
        );
        address recoveredAddress = ecrecover(digest, v, r, s);
        require(
            recoveredAddress != address(0) && recoveredAddress == owner,
            "Pair: INVALID_SIGNATURE"
        );
        allowance[owner][spender] = value;

        emit Approval(owner, spender, value);
    }

    function transfer(address dst, uint256 amount) external returns (bool) {
        _transferTokens(msg.sender, dst, amount);
        return true;
    }

    function transferFrom(
        address src,
        address dst,
        uint256 amount
    ) external returns (bool) {
        address spender = msg.sender;
        uint256 spenderAllowance = allowance[src][spender];

        if (spender != src && spenderAllowance != type(uint256).max) {
            uint256 newAllowance = spenderAllowance - amount;
            allowance[src][spender] = newAllowance;

            emit Approval(src, spender, newAllowance);
        }

        _transferTokens(src, dst, amount);
        return true;
    }

    function _transferTokens(
        address src,
        address dst,
        uint256 amount
    ) internal {
        balanceOf[src] -= amount;
        balanceOf[dst] += amount;

        emit Transfer(src, dst, amount);
    }

    function _safeTransfer(address token, address to, uint256 value) internal {
        require(token.code.length > 0);
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, value)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }

    function setActiveGauge(bool isActive) external {
        require(msg.sender == voter, "!AUTH");

        hasActiveGauge = isActive;
    }

    function setFeeSplit() external {
        uint8 oldFeeSplit = feeSplit;

        uint8 _feeSplit = IPairFactory(factory).getPoolFeeSplit(address(this));

        if (_feeSplit != oldFeeSplit) {
            feeSplit = _feeSplit;

            emit SetFeeSplit(
                oldFeeSplit % 16,
                oldFeeSplit >> 4,
                _feeSplit % 16,
                _feeSplit >> 4
            );
        }
    }
}
