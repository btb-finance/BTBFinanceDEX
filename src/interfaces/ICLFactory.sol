// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/// @title ICLFactory Interface
/// @notice Interface for the BTB Finance CL pool factory
interface ICLFactory {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error IdenticalAddresses();
    error ZeroAddress();
    error PoolExists();
    error InvalidTickSpacing();
    error NotOwner();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event PoolCreated(
        address indexed token0,
        address indexed token1,
        int24 indexed tickSpacing,
        address pool,
        uint256 allPoolsLength
    );
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    event TickSpacingEnabled(int24 indexed tickSpacing, uint24 indexed fee);

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function owner() external view returns (address);
    function implementation() external view returns (address);
    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address);
    function isPool(address pool) external view returns (bool);
    function allPoolsLength() external view returns (uint256);
    function tickSpacingToFee(int24 tickSpacing) external view returns (uint24);

    /*//////////////////////////////////////////////////////////////
                            WRITE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function createPool(address tokenA, address tokenB, int24 tickSpacing, uint160 sqrtPriceX96)
        external
        returns (address pool);

    function setOwner(address newOwner) external;
    function enableTickSpacing(int24 tickSpacing, uint24 fee) external;
}
