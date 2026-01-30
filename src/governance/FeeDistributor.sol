// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {VotingEscrow} from "./VotingEscrow.sol";
import {IVoter} from "../interfaces/IVoter.sol";

/// @title FeeDistributor - Distributes 100% of trading fees to veBTB holders
/// @notice All trading fees from pools are collected here and distributed to veBTB holders
/// @dev Fees distributed proportionally based on voting power and time-weighted balance
contract FeeDistributor is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct TokenCheckpoint {
        uint256 timestamp;
        uint256 balanceOf;
    }

    struct FeeCheckpoint {
        uint256 timestamp;
        uint256 totalFees;
        uint256 distributedFees;
    }

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice veBTB contract
    VotingEscrow public veBTB;

    /// @notice Voter contract
    IVoter public voter;

    /// @notice Fee token (typically token0 or token1 from pools)
    mapping(address => bool) public feeTokens;

    /// @notice Token => Total fees collected
    mapping(address => uint256) public totalFeesCollected;

    /// @notice Token => Total fees distributed
    mapping(address => uint256) public totalFeesDistributed;

    /// @notice User => Token => Last claim timestamp
    mapping(address => mapping(address => uint256)) public lastClaimed;

    /// @notice User => Token => Claimable fees
    mapping(address => mapping(address => uint256)) public claimableFees;

    /// @notice Token checkpoints for calculating time-weighted balance
    mapping(uint256 => mapping(address => TokenCheckpoint[])) public tokenCheckpoints;

    /// @notice Fee checkpoints for each token
    mapping(address => FeeCheckpoint[]) public feeCheckpoints;

    /// @notice Last checkpoint timestamp per token
    mapping(address => uint256) public lastFeeCheckpoint;

    /// @notice Emergency owner
    address public owner;

    /// @notice Authorized fee collectors (pools)
    mapping(address => bool) public authorizedCollectors;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant WEEK = 7 days;
    uint256 public constant PRECISION = 1e18;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event FeesCollected(address indexed token, uint256 amount, address indexed collector);
    event FeesDistributed(address indexed token, uint256 totalAmount);
    event FeesClaimed(address indexed user, address indexed token, uint256 amount);
    event FeeTokenAdded(address indexed token);
    event CollectorAuthorized(address indexed collector, bool authorized);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotAuthorizedCollector();
    error NotFeeToken();
    error NoFeesToClaim();
    error NotOwner();
    error ZeroAmount();

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyAuthorizedCollector() {
        if (!authorizedCollectors[msg.sender]) revert NotAuthorizedCollector();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _veBTB, address _voter) {
        veBTB = VotingEscrow(_veBTB);
        voter = IVoter(_voter);
        owner = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////
                            FEE COLLECTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Collect trading fees from a pool
    /// @dev Called by pools when fees are accumulated
    /// @param token The token being collected (token0 or token1)
    /// @param amount Amount of fees to collect
    function collectFees(address token, uint256 amount) external onlyAuthorizedCollector nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (!feeTokens[token]) revert NotFeeToken();

        // Transfer fees from pool
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Update totals
        totalFeesCollected[token] += amount;

        // Record checkpoint for distribution calculation
        _updateFeeCheckpoint(token, amount);

        emit FeesCollected(token, amount, msg.sender);
    }

    /// @notice Collect ETH fees (for ETH pairs)
    function collectETHFees() external payable onlyAuthorizedCollector nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        
        // Track ETH fees separately
        totalFeesCollected[address(0)] += msg.value;
        _updateFeeCheckpoint(address(0), msg.value);

        emit FeesCollected(address(0), msg.value, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                            FEE DISTRIBUTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Distribute collected fees to all veBTB holders
    /// @dev Called weekly or when significant fees accumulate
    function distributeFees(address token) external nonReentrant {
        _distributeFeesInternal(token);
    }

    /// @notice Batch distribute multiple tokens
    function distributeFeesBatch(address[] calldata tokens) external nonReentrant {
        for (uint256 i = 0; i < tokens.length; i++) {
            _distributeFeesInternal(tokens[i]);
        }
    }

    /// @dev Internal fee distribution logic
    function _distributeFeesInternal(address token) internal {
        if (!feeTokens[token] && token != address(0)) revert NotFeeToken();

        uint256 undistributed = totalFeesCollected[token] - totalFeesDistributed[token];
        if (undistributed == 0) return;

        // Calculate total voting power at current time
        uint256 totalVotingPower = _getTotalVotingPower();
        if (totalVotingPower == 0) return;

        // Distribute to checkpoint system
        feeCheckpoints[token].push(FeeCheckpoint({
            timestamp: block.timestamp,
            totalFees: undistributed,
            distributedFees: 0
        }));

        totalFeesDistributed[token] += undistributed;
        lastFeeCheckpoint[token] = block.timestamp;

        emit FeesDistributed(token, undistributed);
    }

    /*//////////////////////////////////////////////////////////////
                            FEE CLAIMING
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculate claimable fees for a user
    function claimable(address user, address token) external view returns (uint256) {
        return _calculateClaimable(user, token);
    }

    /// @notice Claim fees for a specific token
    function claim(address token) external nonReentrant {
        uint256 amount = _calculateClaimable(msg.sender, token);
        if (amount == 0) revert NoFeesToClaim();

        // Reset claimable
        lastClaimed[msg.sender][token] = block.timestamp;

        // Transfer fees
        if (token == address(0)) {
            payable(msg.sender).transfer(amount);
        } else {
            IERC20(token).safeTransfer(msg.sender, amount);
        }

        emit FeesClaimed(msg.sender, token, amount);
    }

    /// @notice Claim all available fees across multiple tokens
    function claimAll(address[] calldata tokens) external nonReentrant {
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 amount = _calculateClaimable(msg.sender, tokens[i]);
            if (amount > 0) {
                lastClaimed[msg.sender][tokens[i]] = block.timestamp;
                
                if (tokens[i] == address(0)) {
                    payable(msg.sender).transfer(amount);
                } else {
                    IERC20(tokens[i]).safeTransfer(msg.sender, amount);
                }
                
                emit FeesClaimed(msg.sender, tokens[i], amount);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL CALCULATIONS
    //////////////////////////////////////////////////////////////*/

    function _calculateClaimable(address user, address token) internal view returns (uint256) {
        // Get user's veBTB tokens
        uint256 userTokenId = _getUserTokenId(user);
        if (userTokenId == 0) return 0;

        // Calculate time-weighted balance
        uint256 userBalance = _getTimeWeightedBalance(userTokenId);
        if (userBalance == 0) return 0;

        // Get total supply
        uint256 totalSupply = _getTotalVotingPower();
        if (totalSupply == 0) return 0;

        // Calculate share
        uint256 userShare = (userBalance * PRECISION) / totalSupply;

        // Get total fees since last claim
        uint256 feesSinceLastClaim = totalFeesDistributed[token] - _getFeesAtLastClaim(user, token);

        // Calculate claimable amount
        return (feesSinceLastClaim * userShare) / PRECISION;
    }

    function _getUserTokenId(address user) internal view returns (uint256) {
        // In production, iterate through veBTB tokens to find user's
        // For now, simplified
        return 1; // Placeholder
    }

    function _getTimeWeightedBalance(uint256 tokenId) internal view returns (uint256) {
        // Get current balance from veBTB
        return veBTB.balanceOfNFT(tokenId);
    }

    function _getTotalVotingPower() internal view returns (uint256) {
        return veBTB.totalSupply();
    }

    function _getFeesAtLastClaim(address user, address token) internal view returns (uint256) {
        uint256 lastClaim = lastClaimed[user][token];
        if (lastClaim == 0) return 0;

        // Find checkpoint at or before last claim
        FeeCheckpoint[] storage checkpoints = feeCheckpoints[token];
        for (uint256 i = checkpoints.length; i > 0; i--) {
            if (checkpoints[i-1].timestamp <= lastClaim) {
                return checkpoints[i-1].distributedFees;
            }
        }
        return 0;
    }

    function _updateFeeCheckpoint(address token, uint256 amount) internal {
        FeeCheckpoint[] storage checkpoints = feeCheckpoints[token];
        
        if (checkpoints.length > 0 && block.timestamp - checkpoints[checkpoints.length - 1].timestamp < 1 hours) {
            // Update existing checkpoint if within 1 hour
            checkpoints[checkpoints.length - 1].totalFees += amount;
        } else {
            // Create new checkpoint
            checkpoints.push(FeeCheckpoint({
                timestamp: block.timestamp,
                totalFees: amount,
                distributedFees: totalFeesDistributed[token]
            }));
        }

        // Clean old checkpoints (keep last 52 weeks)
        if (checkpoints.length > 52) {
            // Remove oldest checkpoint
            for (uint256 i = 0; i < checkpoints.length - 1; i++) {
                checkpoints[i] = checkpoints[i + 1];
            }
            checkpoints.pop();
        }
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function addFeeToken(address token) external onlyOwner {
        feeTokens[token] = true;
        emit FeeTokenAdded(token);
    }

    function authorizeCollector(address collector, bool authorized) external onlyOwner {
        authorizedCollectors[collector] = authorized;
        emit CollectorAuthorized(collector, authorized);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        owner = newOwner;
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getFeeCheckpoints(address token) external view returns (FeeCheckpoint[] memory) {
        return feeCheckpoints[token];
    }

    function getUndistributedFees(address token) external view returns (uint256) {
        return totalFeesCollected[token] - totalFeesDistributed[token];
    }

    /*//////////////////////////////////////////////////////////////
                            FALLBACK
    //////////////////////////////////////////////////////////////*/

    receive() external payable {}
}
