// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/// @title IVoter Interface
/// @notice Interface for the BTB Finance gauge voting system
interface IVoter {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotApprovedOrOwner();
    error AlreadyVotedThisEpoch();
    error NotWhitelisted();
    error NotGauge();
    error NotGovernor();
    error PoolNotAlive();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidWeights();
    error TooManyPools();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event GaugeCreated(address indexed pool, address indexed gauge, address indexed creator);
    event GaugeKilled(address indexed gauge);
    event GaugeRevived(address indexed gauge);
    event Voted(address indexed voter, uint256 indexed tokenId, address indexed pool, uint256 weight);
    event Abstained(address indexed voter, uint256 indexed tokenId, uint256 weight);
    event NotifyReward(address indexed sender, address indexed reward, uint256 amount);
    event DistributeReward(address indexed sender, address indexed gauge, uint256 amount);
    event WhitelistToken(address indexed token, bool indexed status);

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function ve() external view returns (address);
    function governor() external view returns (address);
    function minter() external view returns (address);
    function rewardToken() external view returns (address);

    function totalWeight() external view returns (uint256);
    function weights(address pool) external view returns (uint256);
    function votes(uint256 tokenId, address pool) external view returns (uint256);
    function usedWeights(uint256 tokenId) external view returns (uint256);
    function lastVoted(uint256 tokenId) external view returns (uint256);

    function gauges(address pool) external view returns (address);
    function poolForGauge(address gauge) external view returns (address);
    function isGauge(address gauge) external view returns (bool);
    function isAlive(address gauge) external view returns (bool);
    function isWhitelistedToken(address token) external view returns (bool);

    function poolsLength() external view returns (uint256);
    function allPools(uint256 index) external view returns (address);

    /*//////////////////////////////////////////////////////////////
                            WRITE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function createGauge(address pool) external returns (address);
    function vote(uint256 tokenId, address[] calldata pools, uint256[] calldata weights) external;
    function reset(uint256 tokenId) external;
    function poke(uint256 tokenId) external;

    function killGauge(address gauge) external;
    function reviveGauge(address gauge) external;

    function notifyRewardAmount(uint256 amount) external;
    function distribute(address gauge) external;
    function distributeAll() external;

    function whitelistToken(address token, bool status) external;
}
