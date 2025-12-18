// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/// @title IPoolFactory Interface
/// @notice Interface for the BTB Finance pool factory
interface IPoolFactory {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error IdenticalAddresses();
    error ZeroAddress();
    error PoolExists();
    error PoolDoesNotExist();
    error NotPauser();
    error SameState();
    error FeeInvalid();
    error FeeTooHigh();
    error NotFeeManager();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event PoolCreated(
        address indexed token0,
        address indexed token1,
        bool stable,
        address pool,
        uint256 allPoolsLength
    );
    event SetPauser(address indexed pauser);
    event SetPauseState(bool state);
    event SetFeeManager(address indexed feeManager);
    event SetVolatileFee(uint256 fee);
    event SetStableFee(uint256 fee);
    event SetCustomFee(address indexed pool, uint256 fee);

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Pool implementation for cloning
    function implementation() external view returns (address);

    /// @notice All pools array length
    function allPoolsLength() external view returns (uint256);

    /// @notice Get pool for token pair
    function getPool(address tokenA, address tokenB, bool stable) external view returns (address);

    /// @notice Whether an address is a valid pool
    function isPool(address pool) external view returns (bool);

    /// @notice Fee for volatile pools (basis points)
    function volatileFee() external view returns (uint256);

    /// @notice Fee for stable pools (basis points)
    function stableFee() external view returns (uint256);

    /// @notice Custom fee for specific pool
    function customFee(address pool) external view returns (uint256);

    /// @notice Fee for specific pool (custom or default)
    function getFee(address pool, bool stable) external view returns (uint256);

    /// @notice Whether swaps are paused
    function isPaused() external view returns (bool);

    /// @notice Address allowed to pause swaps
    function pauser() external view returns (address);

    /// @notice Address allowed to set fees
    function feeManager() external view returns (address);

    /// @notice Voter contract address
    function voter() external view returns (address);

    /*//////////////////////////////////////////////////////////////
                            WRITE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a new pool
    function createPool(address tokenA, address tokenB, bool stable) external returns (address pool);

    /// @notice Set pause state
    function setPauseState(bool state) external;

    /// @notice Set pauser address
    function setPauser(address pauser) external;

    /// @notice Set fee manager
    function setFeeManager(address feeManager) external;

    /// @notice Set default volatile fee
    function setVolatileFee(uint256 fee) external;

    /// @notice Set default stable fee
    function setStableFee(uint256 fee) external;

    /// @notice Set custom fee for a pool
    function setCustomFee(address pool, uint256 fee) external;
}
