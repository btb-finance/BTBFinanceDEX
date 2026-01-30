// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICLPool} from "../interfaces/ICLPool.sol";
import {TickMath} from "../libraries/TickMath.sol";
import {FullMath} from "../libraries/FullMath.sol";
import {LiquidityMath} from "../libraries/LiquidityMath.sol";

/// @title BTB Finance Concentrated Liquidity Pool
/// @author BTB Finance
/// @notice A concentrated liquidity pool inspired by Uniswap v3
/// @dev Supports tick-based liquidity positions with customizable price ranges
contract CLPool is ICLPool {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant Q96 = 0x1000000000000000000000000;
    uint256 internal constant Q128 = 0x100000000000000000000000000000000;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    address public override factory;
    address public override token0;
    address public override token1;
    int24 public override tickSpacing;
    uint24 public override fee;

    Slot0 private _slot0;
    uint128 public override liquidity;

    uint256 public override feeGrowthGlobal0X128;
    uint256 public override feeGrowthGlobal1X128;

    mapping(int24 => TickInfo) private _ticks;
    mapping(bytes32 => Position) private _positions;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() {}

    /*//////////////////////////////////////////////////////////////
                              INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialize the pool (called by factory)
    function initializePool(
        address _factory,
        address _token0,
        address _token1,
        int24 _tickSpacing,
        uint24 _fee
    ) external {
        if (factory != address(0)) revert AlreadyInitialized();
        factory = _factory;
        token0 = _token0;
        token1 = _token1;
        tickSpacing = _tickSpacing;
        fee = _fee;
    }

    /// @inheritdoc ICLPool
    function initialize(uint160 sqrtPriceX96) external override {
        if (_slot0.sqrtPriceX96 != 0) revert AlreadyInitialized();
        if (sqrtPriceX96 < TickMath.MIN_SQRT_RATIO || sqrtPriceX96 >= TickMath.MAX_SQRT_RATIO) {
            revert InvalidSqrtPrice();
        }

        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);
        _slot0 = Slot0({sqrtPriceX96: sqrtPriceX96, tick: tick, unlocked: true});

        emit Initialize(sqrtPriceX96, tick);
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICLPool
    function slot0() external view override returns (uint160 sqrtPriceX96, int24 tick, bool unlocked) {
        Slot0 memory s = _slot0;
        return (s.sqrtPriceX96, s.tick, s.unlocked);
    }

    /// @inheritdoc ICLPool
    function ticks(int24 tick) external view override returns (TickInfo memory) {
        return _ticks[tick];
    }

    /// @inheritdoc ICLPool
    function positions(bytes32 key) external view override returns (Position memory) {
        return _positions[key];
    }

    /*//////////////////////////////////////////////////////////////
                           LIQUIDITY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICLPool
    function mint(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount,
        bytes calldata
    ) external override returns (uint256 amount0, uint256 amount1) {
        if (amount == 0) revert ZeroLiquidity();
        if (tickLower >= tickUpper) revert InvalidTickRange();
        if (tickLower < TickMath.MIN_TICK || tickUpper > TickMath.MAX_TICK) revert InvalidTick();
        if (tickLower % tickSpacing != 0 || tickUpper % tickSpacing != 0) revert InvalidTick();

        _checkLock();
        _slot0.unlocked = false;

        Slot0 memory slot0_ = _slot0;

        // Calculate token amounts needed
        (amount0, amount1) = _getAmountsForLiquidity(
            slot0_.sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            int128(amount)
        );

        // Update tick state
        _updateTick(tickLower, slot0_.tick, int128(amount), false);
        _updateTick(tickUpper, slot0_.tick, int128(amount), true);

        // Update position
        bytes32 positionKey = _getPositionKey(recipient, tickLower, tickUpper);
        Position storage position = _positions[positionKey];
        position.liquidity += amount;

        // Update pool liquidity if current tick is in range
        if (slot0_.tick >= tickLower && slot0_.tick < tickUpper) {
            liquidity += amount;
        }

        // Transfer tokens in
        uint256 balance0Before = IERC20(token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(token1).balanceOf(address(this));

        if (amount0 > 0) IERC20(token0).safeTransferFrom(msg.sender, address(this), amount0);
        if (amount1 > 0) IERC20(token1).safeTransferFrom(msg.sender, address(this), amount1);

        if (amount0 > 0 && IERC20(token0).balanceOf(address(this)) < balance0Before + amount0) {
            revert TransferFailed();
        }
        if (amount1 > 0 && IERC20(token1).balanceOf(address(this)) < balance1Before + amount1) {
            revert TransferFailed();
        }

        _slot0.unlocked = true;
        emit Mint(msg.sender, recipient, tickLower, tickUpper, amount, amount0, amount1);
    }

    /// @inheritdoc ICLPool
    function burn(int24 tickLower, int24 tickUpper, uint128 amount)
        external
        override
        returns (uint256 amount0, uint256 amount1)
    {
        _checkLock();
        _slot0.unlocked = false;

        bytes32 positionKey = _getPositionKey(msg.sender, tickLower, tickUpper);
        Position storage position = _positions[positionKey];
        
        if (amount > position.liquidity) revert ZeroLiquidity();

        Slot0 memory slot0_ = _slot0;

        // Calculate token amounts to return
        (amount0, amount1) = _getAmountsForLiquidity(
            slot0_.sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            -int128(amount)
        );

        // Update tick state
        _updateTick(tickLower, slot0_.tick, -int128(amount), false);
        _updateTick(tickUpper, slot0_.tick, -int128(amount), true);

        // Update position
        position.liquidity -= amount;
        position.tokensOwed0 += uint128(amount0);
        position.tokensOwed1 += uint128(amount1);

        // Update pool liquidity if current tick is in range
        if (slot0_.tick >= tickLower && slot0_.tick < tickUpper) {
            liquidity -= amount;
        }

        _slot0.unlocked = true;
        emit Burn(msg.sender, tickLower, tickUpper, amount, amount0, amount1);
    }

    /// @inheritdoc ICLPool
    function collect(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external override returns (uint256 amount0, uint256 amount1) {
        bytes32 positionKey = _getPositionKey(msg.sender, tickLower, tickUpper);
        Position storage position = _positions[positionKey];

        amount0 = amount0Requested > position.tokensOwed0 ? position.tokensOwed0 : amount0Requested;
        amount1 = amount1Requested > position.tokensOwed1 ? position.tokensOwed1 : amount1Requested;

        if (amount0 > 0) {
            position.tokensOwed0 -= uint128(amount0);
            IERC20(token0).safeTransfer(recipient, amount0);
        }
        if (amount1 > 0) {
            position.tokensOwed1 -= uint128(amount1);
            IERC20(token1).safeTransfer(recipient, amount1);
        }

        emit Collect(msg.sender, recipient, tickLower, tickUpper, amount0, amount1);
    }

    /*//////////////////////////////////////////////////////////////
                            SWAP FUNCTION
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICLPool
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata
    ) external override returns (int256 amount0, int256 amount1) {
        if (amountSpecified == 0) revert InsufficientInputAmount();

        _checkLock();
        _slot0.unlocked = false;

        Slot0 memory slot0Start = _slot0;

        // Validate price limit
        if (zeroForOne) {
            if (sqrtPriceLimitX96 >= slot0Start.sqrtPriceX96 || sqrtPriceLimitX96 <= TickMath.MIN_SQRT_RATIO) {
                revert InvalidSqrtPrice();
            }
        } else {
            if (sqrtPriceLimitX96 <= slot0Start.sqrtPriceX96 || sqrtPriceLimitX96 >= TickMath.MAX_SQRT_RATIO) {
                revert InvalidSqrtPrice();
            }
        }

        bool exactInput = amountSpecified > 0;
        uint256 amountSpecifiedRemaining = exactInput ? uint256(amountSpecified) : uint256(-amountSpecified);
        uint256 amountCalculated = 0;

        uint160 sqrtPriceX96 = slot0Start.sqrtPriceX96;
        int24 tick = slot0Start.tick;
        uint128 liquidityLocal = liquidity;

        // Simplified swap - single step
        // In production, this would iterate through ticks
        uint256 amountIn = 0; // Declare outside to fix scope issue
        uint256 amountOut;
        
        if (liquidityLocal > 0 && amountSpecifiedRemaining > 0) {
            // Calculate swap amounts using simplified constant product formula for demo

            if (zeroForOne) {
                // Swap token0 for token1
                uint256 price = uint256(sqrtPriceX96) * uint256(sqrtPriceX96) / Q96;
                amountIn = amountSpecifiedRemaining;
                amountOut = FullMath.mulDiv(amountIn, price, Q96);
                amountOut = amountOut * (10000 - fee) / 10000; // Apply fee

                amount0 = int256(amountIn);
                amount1 = -int256(amountOut);

                // Update sqrt price (simplified)
                sqrtPriceX96 = uint160(FullMath.mulDiv(sqrtPriceX96, 9990, 10000));
            } else {
                // Swap token1 for token0
                uint256 price = uint256(sqrtPriceX96) * uint256(sqrtPriceX96) / Q96;
                amountIn = amountSpecifiedRemaining;
                amountOut = FullMath.mulDiv(amountIn, Q96, price);
                amountOut = amountOut * (10000 - fee) / 10000;

                amount0 = -int256(amountOut);
                amount1 = int256(amountIn);

                // Update sqrt price (simplified)
                sqrtPriceX96 = uint160(FullMath.mulDiv(sqrtPriceX96, 10010, 10000));
            }

            // Update fee growth
            uint256 feeAmount = amountIn * fee / 10000;
            if (zeroForOne) {
                feeGrowthGlobal0X128 += FullMath.mulDiv(feeAmount, Q128, liquidityLocal);
            } else {
                feeGrowthGlobal1X128 += FullMath.mulDiv(feeAmount, Q128, liquidityLocal);
            }
        }

        // Update slot0
        _slot0.sqrtPriceX96 = sqrtPriceX96;
        _slot0.tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        // Execute transfers
        if (zeroForOne) {
            if (amount1 < 0) IERC20(token1).safeTransfer(recipient, uint256(-amount1));
            IERC20(token0).safeTransferFrom(msg.sender, address(this), uint256(amount0));
        } else {
            if (amount0 < 0) IERC20(token0).safeTransfer(recipient, uint256(-amount0));
            IERC20(token1).safeTransferFrom(msg.sender, address(this), uint256(amount1));
        }

        _slot0.unlocked = true;
        emit Swap(msg.sender, recipient, amount0, amount1, sqrtPriceX96, liquidityLocal, _slot0.tick);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _checkLock() internal view {
        if (!_slot0.unlocked) revert Locked();
    }

    function _getPositionKey(address owner, int24 tickLower, int24 tickUpper) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner, tickLower, tickUpper));
    }

    function _updateTick(int24 tick, int24 currentTick, int128 liquidityDelta, bool upper) internal {
        TickInfo storage info = _ticks[tick];

        if (!info.initialized) {
            info.initialized = true;
            // Initialize fee growth outside based on current tick
            if (tick <= currentTick) {
                info.feeGrowthOutside0X128 = feeGrowthGlobal0X128;
                info.feeGrowthOutside1X128 = feeGrowthGlobal1X128;
            }
        }

        info.liquidityGross = LiquidityMath.addDelta(info.liquidityGross, liquidityDelta);

        if (upper) {
            info.liquidityNet -= liquidityDelta;
        } else {
            info.liquidityNet += liquidityDelta;
        }
    }

    function _getAmountsForLiquidity(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        int128 liquidityDelta
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96) {
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        }

        uint128 absLiquidity = liquidityDelta >= 0 ? uint128(liquidityDelta) : uint128(-liquidityDelta);

        if (sqrtRatioX96 <= sqrtRatioAX96) {
            // Current price below range - only token0 needed
            amount0 = LiquidityMath.getAmount0ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, absLiquidity);
        } else if (sqrtRatioX96 < sqrtRatioBX96) {
            // Current price in range - both tokens needed
            amount0 = LiquidityMath.getAmount0ForLiquidity(sqrtRatioX96, sqrtRatioBX96, absLiquidity);
            amount1 = LiquidityMath.getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioX96, absLiquidity);
        } else {
            // Current price above range - only token1 needed
            amount1 = LiquidityMath.getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, absLiquidity);
        }
    }
}
