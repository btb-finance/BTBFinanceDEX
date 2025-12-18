// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMinter} from "../interfaces/IMinter.sol";
import {IVoter} from "../interfaces/IVoter.sol";
import {IVotingEscrow} from "../interfaces/IVotingEscrow.sol";
import {IBTB} from "../interfaces/IBTB.sol";

/// @title BTB Finance Minter
/// @author BTB Finance
/// @notice Controls weekly BTB emissions to gauges
/// @dev Emissions decay over time with a tail emission rate
contract Minter is IMinter {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMinter
    uint256 public constant override WEEK = 7 days;

    /// @inheritdoc IMinter
    uint256 public constant override EMISSION = 990; // 99% of previous week (1% decay)

    /// @inheritdoc IMinter
    uint256 public constant override TAIL_BASE = 1000; // Tail emission = 0.2% of supply

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMinter
    address public immutable override token;

    /// @inheritdoc IMinter
    address public immutable override voter;

    /// @inheritdoc IMinter
    address public immutable override ve;

    /// @inheritdoc IMinter
    address public override rewardsDistributor;

    /// @inheritdoc IMinter
    address public override team;

    /// @inheritdoc IMinter
    address public override pendingTeam;

    /// @inheritdoc IMinter
    uint256 public override weekly;

    /// @inheritdoc IMinter
    uint256 public override activePeriod;

    /// @inheritdoc IMinter
    uint256 public override tailEmissionRate = 2; // 0.2% of circulating supply

    /// @dev Whether emissions have been started
    bool public isFirstMint = true;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _voter, address _ve, address _rewardsDistributor) {
        token = IVoter(_voter).rewardToken();
        voter = _voter;
        ve = _ve;
        rewardsDistributor = _rewardsDistributor;
        team = msg.sender;

        // Start at beginning of current epoch
        activePeriod = (block.timestamp / WEEK) * WEEK;
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMinter
    function calculateEmission() public view override returns (uint256) {
        return (weekly * EMISSION) / TAIL_BASE;
    }

    /// @inheritdoc IMinter
    function circulatingSupply() public view override returns (uint256) {
        // Total supply minus locked in VE
        return IERC20(token).totalSupply() - IVotingEscrow(ve).supply();
    }

    /// @dev Calculate weekly tail emissions based on circulating supply
    function _tailEmission() internal view returns (uint256) {
        return (circulatingSupply() * tailEmissionRate) / TAIL_BASE;
    }

    /*//////////////////////////////////////////////////////////////
                           EMISSION FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMinter
    function updatePeriod() external override returns (uint256) {
        uint256 _activePeriod = activePeriod;
        if (block.timestamp >= _activePeriod + WEEK) {
            _activePeriod = (block.timestamp / WEEK) * WEEK;
            activePeriod = _activePeriod;

            uint256 _weekly;
            if (isFirstMint) {
                // First mint starts the emissions schedule
                isFirstMint = false;
                // Initial emission: 15M BTB per week (configurable)
                _weekly = 15_000_000 ether;
            } else {
                // Calculate emission with decay
                _weekly = calculateEmission();
                uint256 _tail = _tailEmission();
                // Use tail emission as floor
                if (_weekly < _tail) {
                    _weekly = _tail;
                }
            }

            weekly = _weekly;
            uint256 _growth = _weekly;

            // Mint weekly emission
            IBTB(token).mint(address(this), _weekly);

            // Distribute to voters
            IERC20(token).approve(voter, _weekly);
            IVoter(voter).notifyRewardAmount(_weekly);

            emit Mint(msg.sender, _weekly, circulatingSupply(), _growth);
        }
        return _activePeriod;
    }

    /// @inheritdoc IMinter
    function nudge() external override {
        if (activePeriod != 0 && !isFirstMint) revert AlreadyNudged();
        // Force first mint on first nudge
        activePeriod = ((block.timestamp / WEEK) * WEEK) - WEEK;
    }

    /*//////////////////////////////////////////////////////////////
                          ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMinter
    function setTeam(address _team) external override {
        if (msg.sender != team) revert NotTeam();
        pendingTeam = _team;
    }

    /// @inheritdoc IMinter
    function acceptTeam() external override {
        if (msg.sender != pendingTeam) revert NotPendingTeam();
        team = pendingTeam;
        pendingTeam = address(0);
        emit AcceptTeam(team);
    }

    /// @inheritdoc IMinter
    function setRewardsDistributor(address _rewardsDistributor) external override {
        if (msg.sender != team) revert NotTeam();
        rewardsDistributor = _rewardsDistributor;
    }

    /// @notice Set the tail emission rate (in basis points / 1000)
    function setTailEmissionRate(uint256 _rate) external {
        if (msg.sender != team) revert NotTeam();
        tailEmissionRate = _rate;
    }
}
