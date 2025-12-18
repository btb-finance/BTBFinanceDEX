// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/// @title ICLGauge Interface
/// @notice Interface for CL NFT position staking gauge
interface ICLGauge {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotOwner();
    error NotVoter();
    error NotAlive();
    error ZeroAmount();
    error NotStaked();
    error InvalidReward();
    error PositionNotInRange();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposit(address indexed user, uint256 indexed tokenId, uint128 liquidity);
    event Withdraw(address indexed user, uint256 indexed tokenId, uint128 liquidity);
    event NotifyReward(address indexed from, uint256 amount);
    event ClaimRewards(address indexed user, uint256 indexed tokenId, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function pool() external view returns (address);
    function voter() external view returns (address);
    function rewardToken() external view returns (address);
    function nft() external view returns (address);

    function totalSupply() external view returns (uint256);
    function stakedTokenIds(address owner) external view returns (uint256[] memory);
    function stakedPositions(uint256 tokenId) external view returns (address owner, uint128 liquidity, int24 tickLower, int24 tickUpper);

    function rewardRate() external view returns (uint256);
    function periodFinish() external view returns (uint256);
    function earned(uint256 tokenId) external view returns (uint256);
    function left() external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                            WRITE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 tokenId) external;
    function withdraw(uint256 tokenId) external;
    function getReward(uint256 tokenId) external;
    function notifyRewardAmount(uint256 amount) external;
}
