// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/// @title IRewardsDistributor Interface
/// @notice Interface for veBTB rebase distribution
interface IRewardsDistributor {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotDepositor();
    error NotTeam();
    error ZeroAmount();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event CheckpointToken(uint256 time, uint256 tokens);
    event Claimed(uint256 indexed tokenId, uint256 amount, uint256 epochStart, uint256 epochEnd);

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function ve() external view returns (address);
    function token() external view returns (address);
    function depositor() external view returns (address);

    function lastTokenTime() external view returns (uint256);
    function tokenLastBalance() external view returns (uint256);
    function timeCursor() external view returns (uint256);

    function claimable(uint256 tokenId) external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                            WRITE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function checkpointToken() external;
    function checkpointTotalSupply() external;
    function claim(uint256 tokenId) external returns (uint256);
    function claimMany(uint256[] calldata tokenIds) external returns (bool);
    function depositFor(uint256 amount) external;
    function setDepositor(address depositor) external;
}
