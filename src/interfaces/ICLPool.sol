// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/// @title ICLPool Interface
/// @notice Interface for BTB Finance Concentrated Liquidity pools
interface ICLPool {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error Locked();
    error ZeroLiquidity();
    error InsufficientInputAmount();
    error InsufficientOutputAmount();
    error InvalidTick();
    error TickSpacingTooLarge();
    error TickSpacingTooSmall();
    error NotInitialized();
    error AlreadyInitialized();
    error InvalidSqrtPrice();
    error InvalidTickRange();
    error TransferFailed();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Initialize(uint160 sqrtPriceX96, int24 tick);
    event Mint(
        address indexed sender,
        address indexed owner,
        int24 indexed tickLower,
        int24 tickUpper,
        uint128 amount,
        uint256 amount0,
        uint256 amount1
    );
    event Burn(
        address indexed owner,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        uint128 amount,
        uint256 amount0,
        uint256 amount1
    );
    event Swap(
        address indexed sender,
        address indexed recipient,
        int256 amount0,
        int256 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick
    );
    event Collect(
        address indexed owner,
        address recipient,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        uint256 amount0,
        uint256 amount1
    );
    event CollectFees(address indexed recipient, uint256 amount0, uint256 amount1);

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct Slot0 {
        /// @notice Current sqrt(price) as Q64.96
        uint160 sqrtPriceX96;
        /// @notice Current tick
        int24 tick;
        /// @notice Whether the pool is locked
        bool unlocked;
    }

    struct Position {
        /// @notice Liquidity of the position
        uint128 liquidity;
        /// @notice Fee growth of token0 inside the position's tick range
        uint256 feeGrowthInside0LastX128;
        /// @notice Fee growth of token1 inside the position's tick range
        uint256 feeGrowthInside1LastX128;
        /// @notice Tokens owed to the position owner (token0)
        uint128 tokensOwed0;
        /// @notice Tokens owed to the position owner (token1)
        uint128 tokensOwed1;
    }

    struct TickInfo {
        /// @notice Total liquidity that references this tick
        uint128 liquidityGross;
        /// @notice Net liquidity change when tick is crossed
        int128 liquidityNet;
        /// @notice Fee growth per unit of liquidity on the other side of this tick (token0)
        uint256 feeGrowthOutside0X128;
        /// @notice Fee growth per unit of liquidity on the other side of this tick (token1)
        uint256 feeGrowthOutside1X128;
        /// @notice Whether the tick is initialized
        bool initialized;
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function tickSpacing() external view returns (int24);
    function fee() external view returns (uint24);
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, bool unlocked);
    function liquidity() external view returns (uint128);
    function feeGrowthGlobal0X128() external view returns (uint256);
    function feeGrowthGlobal1X128() external view returns (uint256);
    function ticks(int24 tick) external view returns (TickInfo memory);
    function positions(bytes32 key) external view returns (Position memory);

    /*//////////////////////////////////////////////////////////////
                            WRITE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialize the pool with a sqrt price
    function initialize(uint160 sqrtPriceX96) external;

    /// @notice Add liquidity to a position
    function mint(address recipient, int24 tickLower, int24 tickUpper, uint128 amount, bytes calldata data)
        external
        returns (uint256 amount0, uint256 amount1);

    /// @notice Remove liquidity from a position
    function burn(int24 tickLower, int24 tickUpper, uint128 amount)
        external
        returns (uint256 amount0, uint256 amount1);

    /// @notice Collect tokens owed to a position
    function collect(address recipient, int24 tickLower, int24 tickUpper, uint128 amount0Requested, uint128 amount1Requested)
        external
        returns (uint256 amount0, uint256 amount1);

    /// @notice Swap token0 for token1, or token1 for token0
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}
