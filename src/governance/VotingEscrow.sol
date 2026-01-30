// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {ERC721EnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IVotingEscrow} from "../interfaces/IVotingEscrow.sol";
import {IPool} from "../interfaces/IPool.sol";

/// @title BTB Finance VotingEscrow
/// @author BTB Finance
/// @notice Vote-escrowed BTB (veBTB) - Lock BTB to receive voting power NFT
/// @dev Voting power decays linearly over time. Inspired by Curve/Velodrome.
contract VotingEscrow is IVotingEscrow, ERC721Upgradeable, ERC721EnumerableUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IVotingEscrow
    uint256 public constant override MAXTIME = 4 * 365 * 86400; // 4 years

    uint256 internal constant WEEK = 7 * 86400;
    int128 internal constant iMAXTIME = 4 * 365 * 86400;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IVotingEscrow
    address public override token;

    /// @inheritdoc IVotingEscrow
    address public override voter;

    /// @inheritdoc IVotingEscrow
    uint256 public override supply;

    /// @inheritdoc IVotingEscrow
    uint256 public override tokenId;

    /// @dev Token ID => Locked balance
    mapping(uint256 => LockedBalance) internal _locked;

    /// @dev Token ID => Voting status
    mapping(uint256 => bool) public voted;

    /// @dev Token ID => Point history
    mapping(uint256 => Point[]) internal _userPointHistory;

    /// @dev Global point history
    Point[] internal _pointHistory;

    /// @dev Slope changes at future timestamps
    mapping(uint256 => int128) public slopeChanges;

    /// @dev Team address for admin functions
    address public team;

    /// @dev Token ID => Emissions already distributed to pools
    mapping(uint256 => uint256) public emissionsDistributed;

    /// @dev Token ID => Total emission budget (set on lock creation)
    mapping(uint256 => uint256) public emissionBudget;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                              INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialize the VotingEscrow
    function initialize(address _token, address _voter) external initializer {
        __ERC721_init("Vote-escrowed BTB", "veBTB");
        __ERC721Enumerable_init();

        token = _token;
        voter = _voter;
        team = msg.sender;

        // Initialize point history
        _pointHistory.push(Point({bias: 0, slope: 0, ts: block.timestamp, blk: block.number}));
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IVotingEscrow
    function locked(uint256 _tokenId) external view override returns (LockedBalance memory) {
        return _locked[_tokenId];
    }

    /// @inheritdoc IVotingEscrow
    function balanceOfNFT(uint256 _tokenId) public view override returns (uint256) {
        return _balanceOfNFT(_tokenId, block.timestamp);
    }

    /// @inheritdoc IVotingEscrow
    function balanceOfNFTAt(uint256 _tokenId, uint256 _t) external view override returns (uint256) {
        return _balanceOfNFT(_tokenId, _t);
    }

    /// @inheritdoc IVotingEscrow
    function totalSupply() public view override(ERC721EnumerableUpgradeable, IVotingEscrow) returns (uint256) {
        return _totalSupplyAt(block.timestamp);
    }

    /// @inheritdoc IVotingEscrow
    function totalSupplyAt(uint256 _t) external view override returns (uint256) {
        return _totalSupplyAt(_t);
    }

    /// @inheritdoc IVotingEscrow
    function isApprovedOrOwner(address _spender, uint256 _tokenId) external view override returns (bool) {
        return _isAuthorized(ownerOf(_tokenId), _spender, _tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                           LOCK FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IVotingEscrow
    function createLock(uint256 _value, uint256 _lockDuration) external override returns (uint256) {
        return _createLock(_value, _lockDuration, msg.sender);
    }

    /// @inheritdoc IVotingEscrow
    function createLockFor(uint256 _value, uint256 _lockDuration, address _to) external override returns (uint256) {
        return _createLock(_value, _lockDuration, _to);
    }

    function _createLock(uint256 _value, uint256 _lockDuration, address _to) internal nonReentrant returns (uint256) {
        if (_value == 0) revert ZeroAmount();

        uint256 unlockTime = ((block.timestamp + _lockDuration) / WEEK) * WEEK; // Round to week
        if (unlockTime <= block.timestamp) revert InvalidLockTime();
        if (unlockTime > block.timestamp + MAXTIME) revert LockTooLong();

        ++tokenId;
        uint256 _tokenId = tokenId;
        _mint(_to, _tokenId);

        _depositFor(_tokenId, _value, unlockTime, _locked[_tokenId], 1); // 1 = CREATE_LOCK_TYPE

        return _tokenId;
    }

    /// @inheritdoc IVotingEscrow
    function increaseAmount(uint256 _tokenId, uint256 _value) external override nonReentrant {
        if (!_isAuthorized(ownerOf(_tokenId), msg.sender, _tokenId)) revert NotApprovedOrOwner();
        if (_value == 0) revert ZeroAmount();

        LockedBalance memory oldLocked = _locked[_tokenId];
        if (oldLocked.amount <= 0) revert ZeroAmount();
        if (oldLocked.end <= block.timestamp) revert LockExpired();

        _depositFor(_tokenId, _value, 0, oldLocked, 2); // 2 = INCREASE_LOCK_AMOUNT
    }

    /// @inheritdoc IVotingEscrow
    function increaseUnlockTime(uint256 _tokenId, uint256 _lockDuration) external override nonReentrant {
        if (!_isAuthorized(ownerOf(_tokenId), msg.sender, _tokenId)) revert NotApprovedOrOwner();

        LockedBalance memory oldLocked = _locked[_tokenId];
        if (oldLocked.amount <= 0) revert ZeroAmount();
        if (oldLocked.end <= block.timestamp) revert LockExpired();
        if (voted[_tokenId]) revert AlreadyVoted();

        uint256 unlockTime = ((block.timestamp + _lockDuration) / WEEK) * WEEK;
        if (unlockTime <= oldLocked.end) revert InvalidLockTime();
        if (unlockTime > block.timestamp + MAXTIME) revert LockTooLong();

        _depositFor(_tokenId, 0, unlockTime, oldLocked, 3); // 3 = INCREASE_UNLOCK_TIME
    }

    /// @inheritdoc IVotingEscrow
    function withdraw(uint256 _tokenId) external override nonReentrant {
        if (!_isAuthorized(ownerOf(_tokenId), msg.sender, _tokenId)) revert NotApprovedOrOwner();

        LockedBalance memory oldLocked = _locked[_tokenId];
        if (block.timestamp < oldLocked.end) revert LockNotExpired();
        if (voted[_tokenId]) revert AlreadyVoted();

        uint256 value = uint256(int256(oldLocked.amount));

        _locked[_tokenId] = LockedBalance(0, 0);
        uint256 supplyBefore = supply;
        supply = supplyBefore - value;

        // Checkpoint
        _checkpoint(_tokenId, oldLocked, LockedBalance(0, 0));

        IERC20(token).safeTransfer(msg.sender, value);

        // Burn the NFT
        _burn(_tokenId);

        emit Withdraw(msg.sender, _tokenId, value, block.timestamp);
        emit Supply(supplyBefore, supply);
    }

    /// @inheritdoc IVotingEscrow
    function merge(uint256 _from, uint256 _to) external override nonReentrant {
        if (!_isAuthorized(ownerOf(_from), msg.sender, _from)) revert NotApprovedOrOwner();
        if (!_isAuthorized(ownerOf(_to), msg.sender, _to)) revert NotApprovedOrOwner();
        if (voted[_from] || voted[_to]) revert AlreadyVoted();

        LockedBalance memory fromLocked = _locked[_from];
        LockedBalance memory toLocked = _locked[_to];

        if (fromLocked.end <= block.timestamp) revert LockExpired();
        if (toLocked.end <= block.timestamp) revert LockExpired();

        uint256 value = uint256(int256(fromLocked.amount));
        uint256 end = fromLocked.end > toLocked.end ? fromLocked.end : toLocked.end;

        _locked[_from] = LockedBalance(0, 0);
        _checkpoint(_from, fromLocked, LockedBalance(0, 0));
        _burn(_from);

        _depositFor(_to, value, end, toLocked, 4); // 4 = MERGE_TYPE
    }

    /// @inheritdoc IVotingEscrow
    function split(uint256[] calldata _amounts, uint256 _tokenId)
        external
        override
        nonReentrant
        returns (uint256[] memory)
    {
        if (!_isAuthorized(ownerOf(_tokenId), msg.sender, _tokenId)) revert NotApprovedOrOwner();
        if (voted[_tokenId]) revert AlreadyVoted();

        LockedBalance memory locked_ = _locked[_tokenId];
        if (locked_.end <= block.timestamp) revert LockExpired();

        uint256 totalAmount = 0;
        for (uint256 i = 0; i < _amounts.length; i++) {
            totalAmount += _amounts[i];
        }
        if (int256(totalAmount) != int256(locked_.amount)) revert ZeroAmount();

        // Burn original
        _locked[_tokenId] = LockedBalance(0, 0);
        _checkpoint(_tokenId, locked_, LockedBalance(0, 0));
        _burn(_tokenId);

        // Create new tokens
        uint256[] memory newTokenIds = new uint256[](_amounts.length);
        for (uint256 i = 0; i < _amounts.length; i++) {
            ++tokenId;
            newTokenIds[i] = tokenId;
            _mint(msg.sender, tokenId);

            LockedBalance memory newLocked = LockedBalance({amount: int128(int256(_amounts[i])), end: locked_.end});
            _locked[tokenId] = newLocked;
            _checkpoint(tokenId, LockedBalance(0, 0), newLocked);
        }

        return newTokenIds;
    }

    /// @inheritdoc IVotingEscrow
    function voting(uint256 _tokenId, bool _status) external override {
        if (msg.sender != voter) revert NotVoter();
        voted[_tokenId] = _status;
    }

    /// @inheritdoc IVotingEscrow
    /// @notice Get remaining emission budget for a veNFT
    /// @dev Budget = locked amount - already distributed
    function getEmissionBudget(uint256 _tokenId) external view override returns (uint256) {
        uint256 budget = emissionBudget[_tokenId];
        uint256 distributed = emissionsDistributed[_tokenId];
        return budget > distributed ? budget - distributed : 0;
    }

    /// @inheritdoc IVotingEscrow
    /// @notice Distribute BTB emissions from veNFT to a pool
    /// @dev Only callable by Voter contract
    function distributeEmission(uint256 _tokenId, address _pool, uint256 _amount) external override {
        if (msg.sender != voter) revert NotVoter();
        if (_amount == 0) revert ZeroAmount();
        
        uint256 budget = emissionBudget[_tokenId];
        uint256 distributed = emissionsDistributed[_tokenId];
        uint256 remaining = budget > distributed ? budget - distributed : 0;
        
        if (_amount > remaining) revert ZeroAmount(); // Not enough budget
        
        // Transfer BTB to pool
        IERC20(token).safeTransfer(_pool, _amount);
        
        // Track distribution
        emissionsDistributed[_tokenId] += _amount;
        
        // Notify pool to distribute to LP holders
        IPool(_pool).notifyRewardAmount(_amount);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _depositFor(
        uint256 _tokenId,
        uint256 _value,
        uint256 _unlockTime,
        LockedBalance memory _oldLocked,
        uint256 /* _type */
    ) internal {
        LockedBalance memory newLocked = LockedBalance({
            amount: _oldLocked.amount + int128(int256(_value)),
            end: _unlockTime == 0 ? _oldLocked.end : _unlockTime
        });

        uint256 supplyBefore = supply;
        supply = supplyBefore + _value;

        _locked[_tokenId] = newLocked;
        _checkpoint(_tokenId, _oldLocked, newLocked);

        if (_value > 0) {
            IERC20(token).safeTransferFrom(msg.sender, address(this), _value);
            // Set emission budget equal to locked amount
            emissionBudget[_tokenId] += _value;
        }

        emit Deposit(msg.sender, _tokenId, _value, newLocked.end, block.timestamp);
        emit Supply(supplyBefore, supply);
    }

    function _checkpoint(uint256 _tokenId, LockedBalance memory _oldLocked, LockedBalance memory _newLocked) internal {
        Point memory uOld;
        Point memory uNew;

        if (_tokenId != 0) {
            // Calculate old point
            if (_oldLocked.end > block.timestamp && _oldLocked.amount > 0) {
                uOld.slope = _oldLocked.amount / iMAXTIME;
                uOld.bias = uOld.slope * int128(int256(_oldLocked.end - block.timestamp));
            }
            // Calculate new point
            if (_newLocked.end > block.timestamp && _newLocked.amount > 0) {
                uNew.slope = _newLocked.amount / iMAXTIME;
                uNew.bias = uNew.slope * int128(int256(_newLocked.end - block.timestamp));
            }

            // Update slope changes
            if (_oldLocked.end > 0) {
                slopeChanges[_oldLocked.end] += uOld.slope;
            }
            if (_newLocked.end > 0) {
                slopeChanges[_newLocked.end] -= uNew.slope;
            }
        }

        // Update user point history
        uNew.ts = block.timestamp;
        uNew.blk = block.number;
        _userPointHistory[_tokenId].push(uNew);

        // Update global point
        Point memory lastPoint =
            _pointHistory.length > 0 ? _pointHistory[_pointHistory.length - 1] : Point(0, 0, block.timestamp, block.number);

        Point memory newPoint = Point({
            bias: lastPoint.bias + uNew.bias - uOld.bias,
            slope: lastPoint.slope + uNew.slope - uOld.slope,
            ts: block.timestamp,
            blk: block.number
        });

        if (newPoint.bias < 0) newPoint.bias = 0;
        if (newPoint.slope < 0) newPoint.slope = 0;

        _pointHistory.push(newPoint);
    }

    function _balanceOfNFT(uint256 _tokenId, uint256 _t) internal view returns (uint256) {
        if (_userPointHistory[_tokenId].length == 0) return 0;

        Point memory lastPoint = _userPointHistory[_tokenId][_userPointHistory[_tokenId].length - 1];
        lastPoint.bias -= lastPoint.slope * int128(int256(_t - lastPoint.ts));

        if (lastPoint.bias < 0) return 0;
        return uint256(int256(lastPoint.bias));
    }

    function _totalSupplyAt(uint256 _t) internal view returns (uint256) {
        if (_pointHistory.length == 0) return 0;

        Point memory lastPoint = _pointHistory[_pointHistory.length - 1];
        lastPoint.bias -= lastPoint.slope * int128(int256(_t - lastPoint.ts));

        if (lastPoint.bias < 0) return 0;
        return uint256(int256(lastPoint.bias));
    }

    /*//////////////////////////////////////////////////////////////
                              ERC721 HOOKS
    //////////////////////////////////////////////////////////////*/

    function _update(address to, uint256 _tokenId, address auth)
        internal
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable)
        returns (address)
    {
        // Prevent transfers of locked tokens that have votes
        if (voted[_tokenId]) revert AlreadyVoted();
        return super._update(to, _tokenId, auth);
    }

    function _increaseBalance(address account, uint128 value)
        internal
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable)
    {
        super._increaseBalance(account, value);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable, IERC165)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
