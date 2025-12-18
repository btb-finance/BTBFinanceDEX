// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/// @title IMinter Interface
/// @notice Interface for the BTB emissions minter
interface IMinter {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotPendingTeam();
    error NotTeam();
    error AlreadyNudged();
    error TooEarlyToMint();
    error NotVoter();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Mint(address indexed sender, uint256 weekly, uint256 circSupply, uint256 growth);
    event SetTeam(address indexed team);
    event AcceptTeam(address indexed team);

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function token() external view returns (address);
    function voter() external view returns (address);
    function ve() external view returns (address);
    function rewardsDistributor() external view returns (address);

    function team() external view returns (address);
    function pendingTeam() external view returns (address);

    function weekly() external view returns (uint256);
    function activePeriod() external view returns (uint256);
    function tailEmissionRate() external view returns (uint256);

    function WEEK() external view returns (uint256);
    function EMISSION() external view returns (uint256);
    function TAIL_BASE() external view returns (uint256);

    function calculateEmission() external view returns (uint256);
    function circulatingSupply() external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                            WRITE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function updatePeriod() external returns (uint256);
    function nudge() external;
    function setTeam(address team) external;
    function acceptTeam() external;
    function setRewardsDistributor(address _rewardsDistributor) external;
}
