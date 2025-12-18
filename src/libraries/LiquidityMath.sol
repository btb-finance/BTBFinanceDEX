// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {FullMath} from "./FullMath.sol";

/// @title Liquidity Math Library
/// @notice Functions for computing liquidity amounts from prices and vice versa
library LiquidityMath {
    /// @notice Computes the amount of liquidity for a given amount of token0 and price range
    function getLiquidityForAmount0(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint256 amount0)
        internal
        pure
        returns (uint128 liquidity)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        uint256 intermediate = FullMath.mulDiv(sqrtRatioAX96, sqrtRatioBX96, 1 << 96);
        return uint128(FullMath.mulDiv(amount0, intermediate, sqrtRatioBX96 - sqrtRatioAX96));
    }

    /// @notice Computes the amount of liquidity for a given amount of token1 and price range
    function getLiquidityForAmount1(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint256 amount1)
        internal
        pure
        returns (uint128 liquidity)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        return uint128(FullMath.mulDiv(amount1, 1 << 96, sqrtRatioBX96 - sqrtRatioAX96));
    }

    /// @notice Computes the amount of token0 for a given amount of liquidity and price range
    function getAmount0ForLiquidity(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        return FullMath.mulDiv(
            uint256(liquidity) << 96, sqrtRatioBX96 - sqrtRatioAX96, sqrtRatioBX96
        ) / sqrtRatioAX96;
    }

    /// @notice Computes the amount of token1 for a given amount of liquidity and price range
    function getAmount1ForLiquidity(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity)
        internal
        pure
        returns (uint256 amount1)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        return FullMath.mulDiv(liquidity, sqrtRatioBX96 - sqrtRatioAX96, 1 << 96);
    }

    /// @notice Computes liquidity from amounts given current and range prices
    function getLiquidityForAmounts(
        uint160 sqrtPriceX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        if (sqrtPriceX96 <= sqrtRatioAX96) {
            // Current price below range - only token0
            liquidity = getLiquidityForAmount0(sqrtRatioAX96, sqrtRatioBX96, amount0);
        } else if (sqrtPriceX96 < sqrtRatioBX96) {
            // Current price in range - both tokens
            uint128 liquidity0 = getLiquidityForAmount0(sqrtPriceX96, sqrtRatioBX96, amount0);
            uint128 liquidity1 = getLiquidityForAmount1(sqrtRatioAX96, sqrtPriceX96, amount1);
            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        } else {
            // Current price above range - only token1
            liquidity = getLiquidityForAmount1(sqrtRatioAX96, sqrtRatioBX96, amount1);
        }
    }

    /// @notice Safe addition for liquidity
    function addDelta(uint128 x, int128 y) internal pure returns (uint128 z) {
        if (y < 0) {
            require((z = x - uint128(-y)) < x, "LS");
        } else {
            require((z = x + uint128(y)) >= x, "LA");
        }
    }
}
