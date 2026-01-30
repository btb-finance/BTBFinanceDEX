// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title IntentRouter - Intent-based trading with RFQ
/// @notice Users express intent, solvers compete to fill at best price
/// @dev Combines AMM for small trades, RFQ for large trades
contract IntentRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Intent {
        address user;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        uint256 deadline;
        bool useRfq;
    }

    struct RfqQuote {
        address solver;
        uint256 amountOut;
        uint256 validUntil;
        bytes signature;
    }

    address public owner;
    address public feeRecipient;
    
    mapping(address => bool) public authorizedSolvers;
    mapping(address => uint256) public nonces;
    
    uint256 public rfqThreshold = 10000 * 1e6;
    uint256 public rfqFeeBps = 10;

    event IntentExecuted(bytes32 indexed intentHash, address indexed user, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, bool usedRfq);
    event SolverAuthorized(address indexed solver, bool authorized);

    error UnauthorizedSolver();
    error IntentExpired();
    error QuoteExpired();
    error SlippageExceeded();
    error NotOwner();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _feeRecipient) {
        feeRecipient = _feeRecipient;
        owner = msg.sender;
    }

    function executeIntent(Intent calldata intent, RfqQuote calldata quote) external nonReentrant returns (uint256 amountOut) {
        if (block.timestamp > intent.deadline) revert IntentExpired();

        bytes32 intentHash = keccak256(abi.encode(intent, nonces[intent.user]++));
        bool useRfq = intent.useRfq || intent.amountIn >= rfqThreshold || quote.amountOut > 0;

        if (useRfq && quote.solver != address(0)) {
            amountOut = _executeRfq(intent, quote, intentHash);
        } else {
            amountOut = _executeAmm(intent, intentHash);
        }

        if (amountOut < intent.minAmountOut) revert SlippageExceeded();

        emit IntentExecuted(intentHash, intent.user, intent.tokenIn, intent.tokenOut, intent.amountIn, amountOut, useRfq);
        return amountOut;
    }

    function _executeRfq(Intent calldata intent, RfqQuote calldata quote, bytes32 intentHash) internal returns (uint256 amountOut) {
        if (!authorizedSolvers[quote.solver]) revert UnauthorizedSolver();
        if (block.timestamp > quote.validUntil) revert QuoteExpired();

        uint256 fee = (quote.amountOut * rfqFeeBps) / 10000;
        amountOut = quote.amountOut - fee;

        IERC20(intent.tokenIn).safeTransferFrom(intent.user, quote.solver, intent.amountIn);
        IERC20(intent.tokenOut).safeTransferFrom(quote.solver, intent.user, amountOut);
        IERC20(intent.tokenOut).safeTransferFrom(quote.solver, feeRecipient, fee);

        return amountOut;
    }

    function _executeAmm(Intent calldata intent, bytes32 intentHash) internal returns (uint256 amountOut) {
        // AMM execution through existing Router
        // Simplified for now - integrate with Router.sol
        amountOut = _simulateSwap(intent.tokenIn, intent.tokenOut, intent.amountIn);
        return amountOut;
    }

    function _simulateSwap(address tokenIn, address tokenOut, uint256 amountIn) internal pure returns (uint256) {
        // Placeholder - use actual Router in production
        uint256 reserveIn = 1000000 * 1e18;
        uint256 reserveOut = 1000000 * 1e18;
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * 1000) + amountInWithFee;
        return numerator / denominator;
    }

    function authorizeSolver(address solver, bool authorized) external onlyOwner {
        authorizedSolvers[solver] = authorized;
        emit SolverAuthorized(solver, authorized);
    }

    function setRfqThreshold(uint256 newThreshold) external onlyOwner {
        rfqThreshold = newThreshold;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        owner = newOwner;
    }
}
