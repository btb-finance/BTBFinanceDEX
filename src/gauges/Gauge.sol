// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IGauge} from "../interfaces/IGauge.sol";

/// @title BTB Finance Gauge
/// @author BTB Finance
/// @notice Gauge contract for LP token staking and BTB reward distribution
/// @dev Rewards are distributed over epochs. Called by Voter to notify rewards.
contract Gauge is IGauge, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant PRECISION = 1e18;
    uint256 internal constant WEEK = 7 days;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IGauge
    address public immutable override stakingToken;

    /// @inheritdoc IGauge
    address public immutable override rewardToken;

    /// @inheritdoc IGauge
    address public immutable override voter;

    /// @inheritdoc IGauge
    uint256 public override totalSupply;

    /// @inheritdoc IGauge
    uint256 public override rewardRate;

    /// @inheritdoc IGauge
    uint256 public override periodFinish;

    uint256 public rewardPerTokenStored;
    uint256 public lastUpdateTime;

    mapping(address => uint256) private _balances;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _stakingToken, address _rewardToken, address _voter) {
        stakingToken = _stakingToken;
        rewardToken = _rewardToken;
        voter = _voter;
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IGauge
    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    /// @inheritdoc IGauge
    function lastTimeRewardApplicable() public view override returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    /// @inheritdoc IGauge
    function rewardPerToken() public view override returns (uint256) {
        if (totalSupply == 0) {
            return rewardPerTokenStored;
        }
        return rewardPerTokenStored
            + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * PRECISION) / totalSupply;
    }

    /// @inheritdoc IGauge
    function earned(address account) public view override returns (uint256) {
        return (_balances[account] * (rewardPerToken() - userRewardPerTokenPaid[account])) / PRECISION + rewards[account];
    }

    /// @inheritdoc IGauge
    function left() external view override returns (uint256) {
        if (block.timestamp >= periodFinish) return 0;
        return (periodFinish - block.timestamp) * rewardRate;
    }

    /*//////////////////////////////////////////////////////////////
                           STAKING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IGauge
    function deposit(uint256 amount) external override {
        _deposit(amount, msg.sender);
    }

    /// @inheritdoc IGauge
    function deposit(uint256 amount, address recipient) external override {
        _deposit(amount, recipient);
    }

    function _deposit(uint256 amount, address recipient) internal nonReentrant {
        if (amount == 0) revert ZeroAmount();

        _updateReward(recipient);

        totalSupply += amount;
        _balances[recipient] += amount;

        IERC20(stakingToken).safeTransferFrom(msg.sender, address(this), amount);

        emit Deposit(msg.sender, recipient, amount);
    }

    /// @inheritdoc IGauge
    function withdraw(uint256 amount) external override nonReentrant {
        if (amount == 0) revert ZeroAmount();

        _updateReward(msg.sender);

        totalSupply -= amount;
        _balances[msg.sender] -= amount;

        IERC20(stakingToken).safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, amount);
    }

    /// @inheritdoc IGauge
    function getReward(address account) external override nonReentrant {
        _updateReward(account);

        uint256 reward = rewards[account];
        if (reward > 0) {
            rewards[account] = 0;
            IERC20(rewardToken).safeTransfer(account, reward);
            emit ClaimRewards(account, reward);
        }
    }

    /*//////////////////////////////////////////////////////////////
                           REWARD FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IGauge
    function notifyRewardAmount(uint256 amount) external override nonReentrant {
        if (msg.sender != voter) revert NotVoter();
        if (amount == 0) revert ZeroAmount();

        _updateReward(address(0));

        // Transfer reward tokens from voter
        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), amount);

        uint256 timestamp = block.timestamp;
        uint256 timeUntilNextEpoch = _epochEnd(timestamp) - timestamp;

        if (timestamp >= periodFinish) {
            rewardRate = amount / timeUntilNextEpoch;
        } else {
            uint256 remaining = periodFinish - timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (amount + leftover) / timeUntilNextEpoch;
        }

        // Ensure reward rate is not too high
        uint256 balance = IERC20(rewardToken).balanceOf(address(this));
        if (rewardRate > balance / timeUntilNextEpoch) revert RewardRateTooHigh();

        lastUpdateTime = timestamp;
        periodFinish = timestamp + timeUntilNextEpoch;

        emit NotifyReward(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _updateReward(address account) internal {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();

        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
    }

    function _epochStart(uint256 timestamp) internal pure returns (uint256) {
        return (timestamp / WEEK) * WEEK;
    }

    function _epochEnd(uint256 timestamp) internal pure returns (uint256) {
        return _epochStart(timestamp) + WEEK;
    }
}
