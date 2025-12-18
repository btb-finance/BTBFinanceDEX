// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IRewardsDistributor} from "../interfaces/IRewardsDistributor.sol";
import {IVotingEscrow} from "../interfaces/IVotingEscrow.sol";

/// @title BTB Finance RewardsDistributor
/// @author BTB Finance
/// @notice Distributes rebases to veBTB holders proportionally to their voting power
/// @dev Implements Curve-style fee distribution to veToken holders
contract RewardsDistributor is IRewardsDistributor, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant WEEK = 7 days;
    uint256 internal constant TOKEN_CHECKPOINT_DEADLINE = 1 days;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRewardsDistributor
    address public immutable override ve;

    /// @inheritdoc IRewardsDistributor
    address public immutable override token;

    /// @inheritdoc IRewardsDistributor
    address public override depositor;

    address public team;

    /// @inheritdoc IRewardsDistributor
    uint256 public override lastTokenTime;

    /// @inheritdoc IRewardsDistributor
    uint256 public override tokenLastBalance;

    /// @inheritdoc IRewardsDistributor
    uint256 public override timeCursor;

    /// @dev Start time for distribution
    uint256 public startTime;

    /// @dev Token ID => last claimed epoch
    mapping(uint256 => uint256) public timeCursorOf;

    /// @dev Token ID => epoch => claimed
    mapping(uint256 => mapping(uint256 => bool)) public claimed;

    /// @dev Epoch => tokens distributed
    mapping(uint256 => uint256) public tokensPerEpoch;

    /// @dev Epoch => total voting power
    mapping(uint256 => uint256) public veSupplyPerEpoch;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _ve) {
        ve = _ve;
        token = IVotingEscrow(_ve).token();
        depositor = msg.sender;
        team = msg.sender;

        uint256 t = (block.timestamp / WEEK) * WEEK;
        startTime = t;
        lastTokenTime = t;
        timeCursor = t;
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRewardsDistributor
    function claimable(uint256 tokenId) external view override returns (uint256) {
        uint256 t = timeCursorOf[tokenId];
        if (t == 0) t = startTime;

        uint256 toDistribute = 0;
        uint256 epochStart = (t / WEEK) * WEEK;
        uint256 currentEpoch = (block.timestamp / WEEK) * WEEK;

        // Calculate claimable for each epoch
        for (uint256 i = 0; i < 50 && epochStart < currentEpoch; i++) {
            if (!claimed[tokenId][epochStart]) {
                uint256 balance = IVotingEscrow(ve).balanceOfNFTAt(tokenId, epochStart + WEEK);
                uint256 supply = veSupplyPerEpoch[epochStart];
                uint256 tokens = tokensPerEpoch[epochStart];

                if (supply > 0 && balance > 0) {
                    toDistribute += (tokens * balance) / supply;
                }
            }
            epochStart += WEEK;
        }

        return toDistribute;
    }

    /*//////////////////////////////////////////////////////////////
                          CHECKPOINT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRewardsDistributor
    function checkpointToken() external override {
        _checkpointToken();
    }

    function _checkpointToken() internal {
        uint256 tokenBalance = IERC20(token).balanceOf(address(this));
        uint256 toDistribute = tokenBalance - tokenLastBalance;
        tokenLastBalance = tokenBalance;

        uint256 t = lastTokenTime;
        uint256 sinceLast = block.timestamp - t;
        lastTokenTime = block.timestamp;

        uint256 thisWeek = (t / WEEK) * WEEK;
        uint256 nextWeek = 0;

        // Distribute tokens to epochs
        for (uint256 i = 0; i < 20 && toDistribute > 0; i++) {
            nextWeek = thisWeek + WEEK;
            if (block.timestamp < nextWeek) {
                if (sinceLast == 0 && block.timestamp == t) {
                    tokensPerEpoch[thisWeek] += toDistribute;
                } else {
                    tokensPerEpoch[thisWeek] += (toDistribute * (block.timestamp - t)) / sinceLast;
                }
                break;
            } else {
                if (sinceLast == 0 && nextWeek == t) {
                    tokensPerEpoch[thisWeek] += toDistribute;
                } else {
                    tokensPerEpoch[thisWeek] += (toDistribute * (nextWeek - t)) / sinceLast;
                }
            }
            t = nextWeek;
            thisWeek = nextWeek;
        }

        emit CheckpointToken(block.timestamp, toDistribute);
    }

    /// @inheritdoc IRewardsDistributor
    function checkpointTotalSupply() external override {
        _checkpointTotalSupply();
    }

    function _checkpointTotalSupply() internal {
        uint256 t = timeCursor;
        uint256 roundedTimestamp = (block.timestamp / WEEK) * WEEK;

        for (uint256 i = 0; i < 20 && t < roundedTimestamp; i++) {
            uint256 epoch = t;
            t += WEEK;
            veSupplyPerEpoch[epoch] = IVotingEscrow(ve).totalSupplyAt(epoch + WEEK);
        }

        timeCursor = t;
    }

    /*//////////////////////////////////////////////////////////////
                           CLAIM FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRewardsDistributor
    function claim(uint256 tokenId) external override nonReentrant returns (uint256) {
        return _claim(tokenId, msg.sender);
    }

    /// @inheritdoc IRewardsDistributor
    function claimMany(uint256[] calldata tokenIds) external override nonReentrant returns (bool) {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _claim(tokenIds[i], msg.sender);
        }
        return true;
    }

    function _claim(uint256 tokenId, address recipient) internal returns (uint256) {
        if (!IVotingEscrow(ve).isApprovedOrOwner(msg.sender, tokenId)) {
            // Allow anyone to claim for a token, but send to owner
            recipient = IVotingEscrow(ve).ownerOf(tokenId);
        }

        // Checkpoints
        if (block.timestamp - lastTokenTime > TOKEN_CHECKPOINT_DEADLINE) {
            _checkpointToken();
            _checkpointTotalSupply();
        }

        uint256 t = timeCursorOf[tokenId];
        if (t == 0) t = startTime;

        uint256 toDistribute = 0;
        uint256 epochStart = (t / WEEK) * WEEK;
        uint256 currentEpoch = (block.timestamp / WEEK) * WEEK;

        // Claim for each epoch (max 50 epochs at once)
        for (uint256 i = 0; i < 50 && epochStart < currentEpoch; i++) {
            if (!claimed[tokenId][epochStart]) {
                uint256 balance = IVotingEscrow(ve).balanceOfNFTAt(tokenId, epochStart + WEEK);
                uint256 supply = veSupplyPerEpoch[epochStart];
                uint256 tokens = tokensPerEpoch[epochStart];

                if (supply > 0 && balance > 0) {
                    uint256 share = (tokens * balance) / supply;
                    toDistribute += share;
                }

                claimed[tokenId][epochStart] = true;
            }
            epochStart += WEEK;
        }

        timeCursorOf[tokenId] = epochStart;

        if (toDistribute > 0) {
            tokenLastBalance -= toDistribute;
            IERC20(token).safeTransfer(recipient, toDistribute);
            emit Claimed(tokenId, toDistribute, t, epochStart);
        }

        return toDistribute;
    }

    /*//////////////////////////////////////////////////////////////
                          DEPOSIT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRewardsDistributor
    function depositFor(uint256 amount) external override {
        if (amount == 0) revert ZeroAmount();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        _checkpointToken();
    }

    /*//////////////////////////////////////////////////////////////
                          ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRewardsDistributor
    function setDepositor(address _depositor) external override {
        if (msg.sender != team) revert NotTeam();
        depositor = _depositor;
    }

    function setTeam(address _team) external {
        if (msg.sender != team) revert NotTeam();
        team = _team;
    }
}
