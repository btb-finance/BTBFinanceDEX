// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";

/// @title IVotingEscrow Interface
/// @notice Interface for veBTB - vote-escrowed BTB token
interface IVotingEscrow is IERC721, IERC721Metadata {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAmount();
    error LockExpired();
    error LockNotExpired();
    error InvalidLockTime();
    error NotApprovedOrOwner();
    error LockTooLong();
    error AlreadyVoted();
    error NotVoter();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposit(
        address indexed provider,
        uint256 indexed tokenId,
        uint256 value,
        uint256 indexed lockTime,
        uint256 timestamp
    );
    event Withdraw(address indexed provider, uint256 indexed tokenId, uint256 value, uint256 timestamp);
    event Supply(uint256 prevSupply, uint256 supply);

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct LockedBalance {
        int128 amount;
        uint256 end;
    }

    struct Point {
        int128 bias;
        int128 slope;
        uint256 ts;
        uint256 blk;
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Token used for locking
    function token() external view returns (address);

    /// @notice Voter contract
    function voter() external view returns (address);

    /// @notice Total supply of veNFTs
    function supply() external view returns (uint256);

    /// @notice Current token ID counter
    function tokenId() external view returns (uint256);

    /// @notice Get locked balance for a token
    function locked(uint256 tokenId) external view returns (LockedBalance memory);

    /// @notice Get voting power of a token at current timestamp
    function balanceOfNFT(uint256 tokenId) external view returns (uint256);

    /// @notice Get voting power of a token at a specific timestamp
    function balanceOfNFTAt(uint256 tokenId, uint256 timestamp) external view returns (uint256);

    /// @notice Get total voting power at current timestamp
    function totalSupply() external view returns (uint256);

    /// @notice Get total voting power at a specific timestamp
    function totalSupplyAt(uint256 timestamp) external view returns (uint256);

    /// @notice Check if token is approved or owned by spender
    function isApprovedOrOwner(address spender, uint256 tokenId) external view returns (bool);

    /// @notice Maximum lock time (4 years)
    function MAXTIME() external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                            WRITE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a new lock
    function createLock(uint256 value, uint256 lockDuration) external returns (uint256);

    /// @notice Create a lock for another address
    function createLockFor(uint256 value, uint256 lockDuration, address to) external returns (uint256);

    /// @notice Increase locked amount
    function increaseAmount(uint256 tokenId, uint256 value) external;

    /// @notice Extend lock time
    function increaseUnlockTime(uint256 tokenId, uint256 lockDuration) external;

    /// @notice Withdraw tokens after lock expires
    function withdraw(uint256 tokenId) external;

    /// @notice Merge two tokens
    function merge(uint256 from, uint256 to) external;

    /// @notice Split a token
    function split(uint256[] calldata amounts, uint256 tokenId) external returns (uint256[] memory);

    /// @notice Set voting status (called by Voter)
    function voting(uint256 tokenId, bool status) external;
}
