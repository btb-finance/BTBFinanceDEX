// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {VotingEscrow} from "./VotingEscrow.sol";

/// @title BribeMarket - Incentivize veBTB voting
/// @notice Protocols can bribe veBTB holders to vote for their pools
contract BribeMarket is ReentrancyGuard {
    using SafeERC20 for IERCC20;

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct Bribe {
        address token;
        uint256 amount;
        uint256 startTime;
        uint256 endTime;
        address briber;
        bool active;
    }

    struct Vote {
        uint256 amount; // Amount of voting power
        uint256 timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice veBTB contract
    VotingEscrow public veBTB;

    /// @notice Pool ID => Bribe ID => Bribe details
    mapping(bytes32 => mapping(uint256 => Bribe)) public bribes;

    /// @notice Pool ID => Array of active bribe IDs
    mapping(bytes32 => uint256[]) public poolBribes;

    /// @notice User => Pool ID => Votes
    mapping(address => mapping(bytes32 => Vote)) public userVotes;

    /// @notice Bribe ID counter
    uint256 public nextBribeId;

    /// @notice Total bribes per pool
    mapping(bytes32 => uint256) public totalBribesPerPool;

    /// @notice Fee on bribes (in basis points)
    uint256 public bribeFeeBps = 100; // 1%

    /// @notice Fee recipient
    address public feeRecipient;

    /// @notice Owner
    address public owner;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event BribeCreated(
        uint256 indexed bribeId,
        bytes32 indexed poolId,
        address indexed token,
        uint256 amount,
        uint256 startTime,
        uint256 endTime
    );

    event BribeClaimed(
        bytes32 indexed poolId,
        uint256 indexed bribeId,
        address indexed user,
        uint256 amount
    );

    event VoteRecorded(
        address indexed user,
        bytes32 indexed poolId,
        uint256 amount
    );

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidBribePeriod();
    error BribeNotActive();
    error NoVotingPower();
    error AlreadyClaimed();
    error NotOwner();

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _veBTB, address _feeRecipient) {
        veBTB = VotingEscrow(_veBTB);
        feeRecipient = _feeRecipient;
        owner = msg.sender;
        nextBribeId = 1;
    }

    /*//////////////////////////////////////////////////////////////
                            CREATE BRIBE
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a bribe to incentivize voting for a pool
    /// @param poolId The pool to incentivize
    /// @param token The reward token
    /// @param amount Total bribe amount
    /// @param duration How long the bribe lasts (in seconds)
    function createBribe(
        bytes32 poolId,
        address token,
        uint256 amount,
        uint256 duration
    ) external nonReentrant returns (uint256 bribeId) {
        if (duration < 1 days || duration > 30 days) revert InvalidBribePeriod();

        bribeId = nextBribeId++;

        uint256 fee = (amount * bribeFeeBps) / 10000;
        uint256 netAmount = amount - fee;

        bribes[poolId][bribeId] = Bribe({
            token: token,
            amount: netAmount,
            startTime: block.timestamp,
            endTime: block.timestamp + duration,
            briber: msg.sender,
            active: true
        });

        poolBribes[poolId].push(bribeId);
        totalBribesPerPool[poolId] += netAmount;

        // Transfer tokens
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(token).safeTransfer(feeRecipient, fee);

        emit BribeCreated(
            bribeId,
            poolId,
            token,
            netAmount,
            block.timestamp,
            block.timestamp + duration
        );

        return bribeId;
    }

    /*//////////////////////////////////////////////////////////////
                            VOTE & CLAIM
    //////////////////////////////////////////////////////////////*/

    /// @notice Record a vote to make user eligible for bribes
    /// @dev Called by Voter contract when user votes
    function recordVote(
        address user,
        bytes32 poolId,
        uint256 amount
    ) external {
        // Only Voter contract can call
        // (Add access control in production)

        userVotes[user][poolId] = Vote({
            amount: amount,
            timestamp: block.timestamp
        });

        emit VoteRecorded(user, poolId, amount);
    }

    /// @notice Claim bribes for a pool
    function claimBribes(bytes32 poolId) external nonReentrant {
        Vote storage vote = userVotes[msg.sender][poolId];
        if (vote.amount == 0) revert NoVotingPower();

        uint256[] storage bribeIds = poolBribes[poolId];
        uint256 totalClaimed = 0;

        for (uint256 i = 0; i < bribeIds.length; i++) {
            uint256 bribeId = bribeIds[i];
            Bribe storage bribe = bribes[poolId][bribeId];

            if (!bribe.active || block.timestamp > bribe.endTime) continue;

            // Calculate share based on voting power
            // Simplified: equal share per voter
            // In production: track total votes and calculate proportionally

            uint256 userShare = bribe.amount / 100; // Simplified: 1% per claim
            if (userShare > 0) {
                totalClaimed += userShare;
                bribe.amount -= userShare;

                IERC20(bribe.token).safeTransfer(msg.sender, userShare);

                emit BribeClaimed(poolId, bribeId, msg.sender, userShare);
            }
        }

        if (totalClaimed == 0) revert AlreadyClaimed();
    }

    /// @notice Get claimable bribes for a user
    function getClaimableBribes(
        address user,
        bytes32 poolId
    ) external view returns (uint256 totalAmount, address[] memory tokens, uint256[] memory amounts) {
        Vote storage vote = userVotes[user][poolId];
        if (vote.amount == 0) return (0, new address[](0), new uint256[](0));

        uint256[] storage bribeIds = poolBribes[poolId];
        
        // Count active bribes
        uint256 activeCount = 0;
        for (uint256 i = 0; i < bribeIds.length; i++) {
            Bribe storage bribe = bribes[poolId][bribeIds[i]];
            if (bribe.active && block.timestamp <= bribe.endTime) {
                activeCount++;
            }
        }

        tokens = new address[](activeCount);
        amounts = new uint256[](activeCount);

        uint256 index = 0;
        for (uint256 i = 0; i < bribeIds.length; i++) {
            Bribe storage bribe = bribes[poolId][bribeIds[i]];
            if (bribe.active && block.timestamp <= bribe.endTime) {
                tokens[index] = bribe.token;
                amounts[index] = bribe.amount / 100; // Simplified
                totalAmount += amounts[index];
                index++;
            }
        }

        return (totalAmount, tokens, amounts);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN
    //////////////////////////////////////////////////////////////*/

    function setBribeFee(uint256 newFeeBps) external onlyOwner {
        require(newFeeBps <= 500, "Fee too high"); // Max 5%
        bribeFeeBps = newFeeBps;
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        feeRecipient = newRecipient;
    }

    /// @notice Emergency withdraw stuck tokens
    function rescueTokens(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner, amount);
    }
}
