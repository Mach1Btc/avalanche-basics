// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import "./../v2/interfaces/IClPool.sol";
import "./../v2/libraries/FixedPoint128.sol";
import "./../v2/libraries/FullMath.sol";
import "./../v2-staking/interfaces/IGaugeV2.sol";

import "../interfaces/IVotingEscrow.sol";
import "../interfaces/IVoter.sol";

import "./interfaces/INonfungiblePositionManager.sol";
import "./interfaces/INonfungibleTokenPositionDescriptor.sol";
import "./libraries/PositionKey.sol";
import "./libraries/PoolAddress.sol";
import "./libraries/PositionManagerAux.sol";
import "./base/LiquidityManagement.sol";
import "./base/PeripheryStateUpgradeable.sol";
import "./base/Multicall.sol";
import "./base/ERC721PermitUpgradeable.sol";
import "./base/PeripheryValidation.sol";
import "./base/SelfPermit.sol";

/// @title NFT positions
/// @notice Wraps RA V2 positions in the ERC721 non-fungible token interface
/// @dev no initializer to reduce contract size, not for new deployments!
contract NonfungiblePositionManagerB is
    Initializable,
    INonfungiblePositionManager,
    Multicall,
    ERC721PermitUpgradeable,
    PeripheryStateUpgradeable,
    LiquidityManagement,
    PeripheryValidation,
    SelfPermit
{
    /// @dev IDs of pools assigned by this contract
    mapping(address => uint80) private _poolIds;

    /// @dev Pool keys by pool ID, to save on SSTOREs for position data
    mapping(uint80 => PoolAddress.PoolKey) private _poolIdToPoolKey;

    /// @dev The token ID position data
    mapping(uint256 => Position) private _positions;

    /// @dev The ID of the next token that will be minted. Skips 0
    uint176 private _nextId = 1;
    /// @dev The ID of the next pool that is used for the first time. Skips 0
    uint80 private _nextPoolId = 1;

    /// @dev The address of the token descriptor contract, which handles generating token URIs for position tokens
    address private _tokenDescriptor;

    address public override votingEscrow;

    address private timelock;

    address public voter;

    /// @dev prevents implementation from being initialized later
    constructor() initializer() {}

    /// @inheritdoc INonfungiblePositionManager
    function positions(
        uint256 tokenId
    )
        external
        view
        override
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {
        Position memory position = _positions[tokenId];
        require(position.poolId != 0, "!VALID ID");
        PoolAddress.PoolKey memory poolKey = _poolIdToPoolKey[position.poolId];
        return (
            position.nonce,
            position.operator,
            poolKey.token0,
            poolKey.token1,
            poolKey.fee,
            position.tickLower,
            position.tickUpper,
            position.liquidity,
            position.feeGrowthInside0LastX128,
            position.feeGrowthInside1LastX128,
            position.tokensOwed0,
            position.tokensOwed1
        );
    }

    /// @dev Caches a pool key
    function cachePoolKey(
        address pool,
        PoolAddress.PoolKey memory poolKey
    ) private returns (uint80 poolId) {
        poolId = _poolIds[pool];
        if (poolId == 0) {
            _poolIds[pool] = (poolId = _nextPoolId++);
            _poolIdToPoolKey[poolId] = poolKey;
        }
    }

    /// @inheritdoc INonfungiblePositionManager
    function mint(
        MintParams calldata params
    )
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        )
    {
        if (params.veNFTTokenId != 0) {
            require(
                IVotingEscrow(votingEscrow).isApprovedOrOwner(
                    msg.sender,
                    params.veNFTTokenId
                ),
                "!APPROVED"
            );
        }
        IClPool pool;
        tokenId = _nextId++;
        (liquidity, amount0, amount1, pool) = addLiquidity(
            AddLiquidityParams({
                token0: params.token0,
                token1: params.token1,
                fee: params.fee,
                recipient: address(this),
                index: tokenId,
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                amount0Desired: params.amount0Desired,
                amount1Desired: params.amount1Desired,
                amount0Min: params.amount0Min,
                amount1Min: params.amount1Min,
                veNftTokenId: params.veNFTTokenId
            })
        );

        _mint(params.recipient, tokenId);

        bytes32 positionKey = PositionKey.compute(
            address(this),
            tokenId,
            params.tickLower,
            params.tickUpper
        );
        (
            ,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            ,
            ,

        ) = pool.positions(positionKey);

        // idempotent set
        uint80 poolId = cachePoolKey(
            address(pool),
            PoolAddress.PoolKey({
                token0: params.token0,
                token1: params.token1,
                fee: params.fee
            })
        );

        _positions[tokenId] = Position({
            nonce: 0,
            operator: address(0),
            poolId: poolId,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidity: liquidity,
            feeGrowthInside0LastX128: feeGrowthInside0LastX128,
            feeGrowthInside1LastX128: feeGrowthInside1LastX128,
            tokensOwed0: 0,
            tokensOwed1: 0,
            veTokenId: params.veNFTTokenId
        });

        emit IncreaseLiquidity(tokenId, liquidity, amount0, amount1);
    }

    modifier isAuthorizedForToken(uint256 tokenId) {
        require(_isApprovedOrOwner(msg.sender, tokenId), "!APPROVED");
        _;
    }

    function tokenURI(
        uint256 tokenId
    )
        public
        view
        override(ERC721Upgradeable, IERC721MetadataUpgradeable)
        returns (string memory)
    {
        require(_exists(tokenId));
        return
            INonfungibleTokenPositionDescriptor(_tokenDescriptor).tokenURI(
                this,
                tokenId
            );
    }

    // save bytecode by removing implementation of unused method
    function baseURI() public pure override returns (string memory) {}

    /// @inheritdoc INonfungiblePositionManager
    function increaseLiquidity(
        IncreaseLiquidityParams calldata params
    )
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        Position storage position = _positions[params.tokenId];

        PoolAddress.PoolKey memory poolKey = _poolIdToPoolKey[position.poolId];

        IClPool pool;
        (liquidity, amount0, amount1, pool) = addLiquidity(
            AddLiquidityParams({
                token0: poolKey.token0,
                token1: poolKey.token1,
                fee: poolKey.fee,
                tickLower: position.tickLower,
                tickUpper: position.tickUpper,
                amount0Desired: params.amount0Desired,
                amount1Desired: params.amount1Desired,
                amount0Min: params.amount0Min,
                amount1Min: params.amount1Min,
                recipient: address(this),
                index: params.tokenId,
                veNftTokenId: position.veTokenId
            })
        );

        bytes32 positionKey = PositionKey.compute(
            address(this),
            params.tokenId,
            position.tickLower,
            position.tickUpper
        );

        // this is now updated to the current transaction
        (
            ,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            ,
            ,

        ) = pool.positions(positionKey);

        position.tokensOwed0 += uint128(
            FullMath.mulDiv(
                feeGrowthInside0LastX128 - position.feeGrowthInside0LastX128,
                position.liquidity,
                FixedPoint128.Q128
            )
        );
        position.tokensOwed1 += uint128(
            FullMath.mulDiv(
                feeGrowthInside1LastX128 - position.feeGrowthInside1LastX128,
                position.liquidity,
                FixedPoint128.Q128
            )
        );

        position.feeGrowthInside0LastX128 = feeGrowthInside0LastX128;
        position.feeGrowthInside1LastX128 = feeGrowthInside1LastX128;
        position.liquidity += liquidity;

        emit IncreaseLiquidity(params.tokenId, liquidity, amount0, amount1);
    }

    /// @inheritdoc INonfungiblePositionManager
    function decreaseLiquidity(
        DecreaseLiquidityParams calldata params
    )
        external
        payable
        override
        isAuthorizedForToken(params.tokenId)
        checkDeadline(params.deadline)
        returns (uint256 amount0, uint256 amount1)
    {
        require(params.liquidity > 0);
        Position storage position = _positions[params.tokenId];

        PoolAddress.PoolKey memory poolKey = _poolIdToPoolKey[position.poolId];
        IClPool pool = IClPool(PoolAddress.computeAddress(factory, poolKey));

        return PositionManagerAux.decreaseLiquidity(position, pool, params);
    }

    /// @inheritdoc INonfungiblePositionManager
    function collect(
        CollectParams calldata params
    )
        external
        payable
        override
        isAuthorizedForToken(params.tokenId)
        returns (uint256 amount0, uint256 amount1)
    {
        Position storage position = _positions[params.tokenId];

        PoolAddress.PoolKey memory poolKey = _poolIdToPoolKey[position.poolId];

        IClPool pool = IClPool(PoolAddress.computeAddress(factory, poolKey));

        return PositionManagerAux.collect(position, pool, params);
    }

    /// @inheritdoc INonfungiblePositionManager
    function switchAttachment(
        uint256 tokenId,
        uint256 veNftTokenId
    ) public override isAuthorizedForToken(tokenId) {
        if (veNftTokenId != 0) {
            require(
                IVotingEscrow(votingEscrow).isApprovedOrOwner(
                    msg.sender,
                    veNftTokenId
                ),
                "!APPROVED"
            );
        }

        Position storage position = _positions[tokenId];

        PoolAddress.PoolKey memory poolKey = _poolIdToPoolKey[position.poolId];

        IClPool pool = IClPool(PoolAddress.computeAddress(factory, poolKey));

        emit SwitchAttachment(tokenId, position.veTokenId, veNftTokenId);

        position.veTokenId = veNftTokenId;

        pool.burn(
            tokenId,
            position.tickLower,
            position.tickUpper,
            0,
            veNftTokenId
        );
    }

    function batchSwitchAttachment(
        uint256[] calldata tokenIds,
        uint256 veRamTokenId
    ) external {
        for (uint256 i; i < tokenIds.length; i++) {
            switchAttachment(tokenIds[i], veRamTokenId);
        }
    }

    /// @inheritdoc INonfungiblePositionManager
    function burn(
        uint256 tokenId
    ) external payable override isAuthorizedForToken(tokenId) {
        Position storage position = _positions[tokenId];
        require(
            position.liquidity == 0 &&
                position.tokensOwed0 == 0 &&
                position.tokensOwed1 == 0 &&
                position.veTokenId == 0,
            "!CLEARED"
        );
        delete _positions[tokenId];
        _burn(tokenId);
    }

    function _getAndIncrementNonce(
        uint256 tokenId
    ) internal override returns (uint256) {
        return uint256(_positions[tokenId].nonce++);
    }

    /// @inheritdoc IERC721Upgradeable
    function getApproved(
        uint256 tokenId
    )
        public
        view
        override(ERC721Upgradeable, IERC721Upgradeable)
        returns (address)
    {
        require(_exists(tokenId), "nonexistent");

        return _positions[tokenId].operator;
    }

    /// @dev Overrides _approve to use the operator in the position, which is packed with the position permit nonce
    function _approve(
        address to,
        uint256 tokenId
    ) internal override(ERC721Upgradeable) {
        _positions[tokenId].operator = to;
        emit Approval(ownerOf(tokenId), to, tokenId);
    }

    /// @notice public _isApprovedOrOwner getter
    function isApprovedOrOwner(
        address spender,
        uint256 tokenId
    ) external view returns (bool) {
        return _isApprovedOrOwner(spender, tokenId);
    }

    function getReward(uint256 tokenId, address[] calldata tokens) external {
        require(_isApprovedOrOwner(msg.sender, tokenId));

        Position storage position = _positions[tokenId];

        PoolAddress.PoolKey memory poolKey = _poolIdToPoolKey[position.poolId];
        IGaugeV2 gauge = IGaugeV2(
            IVoter(voter).gauges(PoolAddress.computeAddress(factory, poolKey))
        );

        gauge.getRewardForOwner(tokenId, tokens);
    }

    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external payable returns (address pool) {
        pool = IClPoolFactory(factory).getPool(token0, token1, fee);

        if (pool == address(0)) {
            pool = IClPoolFactory(factory).createPool(
                token0,
                token1,
                fee,
                sqrtPriceX96
            );
        } else {
            (uint160 sqrtPriceX96Existing, , , , , , ) = IClPool(pool).slot0();
            if (sqrtPriceX96Existing == 0) {
                IClPool(pool).initialize(sqrtPriceX96);
            }
        }
    }
}
