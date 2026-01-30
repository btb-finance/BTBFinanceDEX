// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title IFlashLoanReceiver Interface
/// @notice Interface for contracts that receive flash loans
interface IFlashLoanReceiver {
    /// @notice Callback function for flash loans
    /// @param sender The address that initiated the flash loan
    /// @param token0Amount The amount of token0 borrowed (0 if borrowing token1)
    /// @param token1Amount The amount of token1 borrowed (0 if borrowing token0)
    /// @param fee0 The fee for borrowing token0
    /// @param fee1 The fee for borrowing token1
    /// @param data Arbitrary data passed from the flash loan initiator
    function onFlashLoan(
        address sender,
        uint256 token0Amount,
        uint256 token1Amount,
        uint256 fee0,
        uint256 fee1,
        bytes calldata data
    ) external;
}
