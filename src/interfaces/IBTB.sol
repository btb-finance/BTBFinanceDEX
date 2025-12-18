// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/// @title IBTB Interface
/// @notice Interface for the BTB Finance token
interface IBTB {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotMinter();
    error ZeroAddress();
    error MaxSupplyExceeded();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event MinterSet(address indexed oldMinter, address indexed newMinter);

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the minter address
    function minter() external view returns (address);

    /// @notice Returns the maximum supply cap
    function MAX_SUPPLY() external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                            WRITE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Mint new tokens (only callable by minter)
    /// @param to Recipient address
    /// @param amount Amount to mint
    function mint(address to, uint256 amount) external;

    /// @notice Set the minter address (only owner)
    /// @param newMinter New minter address
    function setMinter(address newMinter) external;
}
