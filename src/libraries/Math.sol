// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/// @title Math Library
/// @notice Common math functions for the DEX
library Math {
    /// @notice Calculate the minimum of two values
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @notice Calculate the maximum of two values
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    /// @notice Calculate the square root using Babylonian method
    /// @param y The value to get square root of
    /// @return z The square root
    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
