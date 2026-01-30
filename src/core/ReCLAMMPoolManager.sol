// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {PoolManager} from "./PoolManager.sol";
import {TickMath} from "../libraries/TickMath.sol";
import {LiquidityMath} from "../libraries/LiquidityMath.sol";

/// @title ReCLAMMPoolManager - Auto-rebalancing concentrated liquidity
/// @notice CL pools that automatically re-center when price moves
contract ReCLAMMPoolManager is PoolManager {
    
    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct RebalanceParams {
        int24 baseTick;        // Center tick
        int24 width;           // Half-width of range (e.g., 100 = +/- 100 ticks)
        uint256 threshold;     // Rebalance when price moves this % from center
        uint256 lastRebalance; // Timestamp of last rebalance
    }

    struct RebalanceState {
        int24 currentCenterTick;
        int24 targetLowerTick;
        int24 targetUpperTick;
        bool needsRebalance;
        uint256 timeUntilRebalance;
    }

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Pool ID => Rebalance parameters
    mapping(bytes32 => RebalanceParams) public rebalanceParams;

    /// @notice Pool ID => Is auto-rebalancing enabled
    mapping(bytes32 => bool) public autoRebalanceEnabled;

    /// @notice Authorized rebalancers (keepers)
    mapping(address => bool) public authorizedRebalancers;

    /// @notice Keeper reward for rebalancing
    uint256 public rebalanceReward = 0.0005 ether;

    /// @notice Minimum time between rebalances (prevents spam)
    uint256 public constant MIN_REBALANCE_INTERVAL = 1 hours;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event AutoRebalanceEnabled(bytes32 indexed poolId, int24 baseTick, int24 width, uint256 threshold);
    event RebalanceExecuted(bytes32 indexed poolId, int24 oldCenter, int24 newCenter, uint256 timestamp);
    event RebalancerAuthorized(address indexed rebalancer, bool authorized);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error RebalanceNotNeeded();
    error RebalanceTooFrequent();
    error NotAuthorizedRebalancer();
    error InvalidRebalanceParams();

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _protocolFeeRecipient) PoolManager(_protocolFeeRecipient) {}

    /*//////////////////////////////////////////////////////////////
                            AUTO-REBALANCING SETUP
    //////////////////////////////////////////////////////////////*/

    /// @notice Enable auto-rebalancing for a pool
    /// @param poolId The pool to enable
    /// @param baseTick Initial center tick
    /// @param width Half-width of range in ticks
    /// @param threshold Percentage threshold for rebalance (in basis points, e.g., 500 = 5%)
    function enableAutoRebalance(
        bytes32 poolId,
        int24 baseTick,
        int24 width,
        uint256 threshold
    ) external onlyOwner {
        if (width <= 0 || width > 10000) revert InvalidRebalanceParams();
        if (threshold == 0 || threshold > 5000) revert InvalidRebalanceParams(); // Max 50%

        rebalanceParams[poolId] = RebalanceParams({
            baseTick: baseTick,
            width: width,
            threshold: threshold,
            lastRebalance: block.timestamp
        });

        autoRebalanceEnabled[poolId] = true;

        emit AutoRebalanceEnabled(poolId, baseTick, width, threshold);
    }

    /// @notice Check if pool needs rebalancing
    function checkRebalance(bytes32 poolId) external view returns (RebalanceState memory state) {
        if (!autoRebalanceEnabled[poolId]) {
            return state;
        }

        PoolState storage pool = pools[poolId];
        RebalanceParams storage params = rebalanceParams[poolId];

        state.currentCenterTick = pool.tick;
        state.targetLowerTick = params.baseTick - params.width;
        state.targetUpperTick = params.baseTick + params.width;

        // Calculate how far price moved from center
        int24 tickDiff = pool.tick - params.baseTick;
        uint256 absTickDiff = tickDiff >= 0 ? uint24(tickDiff) : uint24(-tickDiff);
        
        // Convert to percentage (approximate using tick spacing)
        uint256 priceMovementBps = (absTickDiff * 10000) / uint24(params.width);

        state.needsRebalance = priceMovementBps > params.threshold;
        
        if (block.timestamp < params.lastRebalance + MIN_REBALANCE_INTERVAL) {
            state.needsRebalance = false;
            state.timeUntilRebalance = params.lastRebalance + MIN_REBALANCE_INTERVAL - block.timestamp;
        }

        return state;
    }

    /*//////////////////////////////////////////////////////////////
                            EXECUTE REBALANCE
    //////////////////////////////////////////////////////////////*/

    /// @notice Execute rebalancing for a pool
    /// @dev Called by keeper when price moves beyond threshold
    function executeRebalance(bytes32 poolId) external nonReentrant {
        if (!authorizedRebalancers[msg.sender]) revert NotAuthorizedRebalancer();
        if (!autoRebalanceEnabled[poolId]) revert RebalanceNotNeeded();

        RebalanceParams storage params = rebalanceParams[poolId];
        
        if (block.timestamp < params.lastRebalance + MIN_REBALANCE_INTERVAL) {
            revert RebalanceTooFrequent();
        }

        RebalanceState memory state = this.checkRebalance(poolId);
        if (!state.needsRebalance) revert RebalanceNotNeeded();

        PoolState storage pool = pools[poolId];
        int24 oldCenter = params.baseTick;
        int24 newCenter = pool.tick;

        // Update base tick to new center
        params.baseTick = newCenter;
        params.lastRebalance = block.timestamp;

        // In production:
        // 1. Calculate new optimal range
        // 2. Remove liquidity from old range
        // 3. Add liquidity to new range
        // 4. Handle any impermanent loss / arbitrage

        // Pay keeper reward
        payable(msg.sender).transfer(rebalanceReward);

        emit RebalanceExecuted(poolId, oldCenter, newCenter, block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                            BATCH REBALANCING
    //////////////////////////////////////////////////////////////*/

    /// @notice Rebalance multiple pools in one transaction
    function batchRebalance(bytes32[] calldata poolIds) external nonReentrant {
        if (!authorizedRebalancers[msg.sender]) revert NotAuthorizedRebalancer();

        uint256 successCount = 0;
        for (uint256 i = 0; i < poolIds.length; i++) {
            try this.executeRebalance(poolIds[i]) {
                successCount++;
            } catch {
                // Continue to next pool
            }
        }

        // Pay proportional reward
        uint256 totalReward = rebalanceReward * successCount;
        payable(msg.sender).transfer(totalReward);
    }

    /*//////////////////////////////////////////////////////////////
                            LIQUIDITY HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get optimal tick range for current price
    function getOptimalRange(bytes32 poolId) external view returns (int24 lowerTick, int24 upperTick) {
        if (!autoRebalanceEnabled[poolId]) {
            return (0, 0);
        }

        RebalanceParams storage params = rebalanceParams[poolId];
        PoolState storage pool = pools[poolId];

        // Center range around current price
        lowerTick = pool.tick - params.width;
        upperTick = pool.tick + params.width;

        // Ensure ticks are valid
        if (lowerTick < MIN_TICK) lowerTick = MIN_TICK;
        if (upperTick > MAX_TICK) upperTick = MAX_TICK;
    }

    /// @notice Calculate expected returns with auto-rebalancing
    function estimateAutoRebalanceAPY(bytes32 poolId) external view returns (uint256 apy) {
        if (!autoRebalanceEnabled[poolId]) return 0;

        // Simplified calculation
        // In production: simulate historical performance
        
        // Base fee APY (assume 0.3% daily volume on TVL)
        uint256 baseAPY = 1095; // 3% daily * 365 = 1095%
        
        // Boost from staying in range (vs manual CL that goes out of range)
        uint256 alwaysInRangeBoost = 200; // 2x multiplier
        
        // Subtract rebalance costs
        uint256 rebalanceCostBps = 50; // 0.5% per rebalance
        uint256 estimatedRebalancesPerYear = 52; // Weekly
        uint256 totalRebalanceCost = rebalanceCostBps * estimatedRebalancesPerYear;
        
        apy = (baseAPY * alwaysInRangeBoost) - totalRebalanceCost;
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN
    //////////////////////////////////////////////////////////////*/

    function authorizeRebalancer(address rebalancer, bool authorized) external onlyOwner {
        authorizedRebalancers[rebalancer] = authorized;
        emit RebalancerAuthorized(rebalancer, authorized);
    }

    function setRebalanceReward(uint256 newReward) external onlyOwner {
        rebalanceReward = newReward;
    }

    function disableAutoRebalance(bytes32 poolId) external onlyOwner {
        autoRebalanceEnabled[poolId] = false;
    }

    /*//////////////////////////////////////////////////////////////
                            FALLBACK
    //////////////////////////////////////////////////////////////*/

    receive() external payable {}
}
