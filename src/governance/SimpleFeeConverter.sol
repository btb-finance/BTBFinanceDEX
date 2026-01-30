// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IRewardsDistributor} from "../interfaces/IRewardsDistributor.sol";

/// @title SimpleFeeConverter - Converts trading fees to BTB for veBTB holders
/// @notice Collects fees from pools and deposits into RewardsDistributor
/// @dev Simple design: collect fees → convert to BTB → rewards for veBTB
contract SimpleFeeConverter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice RewardsDistributor contract
    IRewardsDistributor public rewardsDistributor;

    /// @notice BTB token
    address public btbToken;

    /// @notice Authorized pools that can send fees
    mapping(address => bool) public authorizedPools;

    /// @notice Owner
    address public owner;

    event FeesCollected(address indexed pool, address indexed token, uint256 amount);
    event PoolAuthorized(address indexed pool, bool authorized);

    error NotAuthorized();
    error NotOwner();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyAuthorizedPool() {
        if (!authorizedPools[msg.sender]) revert NotAuthorized();
        _;
    }

    constructor(address _rewardsDistributor, address _btbToken) {
        rewardsDistributor = IRewardsDistributor(_rewardsDistributor);
        btbToken = _btbToken;
        owner = msg.sender;
    }

    /// @notice Collect fees from pools
    /// @dev Pools send fees here, we hold them until converted to BTB
    function collectFees(address token, uint256 amount) external onlyAuthorizedPool nonReentrant {
        if (amount == 0) return;

        // Transfer fees from pool
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        emit FeesCollected(msg.sender, token, amount);
    }

    /// @notice Convert accumulated fees to BTB and deposit to RewardsDistributor
    /// @dev Anyone can call this to trigger distribution
    function distributeFees() external nonReentrant {
        // Get BTB balance (from previous swaps or direct deposits)
        uint256 btbBalance = IERC20(btbToken).balanceOf(address(this));

        if (btbBalance > 0) {
            // Approve and deposit to RewardsDistributor
            IERC20(btbToken).approve(address(rewardsDistributor), btbBalance);
            rewardsDistributor.depositFor(btbBalance);
        }
    }

    /// @notice Direct deposit BTB to RewardsDistributor
    function depositBTB(uint256 amount) external {
        IERC20(btbToken).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(btbToken).approve(address(rewardsDistributor), amount);
        rewardsDistributor.depositFor(amount);
    }

    /// @notice Admin: authorize pools to send fees
    function authorizePool(address pool, bool authorized) external onlyOwner {
        authorizedPools[pool] = authorized;
        emit PoolAuthorized(pool, authorized);
    }

    /// @notice Admin: rescue stuck tokens
    function rescueTokens(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner, amount);
    }

    /// @notice Admin: transfer ownership
    function transferOwnership(address newOwner) external onlyOwner {
        owner = newOwner;
    }
}
