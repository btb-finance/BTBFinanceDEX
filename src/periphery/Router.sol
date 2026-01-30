// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRouter} from "../interfaces/IRouter.sol";
import {IPool} from "../interfaces/IPool.sol";
import {IPoolFactory} from "../interfaces/IPoolFactory.sol";
import {IWETH} from "../interfaces/IWETH.sol";
import {Math} from "../libraries/Math.sol";

/// @title BTB Finance Router
/// @author BTB Finance
/// @notice Router for swapping and providing liquidity on V2-style pools
/// @dev Handles token transfers, wrapping/unwrapping ETH, and multi-hop swaps
contract Router is IRouter {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRouter
    address public immutable override factory;

    /// @inheritdoc IRouter
    address public immutable override weth;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _factory, address _weth) {
        factory = _factory;
        weth = _weth;
    }

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier ensure(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRouter
    function sortTokens(address tokenA, address tokenB)
        public
        pure
        override
        returns (address token0, address token1)
    {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    /// @inheritdoc IRouter
    function poolFor(address tokenA, address tokenB, bool stable) public view override returns (address pool) {
        return IPoolFactory(factory).getPool(tokenA, tokenB, stable);
    }

    /// @inheritdoc IRouter
    function getReserves(address tokenA, address tokenB, bool stable)
        public
        view
        override
        returns (uint256 reserveA, uint256 reserveB)
    {
        (address token0,) = sortTokens(tokenA, tokenB);
        (uint256 reserve0, uint256 reserve1,) = IPool(poolFor(tokenA, tokenB, stable)).getReserves();
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    /// @inheritdoc IRouter
    function getAmountOut(uint256 amountIn, address tokenIn, address tokenOut, bool stable)
        public
        view
        override
        returns (uint256 amount)
    {
        address pool = poolFor(tokenIn, tokenOut, stable);
        if (pool == address(0)) revert RouteNotFound();
        return IPool(pool).getAmountOut(amountIn, tokenIn);
    }

    /// @inheritdoc IRouter
    function getAmountsOut(uint256 amountIn, Route[] calldata routes)
        public
        view
        override
        returns (uint256[] memory amounts)
    {
        if (routes.length == 0) revert InvalidPath();
        amounts = new uint256[](routes.length + 1);
        amounts[0] = amountIn;

        for (uint256 i = 0; i < routes.length; i++) {
            amounts[i + 1] = getAmountOut(amounts[i], routes[i].from, routes[i].to, routes[i].stable);
        }
    }

    /// @inheritdoc IRouter
    function quoteAddLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 amountADesired,
        uint256 amountBDesired
    ) public view override returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        address pool = poolFor(tokenA, tokenB, stable);

        if (pool == address(0)) {
            // New pool - return desired amounts
            (amountA, amountB) = (amountADesired, amountBDesired);
            liquidity = Math.sqrt(amountA * amountB) - 1000;
        } else {
            (uint256 reserveA, uint256 reserveB) = getReserves(tokenA, tokenB, stable);
            uint256 amountBOptimal = (amountADesired * reserveB) / reserveA;

            if (amountBOptimal <= amountBDesired) {
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint256 amountAOptimal = (amountBDesired * reserveA) / reserveB;
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }

            uint256 totalSupply = IERC20(pool).totalSupply();
            liquidity = Math.min((amountA * totalSupply) / reserveA, (amountB * totalSupply) / reserveB);
        }
    }

    /// @inheritdoc IRouter
    function quoteRemoveLiquidity(address tokenA, address tokenB, bool stable, uint256 liquidity)
        public
        view
        override
        returns (uint256 amountA, uint256 amountB)
    {
        address pool = poolFor(tokenA, tokenB, stable);
        if (pool == address(0)) return (0, 0);

        (uint256 reserveA, uint256 reserveB) = getReserves(tokenA, tokenB, stable);
        uint256 totalSupply = IERC20(pool).totalSupply();

        amountA = (liquidity * reserveA) / totalSupply;
        amountB = (liquidity * reserveB) / totalSupply;
    }

    /*//////////////////////////////////////////////////////////////
                          LIQUIDITY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRouter
    function addLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) public override ensure(deadline) returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        (amountA, amountB) = _addLiquidity(tokenA, tokenB, stable, amountADesired, amountBDesired, amountAMin, amountBMin);

        address pool = poolFor(tokenA, tokenB, stable);
        IERC20(tokenA).safeTransferFrom(msg.sender, pool, amountA);
        IERC20(tokenB).safeTransferFrom(msg.sender, pool, amountB);
        liquidity = IPool(pool).mint(to);
    }

    /// @inheritdoc IRouter
    function addLiquidityETH(
        address token,
        bool stable,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) public payable override ensure(deadline) returns (uint256 amountToken, uint256 amountETH, uint256 liquidity) {
        (amountToken, amountETH) =
            _addLiquidity(token, weth, stable, amountTokenDesired, msg.value, amountTokenMin, amountETHMin);

        address pool = poolFor(token, weth, stable);
        IERC20(token).safeTransferFrom(msg.sender, pool, amountToken);
        IWETH(weth).deposit{value: amountETH}();
        IERC20(weth).safeTransfer(pool, amountETH);
        liquidity = IPool(pool).mint(to);

        // Refund excess ETH
        if (msg.value > amountETH) {
            _safeTransferETH(msg.sender, msg.value - amountETH);
        }
    }

    /// @inheritdoc IRouter
    function removeLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) public override ensure(deadline) returns (uint256 amountA, uint256 amountB) {
        address pool = poolFor(tokenA, tokenB, stable);
        IERC20(pool).safeTransferFrom(msg.sender, pool, liquidity);
        (uint256 amount0, uint256 amount1) = IPool(pool).burn(to);

        (address token0,) = sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);

        if (amountA < amountAMin) revert InsufficientAAmount();
        if (amountB < amountBMin) revert InsufficientBAmount();
    }

    /// @inheritdoc IRouter
    function removeLiquidityETH(
        address token,
        bool stable,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) public override ensure(deadline) returns (uint256 amountToken, uint256 amountETH) {
        (amountToken, amountETH) =
            removeLiquidity(token, weth, stable, liquidity, amountTokenMin, amountETHMin, address(this), deadline);

        IERC20(token).safeTransfer(to, amountToken);
        IWETH(weth).withdraw(amountETH);
        _safeTransferETH(to, amountETH);
    }

    /*//////////////////////////////////////////////////////////////
                            SWAP FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRouter
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) public override ensure(deadline) returns (uint256[] memory amounts) {
        amounts = getAmountsOut(amountIn, routes);
        if (amounts[amounts.length - 1] < amountOutMin) revert InsufficientOutputAmount();

        IERC20(routes[0].from).safeTransferFrom(msg.sender, poolFor(routes[0].from, routes[0].to, routes[0].stable), amounts[0]);
        _swap(amounts, routes, to);
    }

    /// @inheritdoc IRouter
    function swapExactETHForTokens(uint256 amountOutMin, Route[] calldata routes, address to, uint256 deadline)
        public
        payable
        override
        ensure(deadline)
        returns (uint256[] memory amounts)
    {
        if (routes[0].from != weth) revert InvalidPath();
        amounts = getAmountsOut(msg.value, routes);
        if (amounts[amounts.length - 1] < amountOutMin) revert InsufficientOutputAmount();

        IWETH(weth).deposit{value: amounts[0]}();
        IERC20(weth).safeTransfer(poolFor(routes[0].from, routes[0].to, routes[0].stable), amounts[0]);
        _swap(amounts, routes, to);
    }

    /// @inheritdoc IRouter
    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) public override ensure(deadline) returns (uint256[] memory amounts) {
        if (routes[routes.length - 1].to != weth) revert InvalidPath();
        amounts = getAmountsOut(amountIn, routes);
        if (amounts[amounts.length - 1] < amountOutMin) revert InsufficientOutputAmount();

        IERC20(routes[0].from).safeTransferFrom(msg.sender, poolFor(routes[0].from, routes[0].to, routes[0].stable), amounts[0]);
        _swap(amounts, routes, address(this));

        IWETH(weth).withdraw(amounts[amounts.length - 1]);
        _safeTransferETH(to, amounts[amounts.length - 1]);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _addLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) internal returns (uint256 amountA, uint256 amountB) {
        // Create pool if it doesn't exist
        if (IPoolFactory(factory).getPool(tokenA, tokenB, stable) == address(0)) {
            IPoolFactory(factory).createPool(tokenA, tokenB, stable);
        }

        (uint256 reserveA, uint256 reserveB) = getReserves(tokenA, tokenB, stable);

        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint256 amountBOptimal = (amountADesired * reserveB) / reserveA;
            if (amountBOptimal <= amountBDesired) {
                if (amountBOptimal < amountBMin) revert InsufficientBAmount();
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint256 amountAOptimal = (amountBDesired * reserveA) / reserveB;
                if (amountAOptimal < amountAMin) revert InsufficientAAmount();
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }

    function _swap(uint256[] memory amounts, Route[] calldata routes, address _to) internal {
        for (uint256 i = 0; i < routes.length; i++) {
            (address tokenIn, address tokenOut, bool stable) = (routes[i].from, routes[i].to, routes[i].stable);
            (address token0,) = sortTokens(tokenIn, tokenOut);

            uint256 amountOut = amounts[i + 1];
            (uint256 amount0Out, uint256 amount1Out) =
                tokenIn == token0 ? (uint256(0), amountOut) : (amountOut, uint256(0));

            address to = i < routes.length - 1 ? poolFor(routes[i + 1].from, routes[i + 1].to, routes[i + 1].stable) : _to;
            IPool(poolFor(tokenIn, tokenOut, stable)).swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }

    function _safeTransferETH(address to, uint256 amount) internal {
        (bool success,) = to.call{value: amount}("");
        if (!success) revert ETHTransferFailed();
    }

    /*//////////////////////////////////////////////////////////////
                              ZAP FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Zap in with single token - swap half, add liquidity in one tx
    function zapIn(
        address tokenIn,
        uint256 amountIn,
        address token0,
        address token1,
        bool stable,
        uint256 minLpOut,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256 liquidity) {
        if (amountIn == 0) revert InsufficientInputAmount();

        // Transfer tokens to this contract
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        address pool = poolFor(token0, token1, stable);
        if (pool == address(0)) revert PoolDoesNotExist();

        // If tokenIn is not one of the pair, need to swap first
        if (tokenIn != token0 && tokenIn != token1) {
            revert("Zap from third token not supported");
        }

        // Split 50/50
        uint256 half = amountIn / 2;

        // Swap half to other token
        if (tokenIn == token0) {
            // Swap half to token1
            if (half > 0) {
                uint256 amountOut = IPool(pool).getAmountOut(half, token0);
                IERC20(token0).safeTransfer(pool, half);
                IPool(pool).swap(0, amountOut, address(this), new bytes(0));
            }
        } else {
            // Swap half to token0
            if (half > 0) {
                uint256 amountOut = IPool(pool).getAmountOut(half, token1);
                IERC20(token1).safeTransfer(pool, half);
                IPool(pool).swap(amountOut, 0, address(this), new bytes(0));
            }
        }

        // Add liquidity
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        
        IERC20(token0).safeTransfer(pool, balance0);
        IERC20(token1).safeTransfer(pool, balance1);
        
        liquidity = IPool(pool).mint(to);
        if (liquidity < minLpOut) revert InsufficientOutputAmount();

        // Refund dust
        uint256 dust0 = IERC20(token0).balanceOf(address(this));
        uint256 dust1 = IERC20(token1).balanceOf(address(this));
        if (dust0 > 0) IERC20(token0).safeTransfer(msg.sender, dust0);
        if (dust1 > 0) IERC20(token1).safeTransfer(msg.sender, dust1);
    }

    /// @notice Zap out - remove liquidity and swap to single token
    function zapOut(
        address pool,
        uint256 liquidity,
        address tokenOut,
        uint256 minOut,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256 amountOut) {
        if (liquidity == 0) revert InsufficientInputAmount();

        // Transfer LP to pool
        IERC20(pool).safeTransferFrom(msg.sender, pool, liquidity);
        
        // Burn LP
        (uint256 amount0, uint256 amount1) = IPool(pool).burn(address(this));

        address token0 = IPool(pool).token0();
        address token1 = IPool(pool).token1();

        // Swap to desired output
        if (tokenOut == token0 && amount1 > 0) {
            IERC20(token1).safeTransfer(pool, amount1);
            uint256 swapOut = IPool(pool).getAmountOut(amount1, token1);
            IPool(pool).swap(swapOut, 0, address(this), new bytes(0));
        } else if (tokenOut == token1 && amount0 > 0) {
            IERC20(token0).safeTransfer(pool, amount0);
            uint256 swapOut = IPool(pool).getAmountOut(amount0, token0);
            IPool(pool).swap(0, swapOut, address(this), new bytes(0));
        } else if (tokenOut != token0 && tokenOut != token1) {
            revert InvalidPath();
        }

        amountOut = IERC20(tokenOut).balanceOf(address(this));
        if (amountOut < minOut) revert InsufficientOutputAmount();
        
        IERC20(tokenOut).safeTransfer(to, amountOut);
    }

    /*//////////////////////////////////////////////////////////////
                              RECEIVE ETH
    //////////////////////////////////////////////////////////////*/

    receive() external payable {
        if (msg.sender != weth) revert OnlyWETH();
    }
}
