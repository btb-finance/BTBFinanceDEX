// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {INonfungiblePositionManager} from "../interfaces/INonfungiblePositionManager.sol";
import {ICLFactory} from "../interfaces/ICLFactory.sol";
import {ICLPool} from "../interfaces/ICLPool.sol";
import {IWETH} from "../interfaces/IWETH.sol";
import {LiquidityMath} from "../libraries/LiquidityMath.sol";
import {TickMath} from "../libraries/TickMath.sol";

/// @title BTB Finance NonfungiblePositionManager
/// @author BTB Finance
/// @notice Wraps CL positions as ERC721 NFTs
/// @dev Manages minting, burning, and modifying CL liquidity positions
contract NonfungiblePositionManager is INonfungiblePositionManager, ERC721, ERC721Enumerable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INonfungiblePositionManager
    address public immutable override factory;

    /// @inheritdoc INonfungiblePositionManager
    address public immutable override WETH9;

    /// @dev Next token ID
    uint256 private _nextId = 1;

    /// @dev Token ID => Position
    mapping(uint256 => Position) private _positions;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _factory, address _WETH9) ERC721("BTB CL Position", "BTB-CL-POS") {
        factory = _factory;
        WETH9 = _WETH9;
    }

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INonfungiblePositionManager
    function positions(uint256 tokenId) external view override returns (Position memory) {
        return _positions[tokenId];
    }

    /*//////////////////////////////////////////////////////////////
                           POSITION FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc INonfungiblePositionManager
    function mint(MintParams calldata params)
        external
        payable
        override
        nonReentrant
        checkDeadline(params.deadline)
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        // Get or verify pool exists
        address pool = ICLFactory(factory).getPool(params.token0, params.token1, params.tickSpacing);
        if (pool == address(0)) revert InvalidPool();

        // Calculate liquidity
        (uint160 sqrtPriceX96,,) = ICLPool(pool).slot0();
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(params.tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(params.tickUpper);

        liquidity = LiquidityMath.getLiquidityForAmounts(
            sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, params.amount0Desired, params.amount1Desired
        );

        // Transfer tokens
        _pay(params.token0, msg.sender, pool, params.amount0Desired);
        _pay(params.token1, msg.sender, pool, params.amount1Desired);

        // Mint to pool
        (amount0, amount1) = ICLPool(pool).mint(
            address(this), params.tickLower, params.tickUpper, liquidity, abi.encode(msg.sender)
        );

        // Check slippage
        if (amount0 < params.amount0Min || amount1 < params.amount1Min) revert SlippageExceeded();

        // Mint NFT
        tokenId = _nextId++;
        _mint(params.recipient, tokenId);

        // Store position
        _positions[tokenId] = Position({
            token0: params.token0,
            token1: params.token1,
            tickSpacing: params.tickSpacing,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidity: liquidity,
            feeGrowthInside0LastX128: 0,
            feeGrowthInside1LastX128: 0,
            tokensOwed0: 0,
            tokensOwed1: 0
        });

        emit IncreaseLiquidity(tokenId, liquidity, amount0, amount1);
    }

    /// @inheritdoc INonfungiblePositionManager
    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        payable
        override
        nonReentrant
        checkDeadline(params.deadline)
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        Position storage position = _positions[params.tokenId];
        if (!_isAuthorized(ownerOf(params.tokenId), msg.sender, params.tokenId)) {
            revert NotApprovedOrOwner();
        }

        address pool = ICLFactory(factory).getPool(position.token0, position.token1, position.tickSpacing);

        // Calculate additional liquidity
        (uint160 sqrtPriceX96,,) = ICLPool(pool).slot0();
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(position.tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(position.tickUpper);

        liquidity = LiquidityMath.getLiquidityForAmounts(
            sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, params.amount0Desired, params.amount1Desired
        );

        // Transfer and mint
        _pay(position.token0, msg.sender, pool, params.amount0Desired);
        _pay(position.token1, msg.sender, pool, params.amount1Desired);

        (amount0, amount1) = ICLPool(pool).mint(
            address(this), position.tickLower, position.tickUpper, liquidity, abi.encode(msg.sender)
        );

        if (amount0 < params.amount0Min || amount1 < params.amount1Min) revert SlippageExceeded();

        position.liquidity += liquidity;

        emit IncreaseLiquidity(params.tokenId, liquidity, amount0, amount1);
    }

    /// @inheritdoc INonfungiblePositionManager
    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        override
        nonReentrant
        checkDeadline(params.deadline)
        returns (uint256 amount0, uint256 amount1)
    {
        Position storage position = _positions[params.tokenId];
        if (!_isAuthorized(ownerOf(params.tokenId), msg.sender, params.tokenId)) {
            revert NotApprovedOrOwner();
        }

        address pool = ICLFactory(factory).getPool(position.token0, position.token1, position.tickSpacing);

        // Burn from pool
        (amount0, amount1) = ICLPool(pool).burn(position.tickLower, position.tickUpper, params.liquidity);

        if (amount0 < params.amount0Min || amount1 < params.amount1Min) revert SlippageExceeded();

        position.liquidity -= params.liquidity;
        position.tokensOwed0 += uint128(amount0);
        position.tokensOwed1 += uint128(amount1);

        emit DecreaseLiquidity(params.tokenId, params.liquidity, amount0, amount1);
    }

    /// @inheritdoc INonfungiblePositionManager
    function collect(CollectParams calldata params)
        external
        override
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        Position storage position = _positions[params.tokenId];
        if (!_isAuthorized(ownerOf(params.tokenId), msg.sender, params.tokenId)) {
            revert NotApprovedOrOwner();
        }

        address pool = ICLFactory(factory).getPool(position.token0, position.token1, position.tickSpacing);

        // Collect from pool
        (amount0, amount1) =
            ICLPool(pool).collect(params.recipient, position.tickLower, position.tickUpper, params.amount0Max, params.amount1Max);

        // Update tokens owed
        position.tokensOwed0 -= uint128(amount0);
        position.tokensOwed1 -= uint128(amount1);

        emit Collect(params.tokenId, params.recipient, amount0, amount1);
    }

    /// @inheritdoc INonfungiblePositionManager
    function burn(uint256 tokenId) external override nonReentrant {
        if (!_isAuthorized(ownerOf(tokenId), msg.sender, tokenId)) {
            revert NotApprovedOrOwner();
        }

        Position storage position = _positions[tokenId];
        if (position.liquidity != 0 || position.tokensOwed0 != 0 || position.tokensOwed1 != 0) {
            revert InvalidPool(); // Position not cleared
        }

        delete _positions[tokenId];
        _burn(tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _pay(address token, address payer, address recipient, uint256 amount) internal {
        if (token == WETH9 && msg.value >= amount) {
            IWETH(WETH9).deposit{value: amount}();
            IERC20(WETH9).safeTransfer(recipient, amount);
        } else {
            IERC20(token).safeTransferFrom(payer, recipient, amount);
        }
    }

    /*//////////////////////////////////////////////////////////////
                              ERC721 HOOKS
    //////////////////////////////////////////////////////////////*/

    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721, ERC721Enumerable)
        returns (address)
    {
        return super._update(to, tokenId, auth);
    }

    function _increaseBalance(address account, uint128 value) internal override(ERC721, ERC721Enumerable) {
        super._increaseBalance(account, value);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC721Enumerable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    /*//////////////////////////////////////////////////////////////
                              RECEIVE ETH
    //////////////////////////////////////////////////////////////*/

    receive() external payable {}
}
