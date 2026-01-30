// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/// @title IRouter Interface
/// @notice Interface for the BTB Finance router
interface IRouter {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error Expired();
    error InsufficientOutputAmount();
    error InsufficientInputAmount();
    error InsufficientAAmount();
    error InsufficientBAmount();
    error InvalidPath();
    error InvalidAmountIn();
    error RouteNotFound();
    error ETHTransferFailed();
    error OnlyWETH();
    error PoolDoesNotExist();

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct Route {
        address from;
        address to;
        bool stable;
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the factory address
    function factory() external view returns (address);

    /// @notice Returns the WETH address
    function weth() external view returns (address);

    /// @notice Sort tokens to get token0/token1
    function sortTokens(address tokenA, address tokenB) external pure returns (address token0, address token1);

    /// @notice Get pool address for token pair
    function poolFor(address tokenA, address tokenB, bool stable) external view returns (address pool);

    /// @notice Get reserves for pool
    function getReserves(address tokenA, address tokenB, bool stable)
        external
        view
        returns (uint256 reserveA, uint256 reserveB);

    /// @notice Get output amount for given input
    function getAmountOut(uint256 amountIn, address tokenIn, address tokenOut, bool stable)
        external
        view
        returns (uint256 amount);

    /// @notice Get output amounts for a path
    function getAmountsOut(uint256 amountIn, Route[] calldata routes) external view returns (uint256[] memory amounts);

    /// @notice Quote add liquidity amounts
    function quoteAddLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 amountADesired,
        uint256 amountBDesired
    ) external view returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    /// @notice Quote remove liquidity amounts
    function quoteRemoveLiquidity(address tokenA, address tokenB, bool stable, uint256 liquidity)
        external
        view
        returns (uint256 amountA, uint256 amountB);

    /*//////////////////////////////////////////////////////////////
                            WRITE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Add liquidity to a pool
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
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    /// @notice Add liquidity with ETH
    function addLiquidityETH(
        address token,
        bool stable,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);

    /// @notice Remove liquidity from a pool
    function removeLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);

    /// @notice Remove liquidity with ETH
    function removeLiquidityETH(
        address token,
        bool stable,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountToken, uint256 amountETH);

    /// @notice Swap exact tokens for tokens
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    /// @notice Swap exact ETH for tokens
    function swapExactETHForTokens(uint256 amountOutMin, Route[] calldata routes, address to, uint256 deadline)
        external
        payable
        returns (uint256[] memory amounts);

    /// @notice Swap exact tokens for ETH
    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}
