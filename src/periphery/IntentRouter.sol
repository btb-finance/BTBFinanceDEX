// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolManager} from "../core/PoolManager.sol";
import {MEVProtectedPoolManager} from "../core/MEVProtectedPoolManager.sol";
import {ReCLAMMPoolManager} from "../core/ReCLAMMPoolManager.sol";

/// @title IntentRouter - Intent-based trading with RFQ
/// @notice Users express intent, solvers compete to fill at best price
/// @dev Combines AMM for small trades, RFQ for large trades, MEV protection for all
contract IntentRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct Intent {
        address user;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minAmountOut; // Slippage protection
        uint256 deadline;
        bool useRFQ; // Force RFQ for this trade
        bytes32 poolId; // Preferred pool (optional)
    }

    struct RFQQuote {
        address solver;
        uint256 amountOut;
        uint256 validUntil;
        bytes signature;
    }

    struct Route {
        address[] pools;
        uint256[] amounts;
        bool isRFQ;
        address rfqSolver;
    }

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice MEV Protected Pool Manager
    MEVProtectedPoolManager public poolManager;

    /// @notice ReCLAMM Pool Manager
    ReCLAMMPoolManager public reclammManager;

    /// @notice Authorized solvers (market makers)
    mapping(address => bool) public authorizedSolvers;

    /// @notice Intent hash => Filled amount
    mapping(bytes32 => uint256) public filledIntents;

    /// @notice User => Nonce (for replay protection)
    mapping(address => uint256) public nonces;

    /// @notice RFQ threshold - trades above this use RFQ
    uint256 public rfqThreshold = 10000 * 1e6; // $10k default (assuming 6 decimals)

    /// @notice Fee on RFQ trades (in basis points)
    uint256 public rfqFeeBps = 10; // 0.1%

    /// @notice Fee recipient
    address public feeRecipient;

    /// @notice Owner
    address public owner;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event IntentExecuted(
        bytes32 indexed intentHash,
        address indexed user,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        bool usedRFQ
    );

    event RFQQuoteAccepted(
        bytes32 indexed intentHash,
        address indexed solver,
        uint256 amountOut
    );

    event SolverAuthorized(address indexed solver, bool authorized);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error UnauthorizedSolver();
    error IntentExpired();
    error QuoteExpired();
    error InvalidSignature();
    error SlippageExceeded();
    error InsufficientLiquidity();
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

    constructor(
        address _poolManager,
        address _reclammManager,
        address _feeRecipient
    ) {
        poolManager = MEVProtectedPoolManager(payable(_poolManager));
        reclammManager = ReCLAMMPoolManager(payable(_reclammManager));
        feeRecipient = _feeRecipient;
        owner = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////
                            EXECUTE INTENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Execute a trade intent
    /// @dev Automatically routes small trades to AMM, large trades to RFQ
    function executeIntent(
        Intent calldata intent,
        RFQQuote calldata quote
    ) external nonReentrant returns (uint256 amountOut) {
        return _executeIntentInternal(intent, quote);
    }

    /// @dev Internal intent execution
    function _executeIntentInternal(
        Intent calldata intent,
        RFQQuote calldata quote
    ) internal returns (uint256 amountOut) {
        if (block.timestamp > intent.deadline) revert IntentExpired();

        bytes32 intentHash = keccak256(abi.encode(intent, nonces[intent.user]++));

        // Determine if we should use RFQ
        bool useRFQ = intent.useRFQ || intent.amountIn >= rfqThreshold || quote.amountOut > 0;

        if (useRFQ && quote.solver != address(0)) {
            // Use RFQ
            amountOut = _executeRFQ(intent, quote, intentHash);
        } else {
            // Use AMM
            amountOut = _executeAMM(intent, intentHash);
        }

        // Check slippage
        if (amountOut < intent.minAmountOut) revert SlippageExceeded();

        emit IntentExecuted(
            intentHash,
            intent.user,
            intent.tokenIn,
            intent.tokenOut,
            intent.amountIn,
            amountOut,
            useRFQ
        );

        return amountOut;
    }

    /*//////////////////////////////////////////////////////////////
                            RFQ EXECUTION
    //////////////////////////////////////////////////////////////*/

    function _executeRFQ(
        Intent calldata intent,
        RFQQuote calldata quote,
        bytes32 intentHash
    ) internal returns (uint256 amountOut) {
        if (!authorizedSolvers[quote.solver]) revert UnauthorizedSolver();
        if (block.timestamp > quote.validUntil) revert QuoteExpired();

        // Verify signature (simplified - in production use EIP-712)
        bytes32 quoteHash = keccak256(abi.encode(intentHash, quote.amountOut, quote.validUntil));
        address signer = recoverSigner(quoteHash, quote.signature);
        if (signer != quote.solver) revert InvalidSignature();

        // Calculate fees
        uint256 fee = (quote.amountOut * rfqFeeBps) / 10000;
        amountOut = quote.amountOut - fee;

        // Transfer tokens from user to solver
        IERC20(intent.tokenIn).safeTransferFrom(intent.user, quote.solver, intent.amountIn);

        // Transfer tokens from solver to user (minus fee)
        IERC20(intent.tokenOut).safeTransferFrom(quote.solver, intent.user, amountOut);

        // Transfer fee to protocol
        IERC20(intent.tokenOut).safeTransferFrom(quote.solver, feeRecipient, fee);

        filledIntents[intentHash] = intent.amountIn;

        emit RFQQuoteAccepted(intentHash, quote.solver, quote.amountOut);

        return amountOut;
    }

    /*//////////////////////////////////////////////////////////////
                            AMM EXECUTION
    //////////////////////////////////////////////////////////////*/

    function _executeAMM(
        Intent calldata intent,
        bytes32 intentHash
    ) internal returns (uint256 amountOut) {
        // Find best pool (simplified - in production use optimal routing)
        bytes32 poolId = intent.poolId != bytes32(0) 
            ? intent.poolId 
            : _findBestPool(intent.tokenIn, intent.tokenOut);

        // Queue swap for MEV protection
        PoolManager.SwapParams memory params = PoolManager.SwapParams({
            zeroForOne: intent.tokenIn < intent.tokenOut,
            amountSpecified: int256(intent.amountIn),
            sqrtPriceLimitX96: 0 // No limit
        });

        // Transfer tokens to pool manager
        IERC20(intent.tokenIn).safeTransferFrom(intent.user, address(poolManager), intent.amountIn);

        // Queue the swap (will be settled in batch)
        bytes32 orderId = poolManager.queueSwap{value: 0.001 ether}(poolId, params);

        // For immediate execution (small trades), also support direct swap
        // This is a placeholder - in production integrate with PoolManager
        amountOut = _simulateSwap(intent.tokenIn, intent.tokenOut, intent.amountIn);

        filledIntents[intentHash] = intent.amountIn;

        return amountOut;
    }

    /*//////////////////////////////////////////////////////////////
                            ROUTING LOGIC
    //////////////////////////////////////////////////////////////*/

    function _findBestPool(address tokenIn, address tokenOut) internal view returns (bytes32) {
        // In production: check multiple pools, compare prices, return best
        // For now return a placeholder
        return keccak256(abi.encodePacked(tokenIn, tokenOut));
    }

    function _simulateSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal pure returns (uint256) {
        // Simplified constant product formula
        // In production: get actual reserves from pool
        uint256 reserveIn = 1000000 * 1e18;
        uint256 reserveOut = 1000000 * 1e18;
        
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * 1000) + amountInWithFee;
        
        return numerator / denominator;
    }

    /// @notice Get best execution route for an intent
    function getBestRoute(Intent calldata intent) external view returns (Route memory route) {
        // Compare AMM vs RFQ
        uint256 ammOut = _simulateSwap(intent.tokenIn, intent.tokenOut, intent.amountIn);
        
        // In production: query solvers for RFQ quotes
        uint256 rfqOut = ammOut * 102 / 100; // Assume RFQ is 2% better

        if (intent.amountIn >= rfqThreshold || rfqOut > ammOut * 101 / 100) {
            route.isRFQ = true;
            route.amounts = new uint256[](1);
            route.amounts[0] = rfqOut;
        } else {
            route.isRFQ = false;
            route.pools = new address[](1);
            route.amounts = new uint256[](1);
            route.amounts[0] = ammOut;
        }

        return route;
    }

    /*//////////////////////////////////////////////////////////////
                            QUOTE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get quote from AMM
    function quoteAMM(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256 amountOut) {
        return _simulateSwap(tokenIn, tokenOut, amountIn);
    }

    /// @notice Check if RFQ would be better
    function shouldUseRFQ(Intent calldata intent) external view returns (bool) {
        return intent.amountIn >= rfqThreshold || intent.useRFQ;
    }

    /*//////////////////////////////////////////////////////////////
                            SOLVER MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function authorizeSolver(address solver, bool authorized) external onlyOwner {
        authorizedSolvers[solver] = authorized;
        emit SolverAuthorized(solver, authorized);
    }

    function setRFQThreshold(uint256 newThreshold) external onlyOwner {
        rfqThreshold = newThreshold;
    }

    function setRFQFee(uint256 newFeeBps) external onlyOwner {
        require(newFeeBps <= 100, "Fee too high"); // Max 1%
        rfqFeeBps = newFeeBps;
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        feeRecipient = newRecipient;
    }

    /*//////////////////////////////////////////////////////////////
                            SIGNATURE HELPERS
    //////////////////////////////////////////////////////////////*/

    function recoverSigner(bytes32 hash, bytes memory signature) internal pure returns (address) {
        // Simplified - in production use OpenZeppelin ECDSA
        require(signature.length == 65, "Invalid signature length");
        
        bytes32 r;
        bytes32 s;
        uint8 v;
        
        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }
        
        return ecrecover(hash, v, r, s);
    }

    /*//////////////////////////////////////////////////////////////
                            BATCH OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Execute multiple intents in one transaction
    function batchExecuteIntents(
        Intent[] calldata intents,
        RFQQuote[] calldata quotes
    ) external nonReentrant returns (uint256[] memory amountsOut) {
        require(intents.length == quotes.length, "Length mismatch");
        
        amountsOut = new uint256[](intents.length);
        
        for (uint256 i = 0; i < intents.length; i++) {
            amountsOut[i] = this.executeIntent(intents[i], quotes[i]);
        }
        
        return amountsOut;
    }

    /*//////////////////////////////////////////////////////////////
                            NATIVE ETH SUPPORT
    //////////////////////////////////////////////////////////////*/

    /// @notice Execute swap with native ETH
    function executeIntentWithETH(
        Intent calldata intent,
        RFQQuote calldata quote
    ) external payable nonReentrant returns (uint256 amountOut) {
        require(intent.tokenIn == address(0), "Must be ETH input");
        require(msg.value == intent.amountIn, "Incorrect ETH amount");

        // Wrap ETH to WETH for trading
        // (In production: use WETH contract)
        
        // Execute the swap
        amountOut = _executeIntentInternal(intent, quote);
        
        // Transfer output tokens to user
        // If output is ETH, unwrap WETH
        
        return amountOut;
    }
}
