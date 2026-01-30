// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {PoolManager} from "./PoolManager.sol";

/// @title MEVProtectedPoolManager - Singleton with MEV capture
/// @notice Batch swaps and redistribute MEV to LPs
contract MEVProtectedPoolManager is PoolManager {
    
    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct SwapOrder {
        address sender;
        bytes32 poolId;
        SwapParams params;
        uint256 timestamp;
        bool executed;
    }

    struct Batch {
        SwapOrder[] orders;
        uint256 totalVolume0;
        uint256 totalVolume1;
        bool settled;
    }

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Block number => Batch of swaps
    mapping(uint256 => Batch) public batches;

    /// @notice Pool ID => MEV rewards accumulated
    mapping(bytes32 => uint256) public mevRewards;

    /// @notice Block number => Pool ID => MEV captured
    mapping(uint256 => mapping(bytes32 => uint256)) public blockMEV;

    /// @notice Authorized settlers (keepers/MEV searchers)
    mapping(address => bool) public authorizedSettlers;

    /// @notice Minimum MEV bid to participate
    uint256 public minMEVBid = 0.001 ether;

    /// @notice MEV redistribution percentage to LPs (90%)
    uint256 public constant MEV_LP_SHARE = 90;
    uint256 public constant MEV_PROTOCOL_SHARE = 10;

    /// @notice Keeper reward per batch settlement
    uint256 public keeperReward = 0.001 ether;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event SwapQueued(bytes32 indexed orderId, address indexed sender, bytes32 indexed poolId, uint256 blockNumber);
    event BatchSettled(uint256 indexed blockNumber, bytes32 indexed poolId, uint256 orders, uint256 mevCaptured);
    event MEVDistributed(bytes32 indexed poolId, uint256 lpAmount, uint256 protocolAmount);
    event SettlerAuthorized(address indexed settler, bool authorized);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error BatchAlreadySettled();
    error NotAuthorizedSettler();
    error InvalidBlock();
    error InsufficientMEVBid();

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _protocolFeeRecipient) PoolManager(_protocolFeeRecipient) {}

    /*//////////////////////////////////////////////////////////////
                            QUEUE SWAPS
    //////////////////////////////////////////////////////////////*/

    /// @notice Queue a swap for batch settlement
    /// @dev Swaps aren't executed immediately - batched for MEV protection
    function queueSwap(bytes32 poolId, SwapParams calldata params) external payable nonReentrant returns (bytes32 orderId) {
        if (msg.value < minMEVBid) revert InsufficientMEVBid();
        
        PoolState storage pool = pools[poolId];
        if (!pool.initialized) revert PoolNotInitialized();

        uint256 currentBlock = block.number;
        Batch storage batch = batches[currentBlock];

        // Create order
        SwapOrder memory order = SwapOrder({
            sender: msg.sender,
            poolId: poolId,
            params: params,
            timestamp: block.timestamp,
            executed: false
        });

        batch.orders.push(order);

        // Estimate volumes for MEV tracking
        if (params.zeroForOne) {
            if (params.amountSpecified > 0) {
                batch.totalVolume0 += uint256(params.amountSpecified);
            } else {
                // Exact output
                batch.totalVolume1 += uint256(-params.amountSpecified);
            }
        } else {
            if (params.amountSpecified > 0) {
                batch.totalVolume1 += uint256(params.amountSpecified);
            } else {
                batch.totalVolume0 += uint256(-params.amountSpecified);
            }
        }

        orderId = keccak256(abi.encodePacked(currentBlock, batch.orders.length - 1, msg.sender));

        emit SwapQueued(orderId, msg.sender, poolId, currentBlock);

        // Auto-settle if block is ending (would be called by keeper in production)
        // For now, user can trigger settlement
    }

    /*//////////////////////////////////////////////////////////////
                            BATCH SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Settle all swaps in a block batch
    /// @dev Called by authorized settler at end of block
    function settleBatch(uint256 blockNumber, bytes32 poolId) external nonReentrant {
        if (!authorizedSettlers[msg.sender]) revert NotAuthorizedSettler();
        if (blockNumber >= block.number) revert InvalidBlock();

        Batch storage batch = batches[blockNumber];
        if (batch.settled) revert BatchAlreadySettled();

        // Count orders for this pool
        uint256 poolOrderCount = 0;
        for (uint256 i = 0; i < batch.orders.length; i++) {
            if (batch.orders[i].poolId == poolId && !batch.orders[i].executed) {
                poolOrderCount++;
            }
        }

        if (poolOrderCount == 0) return;

        // Sort orders by price (buy orders ascending, sell orders descending)
        // For simplicity, we'll do pro-rata settlement
        
        // Calculate uniform clearing price
        // In production: run combinatorial auction
        uint256 mevCaptured = _calculateMEV(batch, poolId);

        // Execute swaps at uniform price
        uint256 totalVolume = 0;
        for (uint256 i = 0; i < batch.orders.length; i++) {
            if (batch.orders[i].poolId == poolId && !batch.orders[i].executed) {
                _executeQueuedSwap(batch.orders[i]);
                batch.orders[i].executed = true;
                totalVolume++;
            }
        }

        batch.settled = true;
        blockMEV[blockNumber][poolId] = mevCaptured;

        // Distribute MEV
        uint256 lpShare = (mevCaptured * MEV_LP_SHARE) / 100;
        uint256 protocolShare = mevCaptured - lpShare;

        mevRewards[poolId] += lpShare;
        
        // Pay keeper
        payable(msg.sender).transfer(keeperReward);

        emit BatchSettled(blockNumber, poolId, totalVolume, mevCaptured);
        emit MEVDistributed(poolId, lpShare, protocolShare);
    }

    /*//////////////////////////////////////////////////////////////
                            MEV CAPTURE
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculate MEV that can be extracted from batch
    function _calculateMEV(Batch storage batch, bytes32 poolId) internal view returns (uint256) {
        // Calculate price impact and arbitrage opportunity
        // Simplified: return a percentage of volume as MEV
        
        uint256 volume = batch.totalVolume0 + batch.totalVolume1;
        
        // Assume 0.5% arbitrage opportunity on average
        return (volume * 5) / 1000;
    }

    /// @notice Execute a queued swap
    function _executeQueuedSwap(SwapOrder storage order) internal {
        // Call parent swap function
        // For now simplified
    }

    /*//////////////////////////////////////////////////////////////
                            REWARDS DISTRIBUTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Claim MEV rewards as LP
    function claimMEVRewards(bytes32 poolId) external nonReentrant {
        uint256 rewards = mevRewards[poolId];
        if (rewards == 0) return;

        // Check if sender has liquidity in pool
        // Simplified - in production check LP position
        
        mevRewards[poolId] = 0;
        
        // Transfer rewards
        (address token0, address token1) = poolIdToTokens(poolId);
        uint256 half = rewards / 2;
        
        // Transfer as both tokens (simplified)
        payable(msg.sender).transfer(rewards);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN
    //////////////////////////////////////////////////////////////*/

    function authorizeSettler(address settler, bool authorized) external onlyOwner {
        authorizedSettlers[settler] = authorized;
        emit SettlerAuthorized(settler, authorized);
    }

    function setMinMEVBid(uint256 newBid) external onlyOwner {
        minMEVBid = newBid;
    }

    function setKeeperReward(uint256 newReward) external onlyOwner {
        keeperReward = newReward;
    }

    /*//////////////////////////////////////////////////////////////
                            FALLBACK
    //////////////////////////////////////////////////////////////*/

    receive() external payable {}
}
