// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IVotingEscrow} from "../interfaces/IVotingEscrow.sol";

contract InstantFeeDistributor is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IVotingEscrow public veBTB;
    address public owner;
    
    mapping(address => bool) public authorizedPools;
    mapping(address => mapping(address => uint256)) public userClaimed;
    mapping(address => uint256) public totalFeesCollected;
    mapping(address => uint256) public totalFeesClaimed;

    event FeesCollected(address indexed pool, address indexed token, uint256 amount);
    event FeesClaimed(address indexed user, address indexed token, uint256 amount);

    error NotAuthorized();
    error NotOwner();
    error NothingToClaim();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyAuthorizedPool() {
        if (!authorizedPools[msg.sender]) revert NotAuthorized();
        _;
    }

    constructor(address _veBTB) {
        veBTB = IVotingEscrow(_veBTB);
        owner = msg.sender;
    }

    // Pools send fees here
    function collectFees(address token, uint256 amount) external onlyAuthorizedPool nonReentrant {
        if (amount == 0) return;
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        totalFeesCollected[token] += amount;
        emit FeesCollected(msg.sender, token, amount);
    }

    // INSTANT claim - veBTB holders call this to get their share immediately
    function claimFees(address token) external nonReentrant {
        uint256 claimable = getClaimable(msg.sender, token);
        if (claimable == 0) revert NothingToClaim();

        userClaimed[msg.sender][token] += claimable;
        totalFeesClaimed[token] += claimable;

        IERC20(token).safeTransfer(msg.sender, claimable);
        emit FeesClaimed(msg.sender, token, claimable);
    }

    // Calculate instant claimable amount based on current veBTB balance
    function getClaimable(address user, address token) public view returns (uint256) {
        uint256 userVeBalance = veBTB.balanceOf(user);
        if (userVeBalance == 0) return 0;

        uint256 totalVeSupply = veBTB.totalSupply();
        if (totalVeSupply == 0) return 0;

        uint256 unclaimedFees = totalFeesCollected[token] - totalFeesClaimed[token];
        if (unclaimedFees == 0) return 0;

        // User's share = (user balance / total supply) * unclaimed fees
        uint256 userShare = (userVeBalance * unclaimedFees) / totalVeSupply;
        
        // Subtract what they already claimed
        uint256 alreadyClaimed = userClaimed[user][token];
        
        return userShare > alreadyClaimed ? userShare - alreadyClaimed : 0;
    }

    function authorizePool(address pool, bool authorized) external onlyOwner {
        authorizedPools[pool] = authorized;
    }

    function rescueTokens(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner, amount);
    }
}
