// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/// @title IPool Interface
/// @notice Interface for BTB Finance V2-style AMM pools (volatile/stable)
interface IPool {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error InsufficientLiquidity();
    error InsufficientLiquidityMinted();
    error InsufficientLiquidityBurned();
    error InsufficientOutputAmount();
    error InsufficientInputAmount();
    error InvalidTo();
    error K();
    error NotFactory();
    error Locked();
    error SlippageExceeded();
    error FlashLoanCallbackFailed();
    error FlashLoanNotRepaid();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);
    event Fees(address indexed sender, uint256 amount0, uint256 amount1);
    event Claim(address indexed sender, address indexed recipient, uint256 amount0, uint256 amount1);
    event FlashLoan(address indexed receiver, uint256 token0Amount, uint256 token1Amount, uint256 fee0, uint256 fee1);

    /*//////////////////////////////////////////////////////////////
                               VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice The first token of the pool
    function token0() external view returns (address);

    /// @notice The second token of the pool
    function token1() external view returns (address);

    /// @notice Whether the pool uses stable curve math
    function stable() external view returns (bool);

    /// @notice The pool factory address
    function factory() external view returns (address);

    /// @notice Get current reserves
    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    /// @notice Calculate output amount for given input
    function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256);

    /// @notice Price observation for TWAP
    function observationLength() external view returns (uint256);

    /// @notice Get the current K value
    function getK() external view returns (uint256);

    /// @notice Claimable fees for LP holder
    function claimable0(address account) external view returns (uint256);
    function claimable1(address account) external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                             WRITE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialize pool with tokens (called by factory)
    function initialize(address token0, address token1, bool stable) external;

    /// @notice Mint LP tokens
    function mint(address to) external returns (uint256 liquidity);

    /// @notice Burn LP tokens and receive underlying
    function burn(address to) external returns (uint256 amount0, uint256 amount1);

    /// @notice Swap tokens
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;

    /// @notice Swap tokens with slippage protection
    function swapWithSlippage(
        uint256 amount0Out,
        uint256 amount1Out,
        uint256 minOutput,
        address to,
        bytes calldata data
    ) external;

    /// @notice Sync reserves to balances
    function sync() external;

    /// @notice Skim excess tokens
    function skim(address to) external;

    /// @notice Claim accumulated trading fees
    function claimFees() external returns (uint256 claimed0, uint256 claimed1);

    /// @notice Receive BTB rewards from voter when pool receives votes
    function notifyRewardAmount(uint256 amount) external;
}

/// @title IPoolCallee Interface
/// @notice Interface for contracts that can receive flash loans/swaps
interface IPoolCallee {
    function poolCall(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

/// @title IFeeDistributor Interface
/// @notice Interface for fee distributor that sends 100% of fees to veBTB holders
interface IFeeDistributor {
    /// @notice Collect fees from a pool
    function collectFees(address token, uint256 amount) external;
    
    /// @notice Check claimable fees for a user
    function claimable(address user, address token) external view returns (uint256);
    
    /// @notice Claim fees for a user
    function claim(address token) external;
}
