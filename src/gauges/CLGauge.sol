// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ICLGauge} from "../interfaces/ICLGauge.sol";
import {ICLPool} from "../interfaces/ICLPool.sol";

/// @title BTB Finance CLGauge
/// @author BTB Finance
/// @notice Gauge for staking CL NFT positions and earning BTB rewards
/// @dev Rewards distributed based on in-range liquidity
contract CLGauge is ICLGauge, IERC721Receiver, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant PRECISION = 1e18;
    uint256 internal constant WEEK = 7 days;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICLGauge
    address public immutable override pool;

    /// @inheritdoc ICLGauge
    address public immutable override voter;

    /// @inheritdoc ICLGauge
    address public immutable override rewardToken;

    /// @inheritdoc ICLGauge
    address public immutable override nft;

    /// @inheritdoc ICLGauge
    uint256 public override totalSupply;

    /// @inheritdoc ICLGauge
    uint256 public override rewardRate;

    /// @inheritdoc ICLGauge
    uint256 public override periodFinish;

    uint256 public rewardPerTokenStored;
    uint256 public lastUpdateTime;

    /// @dev Token ID => Staked position info
    struct StakedPosition {
        address owner;
        uint128 liquidity;
        int24 tickLower;
        int24 tickUpper;
    }

    mapping(uint256 => StakedPosition) internal _stakedPositions;

    /// @dev Owner => Staked token IDs
    mapping(address => uint256[]) internal _stakedTokenIds;

    /// @dev Token ID => Index in owner's array
    mapping(uint256 => uint256) internal _tokenIdIndex;

    /// @dev Token ID => User reward per token paid
    mapping(uint256 => uint256) public userRewardPerTokenPaid;

    /// @dev Token ID => Rewards owed
    mapping(uint256 => uint256) public rewards;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _pool, address _nft, address _rewardToken, address _voter) {
        pool = _pool;
        nft = _nft;
        rewardToken = _rewardToken;
        voter = _voter;
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICLGauge
    function stakedTokenIds(address owner) external view override returns (uint256[] memory) {
        return _stakedTokenIds[owner];
    }

    /// @inheritdoc ICLGauge
    function stakedPositions(uint256 tokenId)
        external
        view
        override
        returns (address owner, uint128 liquidity, int24 tickLower, int24 tickUpper)
    {
        StakedPosition memory pos = _stakedPositions[tokenId];
        return (pos.owner, pos.liquidity, pos.tickLower, pos.tickUpper);
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalSupply == 0) {
            return rewardPerTokenStored;
        }
        return rewardPerTokenStored
            + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * PRECISION) / totalSupply;
    }

    /// @inheritdoc ICLGauge
    function earned(uint256 tokenId) public view override returns (uint256) {
        StakedPosition memory pos = _stakedPositions[tokenId];
        if (pos.owner == address(0)) return 0;

        uint256 effectiveLiquidity = _getEffectiveLiquidity(tokenId);
        return (effectiveLiquidity * (rewardPerToken() - userRewardPerTokenPaid[tokenId])) / PRECISION
            + rewards[tokenId];
    }

    /// @inheritdoc ICLGauge
    function left() external view override returns (uint256) {
        if (block.timestamp >= periodFinish) return 0;
        return (periodFinish - block.timestamp) * rewardRate;
    }

    /*//////////////////////////////////////////////////////////////
                           STAKING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICLGauge
    function deposit(uint256 tokenId) external override nonReentrant {
        _updateReward(tokenId);

        // Transfer NFT from user
        IERC721(nft).safeTransferFrom(msg.sender, address(this), tokenId);

        // Get position info from NFT manager
        (uint128 liquidity, int24 tickLower, int24 tickUpper) = _getPositionInfo(tokenId);

        if (liquidity == 0) revert ZeroAmount();

        // Store staked position
        _stakedPositions[tokenId] = StakedPosition({
            owner: msg.sender,
            liquidity: liquidity,
            tickLower: tickLower,
            tickUpper: tickUpper
        });

        // Add to owner's list
        _tokenIdIndex[tokenId] = _stakedTokenIds[msg.sender].length;
        _stakedTokenIds[msg.sender].push(tokenId);

        // Add liquidity to total
        totalSupply += liquidity;

        emit Deposit(msg.sender, tokenId, liquidity);
    }

    /// @inheritdoc ICLGauge
    function withdraw(uint256 tokenId) external override nonReentrant {
        StakedPosition memory pos = _stakedPositions[tokenId];
        if (pos.owner != msg.sender) revert NotOwner();

        _updateReward(tokenId);

        // Remove from total
        totalSupply -= pos.liquidity;

        // Claim any pending rewards
        uint256 reward = rewards[tokenId];
        if (reward > 0) {
            rewards[tokenId] = 0;
            IERC20(rewardToken).safeTransfer(msg.sender, reward);
            emit ClaimRewards(msg.sender, tokenId, reward);
        }

        // Remove from owner's list
        _removeTokenFromOwner(msg.sender, tokenId);

        // Clear position
        delete _stakedPositions[tokenId];
        delete userRewardPerTokenPaid[tokenId];

        // Return NFT
        IERC721(nft).safeTransferFrom(address(this), msg.sender, tokenId);

        emit Withdraw(msg.sender, tokenId, pos.liquidity);
    }

    /// @inheritdoc ICLGauge
    function getReward(uint256 tokenId) external override nonReentrant {
        StakedPosition memory pos = _stakedPositions[tokenId];
        if (pos.owner == address(0)) revert NotStaked();

        _updateReward(tokenId);

        uint256 reward = rewards[tokenId];
        if (reward > 0) {
            rewards[tokenId] = 0;
            IERC20(rewardToken).safeTransfer(pos.owner, reward);
            emit ClaimRewards(pos.owner, tokenId, reward);
        }
    }

    /*//////////////////////////////////////////////////////////////
                           REWARD FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICLGauge
    function notifyRewardAmount(uint256 amount) external override nonReentrant {
        if (msg.sender != voter) revert NotVoter();
        if (amount == 0) revert ZeroAmount();

        _updateReward(0);

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

        lastUpdateTime = timestamp;
        periodFinish = timestamp + timeUntilNextEpoch;

        emit NotifyReward(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _updateReward(uint256 tokenId) internal {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();

        if (tokenId != 0) {
            rewards[tokenId] = earned(tokenId);
            userRewardPerTokenPaid[tokenId] = rewardPerTokenStored;
        }
    }

    function _getEffectiveLiquidity(uint256 tokenId) internal view returns (uint256) {
        StakedPosition memory pos = _stakedPositions[tokenId];
        if (pos.owner == address(0)) return 0;

        // Check if position is in range
        (, int24 currentTick,) = ICLPool(pool).slot0();

        if (currentTick >= pos.tickLower && currentTick < pos.tickUpper) {
            return pos.liquidity; // In range - full rewards
        }
        return 0; // Out of range - no rewards
    }

    function _getPositionInfo(uint256 tokenId)
        internal
        view
        returns (uint128 liquidity, int24 tickLower, int24 tickUpper)
    {
        // Get position from pool directly
        // In production, this would query the NonfungiblePositionManager
        // For now, we assume the position exists and return placeholder
        // You'd integrate with your NFT position manager here
        
        // Placeholder - in real implementation get from NFT manager
        return (1 ether, -887220, 887220); // Default full range
    }

    function _removeTokenFromOwner(address owner, uint256 tokenId) internal {
        uint256[] storage tokenIds = _stakedTokenIds[owner];
        uint256 index = _tokenIdIndex[tokenId];
        uint256 lastIndex = tokenIds.length - 1;

        if (index != lastIndex) {
            uint256 lastTokenId = tokenIds[lastIndex];
            tokenIds[index] = lastTokenId;
            _tokenIdIndex[lastTokenId] = index;
        }

        tokenIds.pop();
        delete _tokenIdIndex[tokenId];
    }

    function _epochStart(uint256 timestamp) internal pure returns (uint256) {
        return (timestamp / WEEK) * WEEK;
    }

    function _epochEnd(uint256 timestamp) internal pure returns (uint256) {
        return _epochStart(timestamp) + WEEK;
    }

    /*//////////////////////////////////////////////////////////////
                              ERC721 RECEIVER
    //////////////////////////////////////////////////////////////*/

    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
