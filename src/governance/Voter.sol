// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVoter} from "../interfaces/IVoter.sol";
import {IVotingEscrow} from "../interfaces/IVotingEscrow.sol";

/// @title BTB Finance Voter
/// @author BTB Finance
/// @notice Personal emissions voting - each veNFT distributes its own BTB budget instantly
/// @dev No epochs, no weekly system, no gauge registration. Vote = instant reward to any pool.
contract Voter is IVoter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant MAX_POOLS = 30;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IVoter
    address public override ve;

    /// @inheritdoc IVoter
    address public override governor;

    /// @inheritdoc IVoter
    address public override rewardToken;

    /// @inheritdoc IVoter
    uint256 public override totalWeight;

    /// @dev Pool => Total votes (for stats only)
    mapping(address => uint256) internal _weights;

    /// @dev Token ID => Pool => Votes
    mapping(uint256 => mapping(address => uint256)) internal _votes;

    /// @dev Token ID => Used weight
    mapping(uint256 => uint256) internal _usedWeights;

    /// @dev Token ID => Pools voted for
    mapping(uint256 => address[]) internal _poolVote;

    /// @dev Pool => Total BTB received (for stats)
    mapping(address => uint256) public totalRewards;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _ve, address _rewardToken) {
        ve = _ve;
        rewardToken = _rewardToken;
        governor = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IVoter
    /// @dev Every pool is its own gauge - no registration needed
    function gauges(address pool) external pure override returns (address) {
        return pool;
    }

    /// @inheritdoc IVoter
    function poolForGauge(address gauge) external pure override returns (address) {
        return gauge;
    }

    /// @inheritdoc IVoter
    /// @dev All pools are gauges by definition
    function isGauge(address) external pure override returns (bool) {
        return true; // Any address can receive votes
    }

    /// @inheritdoc IVoter
    /// @dev All pools are alive by default (no kill mechanism needed for simple system)
    function isAlive(address) external pure override returns (bool) {
        return true;
    }

    /// @inheritdoc IVoter
    function weights(address pool) external view override returns (uint256) {
        return _weights[pool];
    }

    /// @inheritdoc IVoter
    function votes(uint256 tokenId, address pool) external view override returns (uint256) {
        return _votes[tokenId][pool];
    }

    /// @inheritdoc IVoter
    function usedWeights(uint256 tokenId) external view override returns (uint256) {
        return _usedWeights[tokenId];
    }

    /// @inheritdoc IVoter
    function isWhitelistedToken(address) external pure override returns (bool) {
        return true; // No whitelisting - fully permissionless
    }

    /// @inheritdoc IVoter
    function poolsLength() external pure override returns (uint256) {
        return 0; // Not tracking - any pool is valid
    }

    /// @inheritdoc IVoter
    function allPools(uint256) external pure override returns (address) {
        return address(0);
    }

    /*//////////////////////////////////////////////////////////////
                               VOTING
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IVoter
    /// @notice Vote and INSTANTLY distribute your veNFT's BTB emissions to ANY pool
    function vote(uint256 tokenId, address[] calldata pools, uint256[] calldata weights_) external override nonReentrant {
        if (!IVotingEscrow(ve).isApprovedOrOwner(msg.sender, tokenId)) revert NotApprovedOrOwner();
        if (pools.length != weights_.length) revert InvalidWeights();
        if (pools.length > MAX_POOLS) revert TooManyPools();
        if (pools.length == 0) revert InvalidWeights();

        // Get voting power and available emission budget from veNFT
        uint256 votingPower = IVotingEscrow(ve).balanceOfNFT(tokenId);
        uint256 emissionBudget = IVotingEscrow(ve).getEmissionBudget(tokenId);
        
        if (votingPower == 0) revert NotWhitelisted();
        if (emissionBudget == 0) revert ZeroAmount();

        // Reset previous votes (allows changing vote distribution)
        _reset(tokenId);

        // Calculate total weight
        uint256 totalVoteWeight = 0;
        for (uint256 i = 0; i < weights_.length; i++) {
            totalVoteWeight += weights_[i];
        }
        if (totalVoteWeight == 0) revert InvalidWeights();

        // Distribute emissions proportionally to ANY pools
        uint256 usedEmissions = 0;
        
        for (uint256 i = 0; i < pools.length; i++) {
            address pool = pools[i];
            if (pool == address(0)) continue;

            // Calculate this pool's share of emissions
            uint256 poolEmission = (emissionBudget * weights_[i]) / totalVoteWeight;
            
            if (poolEmission > 0) {
                // INSTANTLY transfer BTB from veNFT to pool
                // Pool receives BTB and distributes to LP holders
                IVotingEscrow(ve).distributeEmission(tokenId, pool, poolEmission);
                
                // Track votes for stats/display
                _votes[tokenId][pool] = (votingPower * weights_[i]) / totalVoteWeight;
                _weights[pool] += _votes[tokenId][pool];
                _poolVote[tokenId].push(pool);
                
                // Track total rewards sent to pool
                totalRewards[pool] += poolEmission;
                usedEmissions += poolEmission;

                emit Voted(msg.sender, tokenId, pool, _votes[tokenId][pool]);
            }
        }

        _usedWeights[tokenId] = votingPower;
        totalWeight += votingPower;

        // Mark this veNFT as having voted (prevents double voting with same budget)
        IVotingEscrow(ve).voting(tokenId, true);
        
        emit NotifyReward(msg.sender, rewardToken, usedEmissions);
    }

    /// @inheritdoc IVoter
    function reset(uint256 tokenId) external override nonReentrant {
        if (!IVotingEscrow(ve).isApprovedOrOwner(msg.sender, tokenId)) revert NotApprovedOrOwner();
        _reset(tokenId);
    }

    function _reset(uint256 tokenId) internal {
        address[] storage pools = _poolVote[tokenId];
        uint256 totalVotesRemoved = 0;

        for (uint256 i = 0; i < pools.length; i++) {
            address pool = pools[i];
            uint256 votes_ = _votes[tokenId][pool];

            if (votes_ > 0) {
                _weights[pool] -= votes_;
                totalWeight -= votes_;
                _votes[tokenId][pool] = 0;
                totalVotesRemoved += votes_;

                emit Abstained(msg.sender, tokenId, votes_);
            }
        }

        delete _poolVote[tokenId];
        _usedWeights[tokenId] = 0;

        // Unmark voting status (allows re-voting with remaining budget)
        IVotingEscrow(ve).voting(tokenId, false);
    }

    /// @inheritdoc IVoter
    /// @notice Re-apply same votes (useful if you want to re-distribute remaining budget)
    function poke(uint256 tokenId) external override nonReentrant {
        if (!IVotingEscrow(ve).isApprovedOrOwner(msg.sender, tokenId)) revert NotApprovedOrOwner();

        address[] memory pools = _poolVote[tokenId];
        uint256[] memory weights_ = new uint256[](pools.length);

        for (uint256 i = 0; i < pools.length; i++) {
            weights_[i] = _votes[tokenId][pools[i]];
        }

        _reset(tokenId);
        vote(tokenId, pools, weights_);
    }

    /*//////////////////////////////////////////////////////////////
                            REWARD DISTRIBUTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Get total rewards sent to a pool (for stats)
    function getPoolRewards(address pool) external view returns (uint256) {
        return totalRewards[pool];
    }

    /*//////////////////////////////////////////////////////////////
                               ADMIN (Minimal)
    //////////////////////////////////////////////////////////////*/

    /// @notice Set governor for emergency functions (if needed in future)
    function setGovernor(address _governor) external {
        if (msg.sender != governor) revert NotGovernor();
        if (_governor == address(0)) revert ZeroAddress();
        governor = _governor;
    }

    /// @inheritdoc IVoter
    /// @dev Deprecated - no gauge creation needed, all pools are gauges
    function createGauge(address) external pure override returns (address) {
        return address(0); // No-op: every pool is already a gauge
    }

    /// @inheritdoc IVoter
    /// @dev Deprecated - no kill mechanism in simple system
    function killGauge(address) external pure override {
        // No-op: all pools are always alive
    }

    /// @inheritdoc IVoter
    /// @dev Deprecated - no revive needed
    function reviveGauge(address) external pure override {
        // No-op
    }
}
