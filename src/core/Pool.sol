// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPool} from "../interfaces/IPool.sol";
import {IPoolFactory} from "../interfaces/IPoolFactory.sol";
import {IFlashLoanReceiver} from "../interfaces/IFlashLoanReceiver.sol";
import {Math} from "../libraries/Math.sol";

/// @title BTB Finance Pool
/// @author BTB Finance
/// @notice V2-style AMM pool with integrated BTB rewards. Voting = instant rewards.
/// @dev LP holders earn: 1) Trading fees (token0/token1), 2) BTB emissions (via voting)
contract Pool is IPool, ERC20Upgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant MINIMUM_LIQUIDITY = 1000;
    uint256 private constant PRECISION = 1e18;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    address public override token0;
    address public override token1;
    bool public override stable;
    address public override factory;

    // Reserves
    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;

    // Cumulative prices for TWAP
    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;

    // Trading fee tracking per LP (token0/token1)
    uint256 public index0;
    uint256 public index1;
    mapping(address => uint256) public supplyIndex0;
    mapping(address => uint256) public supplyIndex1;
    mapping(address => uint256) public override claimable0;
    mapping(address => uint256) public override claimable1;

    // Fee accumulator
    uint256 internal fees0;
    uint256 internal fees1;

    // Last K for stable pools
    uint256 internal _reserve0Last;
    uint256 internal _reserve1Last;

    // Decimals for stable math
    uint256 internal immutable decimals0;
    uint256 internal immutable decimals1;

    // BTB reward tracking
    address public rewardToken; // BTB token address
    uint256 public rewardIndex; // Global BTB per LP token
    mapping(address => uint256) public supplyRewardIndex; // Per user index
    mapping(address => uint256) public claimableReward; // BTB rewards owed
    uint256 public totalBTBRewards; // Total BTB received

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() {
        decimals0 = 18;
        decimals1 = 18;
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                               INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPool
    function initialize(address _token0, address _token1, bool _stable) external override initializer {
        __ERC20_init(
            string.concat("BTB Finance ", _stable ? "sAMM" : "vAMM", " - ", _getSymbol(_token0), "/", _getSymbol(_token1)),
            string.concat(_stable ? "sAMM" : "vAMM", "-", _getSymbol(_token0), "/", _getSymbol(_token1))
        );

        factory = msg.sender;
        token0 = _token0;
        token1 = _token1;
        stable = _stable;
        
        // Get BTB reward token from factory
        rewardToken = IPoolFactory(factory).voter(); // Voter has rewardToken
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPool
    function getReserves()
        public
        view
        override
        returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast)
    {
        return (reserve0, reserve1, blockTimestampLast);
    }

    /// @inheritdoc IPool
    function getAmountOut(uint256 amountIn, address tokenIn) external view override returns (uint256 amountOut) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        amountIn -= (amountIn * IPoolFactory(factory).getFee(address(this), stable)) / 10_000;

        if (stable) {
            uint256 xy = _k(_reserve0, _reserve1);
            _reserve0 = uint112((_reserve0 * PRECISION) / 10 ** decimals0);
            _reserve1 = uint112((_reserve1 * PRECISION) / 10 ** decimals1);

            (uint256 reserveA, uint256 reserveB) =
                tokenIn == token0 ? (_reserve0, _reserve1) : (_reserve1, _reserve0);
            amountIn = tokenIn == token0 ? (amountIn * PRECISION) / 10 ** decimals0 : (amountIn * PRECISION) / 10 ** decimals1;

            uint256 y = reserveB - _getY(amountIn + reserveA, xy, reserveB);
            return (y * (tokenIn == token0 ? 10 ** decimals1 : 10 ** decimals0)) / PRECISION;
        } else {
            (uint256 reserveA, uint256 reserveB) =
                tokenIn == token0 ? (uint256(_reserve0), uint256(_reserve1)) : (uint256(_reserve1), uint256(_reserve0));
            return (amountIn * reserveB) / (reserveA + amountIn);
        }
    }

    /// @inheritdoc IPool
    function getK() external view override returns (uint256) {
        return _k(reserve0, reserve1);
    }

    /// @inheritdoc IPool
    function observationLength() external pure override returns (uint256) {
        return 1;
    }

    /// @notice Get pending BTB rewards for an account
    function pendingReward(address account) external view returns (uint256) {
        uint256 _supplied = balanceOf(account);
        if (_supplied == 0) return claimableReward[account];
        
        uint256 _delta = rewardIndex - supplyRewardIndex[account];
        return claimableReward[account] + (_supplied * _delta) / PRECISION;
    }

    /*//////////////////////////////////////////////////////////////
                            LIQUIDITY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPool
    function mint(address to) external override nonReentrant returns (uint256 liquidity) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 - _reserve1;

        _updateFees(to);

        uint256 _totalSupply = totalSupply();
        if (_totalSupply == 0) {
            liquidity = Math.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mint(address(1), MINIMUM_LIQUIDITY);
        } else {
            liquidity = Math.min((amount0 * _totalSupply) / _reserve0, (amount1 * _totalSupply) / _reserve1);
        }

        if (liquidity == 0) revert InsufficientLiquidityMinted();
        _mint(to, liquidity);

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Mint(msg.sender, amount0, amount1);
    }

    /// @inheritdoc IPool
    function burn(address to) external override nonReentrant returns (uint256 amount0, uint256 amount1) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        address _token0 = token0;
        address _token1 = token1;
        uint256 balance0 = IERC20(_token0).balanceOf(address(this));
        uint256 balance1 = IERC20(_token1).balanceOf(address(this));
        uint256 liquidity = balanceOf(address(this));

        _updateFees(to);

        uint256 _totalSupply = totalSupply();
        amount0 = (liquidity * balance0) / _totalSupply;
        amount1 = (liquidity * balance1) / _totalSupply;
        if (amount0 == 0 || amount1 == 0) revert InsufficientLiquidityBurned();

        _burn(address(this), liquidity);
        IERC20(_token0).safeTransfer(to, amount0);
        IERC20(_token1).safeTransfer(to, amount1);

        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Burn(msg.sender, amount0, amount1, to);
    }

    /*//////////////////////////////////////////////////////////////
                            SWAP FUNCTION
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPool
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external override nonReentrant {
        if (amount0Out == 0 && amount1Out == 0) revert InsufficientOutputAmount();
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        if (amount0Out >= _reserve0 || amount1Out >= _reserve1) revert InsufficientLiquidity();

        if (to == token0 || to == token1) revert InvalidTo();

        if (amount0Out > 0) IERC20(token0).safeTransfer(to, amount0Out);
        if (amount1Out > 0) IERC20(token1).safeTransfer(to, amount1Out);

        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        uint256 amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint256 amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        if (amount0In == 0 && amount1In == 0) revert InsufficientInputAmount();

        {
            uint256 fee = IPoolFactory(factory).getFee(address(this), stable);
            if (amount0In > 0) {
                uint256 fee0 = (amount0In * fee) / 10_000;
                fees0 += fee0;
            }
            if (amount1In > 0) {
                uint256 fee1 = (amount1In * fee) / 10_000;
                fees1 += fee1;
            }
        }

        uint256 balance0Adjusted = balance0 - fees0;
        uint256 balance1Adjusted = balance1 - fees1;
        if (_k(balance0Adjusted, balance1Adjusted) < _k(_reserve0, _reserve1)) revert K();

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    /// @inheritdoc IPool
    /// @notice Swap with slippage protection - reverts if output is less than minOutput
    function swapWithSlippage(
        uint256 amount0Out,
        uint256 amount1Out,
        uint256 minOutput,
        address to,
        bytes calldata data
    ) external override nonReentrant {
        // Determine which token is being output
        uint256 actualOutput;
        if (amount0Out > 0) {
            actualOutput = amount0Out;
        } else if (amount1Out > 0) {
            actualOutput = amount1Out;
        }
        
        // Check slippage
        if (actualOutput < minOutput) revert SlippageExceeded();
        
        // Execute swap directly
        _executeSwap(amount0Out, amount1Out, to, data);
    }

    /// @dev Internal swap implementation
    function _executeSwap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) internal {
        // Same implementation as swap() but internal
        if (amount0Out == 0 && amount1Out == 0) revert InsufficientOutputAmount();
        (uint112 _reserve0, uint112 _reserve1,) = getReserves();
        if (amount0Out >= _reserve0 || amount1Out >= _reserve1) revert InsufficientLiquidity();
        if (to == token0 || to == token1) revert InvalidTo();

        if (amount0Out > 0) IERC20(token0).safeTransfer(to, amount0Out);
        if (amount1Out > 0) IERC20(token1).safeTransfer(to, amount1Out);
        if (data.length > 0) IPoolCallee(to).poolCall(msg.sender, amount0Out, amount1Out, data);

        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        uint256 amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint256 amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        if (amount0In == 0 && amount1In == 0) revert InsufficientInputAmount();

        {
            uint256 fee = IPoolFactory(factory).getFee(address(this), stable);
            if (amount0In > 0) {
                uint256 fee0 = (amount0In * fee) / 10_000;
                fees0 += fee0;
            }
            if (amount1In > 0) {
                uint256 fee1 = (amount1In * fee) / 10_000;
                fees1 += fee1;
            }
        }

        uint256 balance0Adjusted = balance0 - fees0;
        uint256 balance1Adjusted = balance1 - fees1;
        if (_k(balance0Adjusted, balance1Adjusted) < _k(_reserve0, _reserve1)) revert K();

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    /*//////////////////////////////////////////////////////////////
                            FEE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPool
    function claimFees() external override returns (uint256 claimed0, uint256 claimed1) {
        _updateFees(msg.sender);

        claimed0 = claimable0[msg.sender];
        claimed1 = claimable1[msg.sender];

        if (claimed0 > 0) {
            claimable0[msg.sender] = 0;
            IERC20(token0).safeTransfer(msg.sender, claimed0);
        }
        if (claimed1 > 0) {
            claimable1[msg.sender] = 0;
            IERC20(token1).safeTransfer(msg.sender, claimed1);
        }

        emit Claim(msg.sender, msg.sender, claimed0, claimed1);
    }

    /// @notice Claim BTB rewards
    function claimReward() external nonReentrant returns (uint256) {
        _updateReward(msg.sender);

        uint256 reward = claimableReward[msg.sender];
        if (reward > 0) {
            claimableReward[msg.sender] = 0;
            IERC20(rewardToken).safeTransfer(msg.sender, reward);
        }

        return reward;
    }

    /// @notice Receive BTB from VotingEscrow when someone votes for this pool
    function notifyRewardAmount(uint256 amount) external {
        // Only accept from VotingEscrow via Voter
        require(msg.sender == IPoolFactory(factory).voter(), "Not voter");
        
        if (amount == 0) return;
        
        // BTB is transferred to this contract by VotingEscrow
        // Update global reward index
        uint256 _totalSupply = totalSupply();
        if (_totalSupply > 0) {
            rewardIndex += (amount * PRECISION) / _totalSupply;
        }
        
        totalBTBRewards += amount;
    }

    /*//////////////////////////////////////////////////////////////
                          MAINTENANCE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPool
    function sync() external override nonReentrant {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }

    /// @inheritdoc IPool
    function skim(address to) external override nonReentrant {
        IERC20(token0).safeTransfer(to, IERC20(token0).balanceOf(address(this)) - reserve0);
        IERC20(token1).safeTransfer(to, IERC20(token1).balanceOf(address(this)) - reserve1);
    }

    /*//////////////////////////////////////////////////////////////
                          FLASH LOAN
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPool
    /// @notice Flash loan - borrow tokens without collateral, must repay + fee in same tx
    /// @param token0Amount Amount of token0 to borrow
    /// @param token1Amount Amount of token1 to borrow
    /// @param receiver Address to receive flash loan callback
    /// @param data Arbitrary data to pass to receiver
    function flash(uint256 token0Amount, uint256 token1Amount, address receiver, bytes calldata data) external override nonReentrant {
        if (token0Amount == 0 && token1Amount == 0) revert InsufficientOutputAmount();
        if (token0Amount >= reserve0 || token1Amount >= reserve1) revert InsufficientLiquidity();

        // Flash loan fee: 0.05% (5 basis points)
        uint256 FLASH_LOAN_FEE = 5;
        uint256 fee0 = (token0Amount * FLASH_LOAN_FEE) / 10000;
        uint256 fee1 = (token1Amount * FLASH_LOAN_FEE) / 10000;

        // Track balances before loan
        uint256 balance0Before = IERC20(token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(token1).balanceOf(address(this));

        // Transfer tokens to receiver
        if (token0Amount > 0) IERC20(token0).safeTransfer(receiver, token0Amount);
        if (token1Amount > 0) IERC20(token1).safeTransfer(receiver, token1Amount);

        // Call receiver callback
        IFlashLoanReceiver(receiver).onFlashLoan(
            msg.sender,
            token0Amount,
            token1Amount,
            fee0,
            fee1,
            data
        );

        // Verify repayment + fee
        uint256 balance0After = IERC20(token0).balanceOf(address(this));
        uint256 balance1After = IERC20(token1).balanceOf(address(this));

        // Must repay at least borrowed amount + fee
        if (token0Amount > 0 && balance0After < balance0Before + fee0) revert FlashLoanNotRepaid();
        if (token1Amount > 0 && balance1After < balance1Before + fee1) revert FlashLoanNotRepaid();

        // Accrue flash loan fees to LP holders
        if (fee0 > 0) fees0 += fee0;
        if (fee1 > 0) fees1 += fee1;

        emit FlashLoan(receiver, token0Amount, token1Amount, fee0, fee1);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _update(uint256 balance0, uint256 balance1, uint112 _reserve0, uint112 _reserve1) private {
        uint32 blockTimestamp = uint32(block.timestamp);
        unchecked {
            uint32 timeElapsed = blockTimestamp - blockTimestampLast;
            if (timeElapsed > 0 && _reserve0 > 0 && _reserve1 > 0) {
                price0CumulativeLast += uint256(_reserve1) * timeElapsed / _reserve0;
                price1CumulativeLast += uint256(_reserve0) * timeElapsed / _reserve1;
            }
        }

        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    function _updateFees(address account) internal {
        uint256 _supplied = balanceOf(account);
        if (_supplied > 0) {
            uint256 _delta0 = index0 - supplyIndex0[account];
            uint256 _delta1 = index1 - supplyIndex1[account];
            if (_delta0 > 0) {
                claimable0[account] += (_supplied * _delta0) / PRECISION;
            }
            if (_delta1 > 0) {
                claimable1[account] += (_supplied * _delta1) / PRECISION;
            }
        }
        supplyIndex0[account] = index0;
        supplyIndex1[account] = index1;
    }

    function _updateReward(address account) internal {
        uint256 _supplied = balanceOf(account);
        if (_supplied > 0) {
            uint256 _delta = rewardIndex - supplyRewardIndex[account];
            if (_delta > 0) {
                claimableReward[account] += (_supplied * _delta) / PRECISION;
            }
        }
        supplyRewardIndex[account] = rewardIndex;
    }

    function _k(uint256 x, uint256 y) internal view returns (uint256) {
        if (stable) {
            uint256 _x = (x * PRECISION) / 10 ** decimals0;
            uint256 _y = (y * PRECISION) / 10 ** decimals1;
            uint256 _a = (_x * _y) / PRECISION;
            uint256 _b = ((_x * _x) / PRECISION + (_y * _y) / PRECISION);
            return (_a * _b) / PRECISION;
        } else {
            return x * y;
        }
    }

    function _getY(uint256 x0, uint256 xy, uint256 y) internal pure returns (uint256) {
        for (uint256 i = 0; i < 255; i++) {
            uint256 yPrev = y;
            uint256 k = _f(x0, y);
            if (k < xy) {
                uint256 dy = ((xy - k) * PRECISION) / _d(x0, y);
                y = y + dy;
            } else {
                uint256 dy = ((k - xy) * PRECISION) / _d(x0, y);
                y = y - dy;
            }
            if (y > yPrev) {
                if (y - yPrev <= 1) return y;
            } else {
                if (yPrev - y <= 1) return y;
            }
        }
        return y;
    }

    function _f(uint256 x0, uint256 y) internal pure returns (uint256) {
        return (x0 * ((((y * y) / PRECISION) * y) / PRECISION)) / PRECISION
            + (((((x0 * x0) / PRECISION) * x0) / PRECISION) * y) / PRECISION;
    }

    function _d(uint256 x0, uint256 y) internal pure returns (uint256) {
        return (3 * x0 * ((y * y) / PRECISION)) / PRECISION + ((((x0 * x0) / PRECISION) * x0) / PRECISION);
    }

    function _getSymbol(address token) internal view returns (string memory) {
        (bool success, bytes memory data) = token.staticcall(abi.encodeWithSignature("symbol()"));
        return success ? abi.decode(data, (string)) : "???";
    }

    /*//////////////////////////////////////////////////////////////
                              ERC20 HOOKS
    //////////////////////////////////////////////////////////////*/

    function _update(address from, address to, uint256 value) internal override {
        _updateFees(from);
        _updateFees(to);
        _updateReward(from); // Auto-accrue BTB rewards
        _updateReward(to);
        super._update(from, to, value);
    }
}
