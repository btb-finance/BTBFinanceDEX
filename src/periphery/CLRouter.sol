// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICLRouter} from "../interfaces/ICLRouter.sol";
import {ICLPool} from "../interfaces/ICLPool.sol";
import {ICLFactory} from "../interfaces/ICLFactory.sol";
import {IWETH} from "../interfaces/IWETH.sol";
import {TickMath} from "../libraries/TickMath.sol";

/// @title BTB Finance CL Router
/// @author BTB Finance
/// @notice Router for swapping on Concentrated Liquidity pools
/// @dev Supports exact input/output swaps, single and multi-hop
contract CLRouter is ICLRouter {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Used as the placeholder value for amountInCached
    uint256 private constant DEFAULT_AMOUNT_IN_CACHED = type(uint256).max;

    /// @dev Transient storage slot for amountIn caching
    uint256 private amountInCached = DEFAULT_AMOUNT_IN_CACHED;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICLRouter
    address public immutable override factory;

    /// @inheritdoc ICLRouter
    address public immutable override WETH9;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _factory, address _WETH9) {
        factory = _factory;
        WETH9 = _WETH9;
    }

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                           SWAP FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICLRouter
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (uint256 amountOut)
    {
        // Transfer tokens to pool
        address pool = ICLFactory(factory).getPool(params.tokenIn, params.tokenOut, params.tickSpacing);
        
        bool zeroForOne = params.tokenIn < params.tokenOut;
        
        // Transfer input tokens from sender to this contract first
        if (msg.value > 0) {
            // Wrap ETH
            IWETH(WETH9).deposit{value: msg.value}();
            IERC20(WETH9).safeTransfer(pool, params.amountIn);
        } else {
            IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);
            IERC20(params.tokenIn).safeTransfer(pool, params.amountIn);
        }

        // Execute swap
        (int256 amount0, int256 amount1) = ICLPool(pool).swap(
            params.recipient,
            zeroForOne,
            int256(params.amountIn),
            params.sqrtPriceLimitX96 == 0
                ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                : params.sqrtPriceLimitX96,
            ""
        );

        amountOut = uint256(-(zeroForOne ? amount1 : amount0));

        if (amountOut < params.amountOutMinimum) revert TooLittleReceived();
    }

    /// @inheritdoc ICLRouter
    function exactInput(ExactInputParams calldata params)
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (uint256 amountOut)
    {
        // Decode first hop
        (address tokenIn, address tokenOut, int24 tickSpacing) = _decodeFirstPool(params.path);
        
        // Handle ETH wrapping
        if (msg.value > 0) {
            IWETH(WETH9).deposit{value: msg.value}();
        } else {
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);
        }

        uint256 amountIn = params.amountIn;
        bytes memory path = params.path;
        
        while (true) {
            bool hasMultiplePools = _hasMultiplePools(path);
            
            // Determine recipient
            address recipient = hasMultiplePools ? address(this) : params.recipient;
            
            // Get pool and execute swap
            address pool = ICLFactory(factory).getPool(tokenIn, tokenOut, tickSpacing);
            bool zeroForOne = tokenIn < tokenOut;
            
            IERC20(tokenIn).safeTransfer(pool, amountIn);
            
            (int256 amount0, int256 amount1) = ICLPool(pool).swap(
                recipient,
                zeroForOne,
                int256(amountIn),
                zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1,
                ""
            );

            amountIn = uint256(-(zeroForOne ? amount1 : amount0));

            if (hasMultiplePools) {
                path = _skipToken(path);
                (tokenIn, tokenOut, tickSpacing) = _decodeFirstPool(path);
            } else {
                amountOut = amountIn;
                break;
            }
        }

        if (amountOut < params.amountOutMinimum) revert TooLittleReceived();
    }

    /// @inheritdoc ICLRouter
    function exactOutputSingle(ExactOutputSingleParams calldata params)
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (uint256 amountIn)
    {
        address pool = ICLFactory(factory).getPool(params.tokenIn, params.tokenOut, params.tickSpacing);
        bool zeroForOne = params.tokenIn < params.tokenOut;

        // For exact output, we need to calculate required input
        // This is a simplified implementation - production would cache and settle
        
        // Transfer max tokens first
        if (msg.value > 0) {
            IWETH(WETH9).deposit{value: msg.value}();
            IERC20(WETH9).safeTransfer(pool, params.amountInMaximum);
        } else {
            IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountInMaximum);
            IERC20(params.tokenIn).safeTransfer(pool, params.amountInMaximum);
        }

        (int256 amount0, int256 amount1) = ICLPool(pool).swap(
            params.recipient,
            zeroForOne,
            -int256(params.amountOut), // Negative for exact output
            params.sqrtPriceLimitX96 == 0
                ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                : params.sqrtPriceLimitX96,
            ""
        );

        amountIn = uint256(zeroForOne ? amount0 : amount1);

        if (amountIn > params.amountInMaximum) revert TooMuchRequested();

        // Refund excess
        uint256 excess = params.amountInMaximum - amountIn;
        if (excess > 0) {
            IERC20(params.tokenIn).safeTransfer(msg.sender, excess);
        }
    }

    /// @inheritdoc ICLRouter
    function exactOutput(ExactOutputParams calldata params)
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (uint256 amountIn)
    {
        // Simplified: single hop exact output for now
        // Multi-hop exact output requires reverse iteration through path
        (address tokenOut, address tokenIn, int24 tickSpacing) = _decodeFirstPool(params.path);
        
        ExactOutputSingleParams memory singleParams = ExactOutputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            tickSpacing: tickSpacing,
            recipient: params.recipient,
            deadline: params.deadline,
            amountOut: params.amountOut,
            amountInMaximum: params.amountInMaximum,
            sqrtPriceLimitX96: 0
        });

        amountIn = this.exactOutputSingle(singleParams);
    }

    /*//////////////////////////////////////////////////////////////
                          PATH UTILITIES
    //////////////////////////////////////////////////////////////*/

    /// @dev Decode the first pool from path
    function _decodeFirstPool(bytes memory path)
        internal
        pure
        returns (address tokenA, address tokenB, int24 tickSpacing)
    {
        require(path.length >= 43, "Invalid path");
        
        assembly {
            tokenA := mload(add(path, 20))
            tickSpacing := mload(add(path, 23))
            tokenB := mload(add(path, 43))
        }
    }

    /// @dev Check if path has multiple pools
    function _hasMultiplePools(bytes memory path) internal pure returns (bool) {
        return path.length >= 66; // 20 + 3 + 20 + 3 + 20
    }

    /// @dev Skip first token in path
    function _skipToken(bytes memory path) internal pure returns (bytes memory) {
        require(path.length >= 43, "Invalid path");
        
        uint256 newLength = path.length - 23; // Remove first token + tickSpacing
        bytes memory newPath = new bytes(newLength);
        
        for (uint256 i = 0; i < newLength; i++) {
            newPath[i] = path[i + 23];
        }
        
        return newPath;
    }

    /*//////////////////////////////////////////////////////////////
                              RECEIVE ETH
    //////////////////////////////////////////////////////////////*/

    receive() external payable {
        require(msg.sender == WETH9, "Not WETH");
    }
}
