// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/// @title IGauge Interface  
/// @notice Interface for LP staking gauges
interface IGauge {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotVoter();
    error NotAlive();
    error ZeroAmount();
    error RewardRateTooHigh();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposit(address indexed from, address indexed to, uint256 amount);
    event Withdraw(address indexed from, uint256 amount);
    event NotifyReward(address indexed from, uint256 amount);
    event ClaimRewards(address indexed from, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function stakingToken() external view returns (address);
    function rewardToken() external view returns (address);
    function voter() external view returns (address);

    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);

    function rewardRate() external view returns (uint256);
    function rewardPerToken() external view returns (uint256);
    function lastTimeRewardApplicable() external view returns (uint256);
    function earned(address account) external view returns (uint256);

    function left() external view returns (uint256);
    function periodFinish() external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                            WRITE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 amount) external;
    function deposit(uint256 amount, address recipient) external;
    function withdraw(uint256 amount) external;
    function getReward(address account) external;
    function notifyRewardAmount(uint256 amount) external;
}
