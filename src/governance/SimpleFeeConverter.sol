// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IRewardsDistributor} from "../interfaces/IRewardsDistributor.sol";

contract SimpleFeeConverter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IRewardsDistributor public rewardsDistributor;
    address public btbToken;
    mapping(address => bool) public authorizedPools;
    address public owner;

    event FeesCollected(address indexed pool, address indexed token, uint256 amount);

    error NotAuthorized();
    error NotOwner();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyAuthorizedPool() {
        if (!authorizedPools[msg.sender]) revert NotAuthorized();
        _;
    }

    constructor(address _rewardsDistributor, address _btbToken) {
        rewardsDistributor = IRewardsDistributor(_rewardsDistributor);
        btbToken = _btbToken;
        owner = msg.sender;
    }

    function collectFees(address token, uint256 amount) external onlyAuthorizedPool nonReentrant {
        if (amount == 0) return;
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit FeesCollected(msg.sender, token, amount);
    }

    function distributeFees() external nonReentrant {
        uint256 btbBalance = IERC20(btbToken).balanceOf(address(this));
        if (btbBalance > 0) {
            IERC20(btbToken).approve(address(rewardsDistributor), btbBalance);
            rewardsDistributor.depositFor(btbBalance);
        }
    }

    function authorizePool(address pool, bool authorized) external onlyOwner {
        authorizedPools[pool] = authorized;
    }

    function rescueTokens(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner, amount);
    }
}
