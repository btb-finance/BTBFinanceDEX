// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVoter} from "../interfaces/IVoter.sol";
import {IVotingEscrow} from "../interfaces/IVotingEscrow.sol";
import {IGauge} from "../interfaces/IGauge.sol";
import {IPool} from "../interfaces/IPool.sol";

/// @title BTB Finance Voter
/// @author BTB Finance
/// @notice Personal emissions voting - each veNFT distributes its own BTB budget instantly
/// @dev No epochs, no weekly system. Vote = instant reward distribution.
contract Voter is IVoter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant WEEK = 7 days;
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

    /// @dev Pool => Is valid gauge (pool is its own gauge)
    mapping(address => bool) internal _isGauge;

    /// @dev Pool => Is alive
    mapping(address => bool) internal _isAlive;

    /// @dev Pool => Total votes (for display)
    mapping(address => uint256) internal _weights;

    /// @dev Token ID => Pool => Votes
    mapping(uint256 => mapping(address => uint256)) internal _votes;

    /// @dev Token ID => Used weight
    mapping(uint256 => uint256) internal _usedWeights;

    /// @dev Token ID => Pools voted for
    mapping(uint256 => address[]) internal _poolVote;

    /// @dev All pools with gauges
    address[] internal _allPools;

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
    function gauges(address pool) external view override returns (address) {
        return _isGauge[pool] ? pool : address(0);
    }

    /// @inheritdoc IVoter
    function poolForGauge(address gauge) external view override returns (address) {
        return _isGauge[gauge] ? gauge : address(0);
    }

    /// @inheritdoc IVoter
    function isGauge(address gauge) external view override returns (bool) {
        return _isGauge[gauge];
    }

    /// @inheritdoc IVoter
    function isAlive(address gauge) external view override returns (bool) {
        return _isAlive[gauge];
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
    function isWhitelistedToken(address token) external pure override returns (bool) {
        return true; // No whitelisting - permissionless
    }

    /// @inheritdoc IVoter
    function poolsLength() external view override returns (uint256) {
        return _allPools.length;
    }

    /// @inheritdoc IVoter
    function allPools(uint256 index_) external view override returns (address) {
        return _allPools[index_];
    }

    /*//////////////////////////////////////////////////////////////
                            GAUGE MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IVoter
    /// @notice Anyone can create a gauge for any pool - permissionless!
    function createGauge(address pool) external override returns (address gauge) {
        // Check gauge doesn't already exist
        if (_isGauge[pool]) revert NotGauge();

        // Verify it's a valid pool with token0/token1
        (bool success0, ) = pool.staticcall(abi.encodeWithSignature("token0()"));
        (bool success1, ) = pool.staticcall(abi.encodeWithSignature("token1()"));
        if (!success0 || !success1) revert NotWhitelisted();

        // Pool is its own gauge
        _isGauge[pool] = true;
        _isAlive[pool] = true;
        _allPools.push(pool);

        emit GaugeCreated(pool, pool, msg.sender);
        return pool;
    }

    /// @inheritdoc IVoter
    function killGauge(address gauge) external override {
        if (msg.sender != governor) revert NotGovernor();
        if (!_isAlive[gauge]) revert PoolNotAlive();
        _isAlive[gauge] = false;
        emit GaugeKilled(gauge);
    }

    /// @inheritdoc IVoter
    function reviveGauge(address gauge) external override {
        if (msg.sender != governor) revert NotGovernor();
        if (_isAlive[gauge]) revert PoolNotAlive();
        _isAlive[gauge] = true;
        emit GaugeRevived(gauge);
    }

    /*//////////////////////////////////////////////////////////////
                               VOTING
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IVoter
    /// @notice Vote and INSTANTLY distribute your veNFT's BTB emissions to pools
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

        // Reset previous votes and return any unspent emissions
        _reset(tokenId);

        // Calculate total weight
        uint256 totalVoteWeight = 0;
        for (uint256 i = 0; i < weights_.length; i++) {
            totalVoteWeight += weights_[i];
        }
        if (totalVoteWeight == 0) revert InvalidWeights();

        // Distribute emissions proportionally
        uint256 usedEmissions = 0;
        
        for (uint256 i = 0; i < pools.length; i++) {
            address pool = pools[i];
            
            // Check pool has a gauge and is alive
            if (!_isGauge[pool]) {
                // Auto-create gauge if needed
                createGauge(pool);
            }
            if (!_isAlive[pool]) continue;

            // Calculate this pool's share of emissions
            uint256 poolEmission = (emissionBudget * weights_[i]) / totalVoteWeight;
            
            if (poolEmission > 0) {
                // INSTANTLY transfer BTB from veNFT to pool
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
                               ADMIN
    //////////////////////////////////////////////////////////////*/

    function setGovernor(address _governor) external {
        if (msg.sender != governor) revert NotGovernor();
        if (_governor == address(0)) revert ZeroAddress();
        governor = _governor;
    }
}
