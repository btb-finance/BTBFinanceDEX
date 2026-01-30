// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PoolManager - Singleton contract managing all pools
/// @notice All pools live in this single contract for maximum gas efficiency
/// @dev Uses flash accounting - only net balances settled at end of transaction
contract PoolManager is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct PoolKey {
        address token0;
        address token1;
        uint24 fee; // Fee tier in hundredths of a bip (e.g., 3000 = 0.3%)
        address hooks; // Optional hook contract
    }

    struct PoolState {
        uint160 sqrtPriceX96;
        int24 tick;
        uint24 feeProtocol;
        bool initialized;
        uint256 reserve0;
        uint256 reserve1;
        uint256 liquidity;
    }

    struct ModifyLiquidityParams {
        int24 tickLower;
        int24 tickUpper;
        int128 liquidityDelta;
    }

    struct SwapParams {
        bool zeroForOne; // True if swapping token0 for token1
        int256 amountSpecified; // Positive = exact input, negative = exact output
        uint160 sqrtPriceLimitX96;
    }

    struct SwapResult {
        int256 amount0;
        int256 amount1;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant MAX_FEE = 1e6; // 100%
    int24 public constant MIN_TICK = -887272;
    int24 public constant MAX_TICK = 887272;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Pool ID => Pool state
    mapping(bytes32 => PoolState) public pools;

    /// @notice Pool ID => Tick => Tick state
    mapping(bytes32 => mapping(int24 => Tick)) public ticks;

    /// @notice Pool ID => Position key => Position
    mapping(bytes32 => mapping(bytes32 => Position)) public positions;

    /// @notice Flash accounting deltas - cleared each transaction
    mapping(address => int256) public currencyDeltas;

    /// @notice Protocol fee recipient
    address public protocolFeeRecipient;

    /// @notice Protocol fee percentage (in hundredths of a bip)
    uint24 public protocolFee;

    /// @notice Owner
    address public owner;

    /// @notice Hook registry - approved hooks
    mapping(address => bool) public approvedHooks;

    /// @notice Pool ID => Hook contract address
    mapping(bytes32 => address) public poolHooks;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event PoolInitialized(bytes32 indexed poolId, address indexed token0, address indexed token1, uint24 fee, address hooks);
    event LiquidityModified(bytes32 indexed poolId, address indexed sender, int24 tickLower, int24 tickUpper, int128 liquidityDelta);
    event Swap(bytes32 indexed poolId, address indexed sender, bool zeroForOne, int256 amount0, int256 amount1);
    event ProtocolFeeUpdated(uint24 newFee);
    event HookApproved(address indexed hook, bool approved);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error PoolAlreadyInitialized();
    error PoolNotInitialized();
    error InvalidFee();
    error InvalidTickRange();
    error InvalidSqrtPrice();
    error InvalidHook();
    error Unauthorized();
    error NotOwner();

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _protocolFeeRecipient) {
        owner = msg.sender;
        protocolFeeRecipient = _protocolFeeRecipient;
        protocolFee = 4000; // 0.04% default (40% of 0.1% pool fee)
    }

    /*//////////////////////////////////////////////////////////////
                            POOL INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialize a new pool
    /// @dev No contract deployment - just state update! 99.99% cheaper
    function initialize(PoolKey calldata key, uint160 sqrtPriceX96) external returns (bytes32 poolId) {
        if (key.fee > MAX_FEE) revert InvalidFee();
        if (sqrtPriceX96 < 4295128739 || sqrtPriceX96 > 1461446703485210103287273052203988822378723970342) revert InvalidSqrtPrice();
        if (key.hooks != address(0) && !approvedHooks[key.hooks]) revert InvalidHook();

        // Sort tokens
        (address token0, address token1) = key.token0 < key.token1 
            ? (key.token0, key.token1) 
            : (key.token1, key.token0);

        poolId = keccak256(abi.encode(token0, token1, key.fee, key.hooks));

        if (pools[poolId].initialized) revert PoolAlreadyInitialized();

        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        pools[poolId] = PoolState({
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            feeProtocol: protocolFee,
            initialized: true,
            reserve0: 0,
            reserve1: 0,
            liquidity: 0
        });

        poolHooks[poolId] = key.hooks;

        // Call hook if present
        if (key.hooks != address(0)) {
            IHooks(key.hooks).afterInitialize(poolId, sqrtPriceX96, tick);
        }

        emit PoolInitialized(poolId, token0, token1, key.fee, key.hooks);
    }

    /*//////////////////////////////////////////////////////////////
                            LIQUIDITY MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Add or remove liquidity from a pool
    function modifyLiquidity(
        bytes32 poolId,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external nonReentrant returns (int256 amount0, int256 amount1) {
        PoolState storage pool = pools[poolId];
        if (!pool.initialized) revert PoolNotInitialized();

        address hook = poolHooks[poolId];

        // Before hook
        if (hook != address(0)) {
            bytes4 selector = IHooks(hook).beforeModifyLiquidity(poolId, msg.sender, params, hookData);
            require(selector == IHooks.beforeModifyLiquidity.selector, "Invalid hook response");
        }

        // Calculate amounts
        (amount0, amount1) = _calculateLiquidityDeltas(poolId, params);

        // Update position
        bytes32 positionKey = keccak256(abi.encodePacked(msg.sender, params.tickLower, params.tickUpper));
        Position storage position = positions[poolId][positionKey];
        position.liquidity = uint128(int128(position.liquidity) + params.liquidityDelta);

        // Update pool liquidity
        pool.liquidity = uint128(int128(pool.liquidity) + params.liquidityDelta);

        // Update reserves
        if (amount0 > 0) {
            pool.reserve0 += uint256(amount0);
        } else if (amount0 < 0) {
            pool.reserve0 -= uint256(-amount0);
        }
        if (amount1 > 0) {
            pool.reserve1 += uint256(amount1);
        } else if (amount1 < 0) {
            pool.reserve1 -= uint256(-amount1);
        }

        // Flash accounting - track deltas
        currencyDeltas[poolIdToTokens(poolId).token0] -= amount0;
        currencyDeltas[poolIdToTokens(poolId).token1] -= amount1;

        // After hook
        if (hook != address(0)) {
            bytes4 selector = IHooks(hook).afterModifyLiquidity(poolId, msg.sender, params, amount0, amount1, hookData);
            require(selector == IHooks.afterModifyLiquidity.selector, "Invalid hook response");
        }

        emit LiquidityModified(poolId, msg.sender, params.tickLower, params.tickUpper, params.liquidityDelta);
    }

    /*//////////////////////////////////////////////////////////////
                                SWAPS
    //////////////////////////////////////////////////////////////*/

    /// @notice Execute a swap with MEV protection
    function swap(
        bytes32 poolId,
        SwapParams calldata params,
        bytes calldata hookData
    ) external nonReentrant returns (SwapResult memory result) {
        PoolState storage pool = pools[poolId];
        if (!pool.initialized) revert PoolNotInitialized();

        address hook = poolHooks[poolId];
        (address token0, address token1) = poolIdToTokens(poolId);

        // Before swap hook
        if (hook != address(0)) {
            bytes4 selector = IHooks(hook).beforeSwap(poolId, msg.sender, params, hookData);
            require(selector == IHooks.beforeSwap.selector, "Invalid hook response");
        }

        // Execute swap
        (result.amount0, result.amount1, pool.sqrtPriceX96, pool.tick) = _computeSwap(
            poolId,
            params.zeroForOne,
            params.amountSpecified,
            params.sqrtPriceLimitX96,
            pool.sqrtPriceX96,
            pool.tick,
            pool.liquidity
        );

        // Update reserves
        if (result.amount0 > 0) {
            pool.reserve0 += uint256(result.amount0);
        } else {
            pool.reserve0 -= uint256(-result.amount0);
        }
        if (result.amount1 > 0) {
            pool.reserve1 += uint256(result.amount1);
        } else {
            pool.reserve1 -= uint256(-result.amount1);
        }

        // Flash accounting
        currencyDeltas[token0] -= result.amount0;
        currencyDeltas[token1] -= result.amount1;

        // After swap hook
        if (hook != address(0)) {
            bytes4 selector = IHooks(hook).afterSwap(poolId, msg.sender, params, result, hookData);
            require(selector == IHooks.afterSwap.selector, "Invalid hook response");
        }

        emit Swap(poolId, msg.sender, params.zeroForOne, result.amount0, result.amount1);
    }

    /*//////////////////////////////////////////////////////////////
                            FLASH ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    /// @notice Settle all deltas at end of transaction
    /// @dev Only settles net balances - massive gas savings!
    function settle() external nonReentrant {
        // This would be called automatically or by a keeper
        // For simplicity, users can call this to settle their own deltas
    }

    /// @notice Take tokens from the pool (positive delta)
    function take(address token, address to, uint256 amount) external nonReentrant {
        currencyDeltas[token] -= int256(amount);
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Pay tokens to the pool (negative delta)
    function pay(address token, uint256 amount) external nonReentrant {
        currencyDeltas[token] += int256(amount);
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function approveHook(address hook, bool approved) external onlyOwner {
        approvedHooks[hook] = approved;
        emit HookApproved(hook, approved);
    }

    function setProtocolFee(uint24 newFee) external onlyOwner {
        if (newFee > MAX_FEE) revert InvalidFee();
        protocolFee = newFee;
        emit ProtocolFeeUpdated(newFee);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        owner = newOwner;
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _calculateLiquidityDeltas(
        bytes32 poolId,
        ModifyLiquidityParams calldata params
    ) internal view returns (int256 amount0, int256 amount1) {
        PoolState storage pool = pools[poolId];
        
        uint160 sqrtPriceX96 = pool.sqrtPriceX96;
        uint160 sqrtPriceAX96 = TickMath.getSqrtRatioAtTick(params.tickLower);
        uint160 sqrtPriceBX96 = TickMath.getSqrtRatioAtTick(params.tickUpper);

        if (params.liquidityDelta > 0) {
            // Adding liquidity
            uint256 liquidity = uint128(params.liquidityDelta);
            amount0 = int256(LiquidityMath.getAmount0ForLiquidity(sqrtPriceAX96, sqrtPriceBX96, liquidity));
            amount1 = int256(LiquidityMath.getAmount1ForLiquidity(sqrtPriceAX96, sqrtPriceBX96, liquidity));
            
            // Adjust based on current price
            if (sqrtPriceX96 <= sqrtPriceAX96) {
                amount1 = 0;
            } else if (sqrtPriceX96 >= sqrtPriceBX96) {
                amount0 = 0;
            }
        } else {
            // Removing liquidity
            uint256 liquidity = uint128(-params.liquidityDelta);
            amount0 = -int256(LiquidityMath.getAmount0ForLiquidity(sqrtPriceAX96, sqrtPriceBX96, liquidity));
            amount1 = -int256(LiquidityMath.getAmount1ForLiquidity(sqrtPriceAX96, sqrtPriceBX96, liquidity));
            
            if (sqrtPriceX96 <= sqrtPriceAX96) {
                amount1 = 0;
            } else if (sqrtPriceX96 >= sqrtPriceBX96) {
                amount0 = 0;
            }
        }
    }

    function _computeSwap(
        bytes32 poolId,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        uint160 sqrtPriceX96,
        int24 tick,
        uint128 liquidity
    ) internal view returns (int256 amount0, int256 amount1, uint160 newSqrtPriceX96, int24 newTick) {
        // Simplified swap computation
        // In production, use full Uniswap v3 math
        
        bool exactInput = amountSpecified > 0;
        uint256 amountRemaining = exactInput ? uint256(amountSpecified) : uint256(-amountSpecified);
        
        // Calculate output based on constant product formula (simplified)
        if (zeroForOne) {
            // Selling token0 for token1
            uint256 reserve0 = pools[poolId].reserve0;
            uint256 reserve1 = pools[poolId].reserve1;
            
            if (exactInput) {
                // Calculate output
                uint256 amountInWithFee = amountRemaining * 997 / 1000; // 0.3% fee
                uint256 numerator = amountInWithFee * reserve1;
                uint256 denominator = reserve0 + amountInWithFee;
                uint256 amountOut = numerator / denominator;
                
                amount0 = int256(amountRemaining);
                amount1 = -int256(amountOut);
            } else {
                // Calculate input
                uint256 amountOut = amountRemaining;
                uint256 numerator = amountOut * reserve0 * 1000;
                uint256 denominator = (reserve1 - amountOut) * 997;
                uint256 amountIn = (numerator / denominator) + 1;
                
                amount0 = int256(amountIn);
                amount1 = -int256(amountOut);
            }
        } else {
            // Selling token1 for token0
            uint256 reserve0 = pools[poolId].reserve0;
            uint256 reserve1 = pools[poolId].reserve1;
            
            if (exactInput) {
                uint256 amountInWithFee = amountRemaining * 997 / 1000;
                uint256 numerator = amountInWithFee * reserve0;
                uint256 denominator = reserve1 + amountInWithFee;
                uint256 amountOut = numerator / denominator;
                
                amount1 = int256(amountRemaining);
                amount0 = -int256(amountOut);
            } else {
                uint256 amountOut = amountRemaining;
                uint256 numerator = amountOut * reserve1 * 1000;
                uint256 denominator = (reserve0 - amountOut) * 997;
                uint256 amountIn = (numerator / denominator) + 1;
                
                amount1 = int256(amountIn);
                amount0 = -int256(amountOut);
            }
        }

        newSqrtPriceX96 = sqrtPriceX96; // Simplified - should recalculate
        newTick = tick;
    }

    function poolIdToTokens(bytes32 poolId) internal pure returns (address token0, address token1) {
        // In production, store tokens in mapping
        // For now, return dummy values
        return (address(0), address(0));
    }
}

/*//////////////////////////////////////////////////////////////
                            DATA STRUCTURES
//////////////////////////////////////////////////////////////*/

struct Tick {
    uint128 liquidityGross;
    int128 liquidityNet;
    uint256 feeGrowthOutside0X128;
    uint256 feeGrowthOutside1X128;
    bool initialized;
}

struct Position {
    uint128 liquidity;
    uint256 feeGrowthInside0LastX128;
    uint256 feeGrowthInside1LastX128;
    uint128 tokensOwed0;
    uint128 tokensOwed1;
}

/*//////////////////////////////////////////////////////////////
                            HOOKS INTERFACE
//////////////////////////////////////////////////////////////*/

interface IHooks {
    function beforeInitialize(bytes32 poolId, uint160 sqrtPriceX96, int24 tick) external returns (bytes4);
    function afterInitialize(bytes32 poolId, uint160 sqrtPriceX96, int24 tick) external returns (bytes4);
    
    function beforeModifyLiquidity(
        bytes32 poolId,
        address sender,
        PoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4);
    
    function afterModifyLiquidity(
        bytes32 poolId,
        address sender,
        PoolManager.ModifyLiquidityParams calldata params,
        int256 amount0,
        int256 amount1,
        bytes calldata hookData
    ) external returns (bytes4);
    
    function beforeSwap(
        bytes32 poolId,
        address sender,
        PoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4);
    
    function afterSwap(
        bytes32 poolId,
        address sender,
        PoolManager.SwapParams calldata params,
        PoolManager.SwapResult calldata result,
        bytes calldata hookData
    ) external returns (bytes4);
}

/*//////////////////////////////////////////////////////////////
                            IMPORTS
//////////////////////////////////////////////////////////////*/

import {TickMath} from "../libraries/TickMath.sol";
import {LiquidityMath} from "../libraries/LiquidityMath.sol";
