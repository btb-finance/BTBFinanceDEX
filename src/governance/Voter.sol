// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVoter} from "../interfaces/IVoter.sol";
import {IVotingEscrow} from "../interfaces/IVotingEscrow.sol";
import {IGauge} from "../interfaces/IGauge.sol";
import {Gauge} from "../gauges/Gauge.sol";

/// @title BTB Finance Voter
/// @author BTB Finance
/// @notice Voting and gauge management for BTB emissions
/// @dev Users vote with veBTB to direct emissions to gauges
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
    address public override minter;

    /// @inheritdoc IVoter
    address public override rewardToken;

    /// @inheritdoc IVoter
    uint256 public override totalWeight;

    /// @dev Pool => Gauge
    mapping(address => address) internal _gauges;

    /// @dev Gauge => Pool
    mapping(address => address) internal _poolForGauge;

    /// @dev Gauge => Is valid gauge
    mapping(address => bool) internal _isGauge;

    /// @dev Gauge => Is alive
    mapping(address => bool) internal _isAlive;

    /// @dev Pool => Total votes
    mapping(address => uint256) internal _weights;

    /// @dev Token ID => Pool => Votes
    mapping(uint256 => mapping(address => uint256)) internal _votes;

    /// @dev Token ID => Used weight
    mapping(uint256 => uint256) internal _usedWeights;

    /// @dev Token ID => Last voted epoch
    mapping(uint256 => uint256) internal _lastVoted;

    /// @dev Token ID => Pools voted for
    mapping(uint256 => address[]) internal _poolVote;

    /// @dev Token => Is whitelisted
    mapping(address => bool) internal _isWhitelistedToken;

    /// @dev All pools with gauges
    address[] internal _allPools;

    /// @dev Reward claimable per gauge
    mapping(address => uint256) public claimable;

    /// @dev Index for global distribution
    uint256 public index;

    /// @dev Gauge supply index
    mapping(address => uint256) public supplyIndex;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _ve, address _rewardToken) {
        ve = _ve;
        rewardToken = _rewardToken;
        governor = msg.sender;
        minter = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IVoter
    function gauges(address pool) external view override returns (address) {
        return _gauges[pool];
    }

    /// @inheritdoc IVoter
    function poolForGauge(address gauge) external view override returns (address) {
        return _poolForGauge[gauge];
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
    function lastVoted(uint256 tokenId) external view override returns (uint256) {
        return _lastVoted[tokenId];
    }

    /// @inheritdoc IVoter
    function isWhitelistedToken(address token) external view override returns (bool) {
        return _isWhitelistedToken[token];
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
    function createGauge(address pool) external override returns (address gauge) {
        if (_gauges[pool] != address(0)) revert NotWhitelisted();

        gauge = address(new Gauge(pool, rewardToken, address(this)));

        _gauges[pool] = gauge;
        _poolForGauge[gauge] = pool;
        _isGauge[gauge] = true;
        _isAlive[gauge] = true;
        _allPools.push(pool);

        emit GaugeCreated(pool, gauge, msg.sender);
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
    function vote(uint256 tokenId, address[] calldata pools, uint256[] calldata weights_) external override nonReentrant {
        if (!IVotingEscrow(ve).isApprovedOrOwner(msg.sender, tokenId)) revert NotApprovedOrOwner();
        if (pools.length != weights_.length) revert InvalidWeights();
        if (pools.length > MAX_POOLS) revert TooManyPools();

        uint256 currentEpoch = _epochStart(block.timestamp);
        if (_lastVoted[tokenId] >= currentEpoch) revert AlreadyVotedThisEpoch();

        _reset(tokenId);
        _vote(tokenId, pools, weights_);
    }

    /// @inheritdoc IVoter
    function reset(uint256 tokenId) external override nonReentrant {
        if (!IVotingEscrow(ve).isApprovedOrOwner(msg.sender, tokenId)) revert NotApprovedOrOwner();

        uint256 currentEpoch = _epochStart(block.timestamp);
        if (_lastVoted[tokenId] >= currentEpoch) revert AlreadyVotedThisEpoch();

        _reset(tokenId);
    }

    /// @inheritdoc IVoter
    function poke(uint256 tokenId) external override nonReentrant {
        if (!IVotingEscrow(ve).isApprovedOrOwner(msg.sender, tokenId)) revert NotApprovedOrOwner();

        address[] memory pools = _poolVote[tokenId];
        uint256[] memory weights_ = new uint256[](pools.length);

        for (uint256 i = 0; i < pools.length; i++) {
            weights_[i] = _votes[tokenId][pools[i]];
        }

        _reset(tokenId);
        _vote(tokenId, pools, weights_);
    }

    function _vote(uint256 tokenId, address[] memory pools, uint256[] memory weights_) internal {
        uint256 votingPower = IVotingEscrow(ve).balanceOfNFT(tokenId);
        uint256 totalVoteWeight = 0;

        for (uint256 i = 0; i < weights_.length; i++) {
            totalVoteWeight += weights_[i];
        }

        uint256 usedWeight = 0;

        for (uint256 i = 0; i < pools.length; i++) {
            address pool = pools[i];
            address gauge = _gauges[pool];

            if (gauge == address(0)) continue;
            if (!_isAlive[gauge]) continue;

            uint256 poolWeight = (weights_[i] * votingPower) / totalVoteWeight;

            _votes[tokenId][pool] = poolWeight;
            _weights[pool] += poolWeight;
            totalWeight += poolWeight;
            usedWeight += poolWeight;

            _poolVote[tokenId].push(pool);

            emit Voted(msg.sender, tokenId, pool, poolWeight);
        }

        _usedWeights[tokenId] = usedWeight;
        _lastVoted[tokenId] = _epochStart(block.timestamp);

        IVotingEscrow(ve).voting(tokenId, true);
    }

    function _reset(uint256 tokenId) internal {
        address[] storage pools = _poolVote[tokenId];

        for (uint256 i = 0; i < pools.length; i++) {
            address pool = pools[i];
            uint256 votes_ = _votes[tokenId][pool];

            if (votes_ > 0) {
                _weights[pool] -= votes_;
                totalWeight -= votes_;
                _votes[tokenId][pool] = 0;

                emit Abstained(msg.sender, tokenId, votes_);
            }
        }

        delete _poolVote[tokenId];
        _usedWeights[tokenId] = 0;

        IVotingEscrow(ve).voting(tokenId, false);
    }

    /*//////////////////////////////////////////////////////////////
                           REWARD DISTRIBUTION
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IVoter
    function notifyRewardAmount(uint256 amount) external override nonReentrant {
        if (amount == 0) revert ZeroAmount();

        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), amount);

        uint256 _totalWeight = totalWeight;
        if (_totalWeight > 0) {
            index += (amount * 1e18) / _totalWeight;
        }

        emit NotifyReward(msg.sender, rewardToken, amount);
    }

    /// @inheritdoc IVoter
    function distribute(address gauge) public override {
        _updateFor(gauge);
        uint256 _claimable = claimable[gauge];
        if (_claimable > 0 && _isAlive[gauge]) {
            claimable[gauge] = 0;
            IERC20(rewardToken).approve(gauge, _claimable);
            IGauge(gauge).notifyRewardAmount(_claimable);
            emit DistributeReward(msg.sender, gauge, _claimable);
        }
    }

    /// @inheritdoc IVoter
    function distributeAll() external override {
        for (uint256 i = 0; i < _allPools.length; i++) {
            address gauge = _gauges[_allPools[i]];
            if (gauge != address(0)) {
                distribute(gauge);
            }
        }
    }

    function _updateFor(address gauge) internal {
        address pool = _poolForGauge[gauge];
        uint256 _weight = _weights[pool];

        if (_weight > 0) {
            uint256 _supplyIndex = supplyIndex[gauge];
            uint256 _index = index;
            supplyIndex[gauge] = _index;
            uint256 delta = _index - _supplyIndex;
            if (delta > 0) {
                claimable[gauge] += (_weight * delta) / 1e18;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                              ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IVoter
    function whitelistToken(address token, bool status) external override {
        if (msg.sender != governor) revert NotGovernor();
        _isWhitelistedToken[token] = status;
        emit WhitelistToken(token, status);
    }

    function setGovernor(address _governor) external {
        if (msg.sender != governor) revert NotGovernor();
        if (_governor == address(0)) revert ZeroAddress();
        governor = _governor;
    }

    function setMinter(address _minter) external {
        if (msg.sender != governor) revert NotGovernor();
        if (_minter == address(0)) revert ZeroAddress();
        minter = _minter;
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _epochStart(uint256 timestamp) internal pure returns (uint256) {
        return (timestamp / WEEK) * WEEK;
    }
}
