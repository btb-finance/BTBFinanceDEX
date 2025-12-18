// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IPoolFactory} from "../interfaces/IPoolFactory.sol";
import {IPool} from "../interfaces/IPool.sol";

/// @title BTB Finance Pool Factory
/// @author BTB Finance
/// @notice Factory for deploying V2-style AMM pools
/// @dev Uses CREATE2 with Clones library for deterministic addresses. UUPS upgradeable.
contract PoolFactory is IPoolFactory, OwnableUpgradeable, UUPSUpgradeable {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Maximum fee (5%)
    uint256 public constant MAX_FEE = 500;

    /// @notice Zero fee sentinel
    uint256 public constant ZERO_FEE_INDICATOR = type(uint256).max;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPoolFactory
    address public override implementation;

    /// @inheritdoc IPoolFactory
    address public override voter;

    /// @inheritdoc IPoolFactory
    address public override pauser;

    /// @inheritdoc IPoolFactory
    address public override feeManager;

    /// @inheritdoc IPoolFactory
    bool public override isPaused;

    /// @inheritdoc IPoolFactory
    uint256 public override volatileFee;

    /// @inheritdoc IPoolFactory
    uint256 public override stableFee;

    /// @dev Pool address => custom fee (0 means use default)
    mapping(address => uint256) internal _customFee;

    /// @dev token0 => token1 => stable => pool
    mapping(address => mapping(address => mapping(bool => address))) internal _pools;

    /// @dev All pools array
    address[] internal _allPools;

    /// @dev Is valid pool
    mapping(address => bool) internal _isPool;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                              INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialize the factory
    /// @param _implementation Pool implementation address
    /// @param _voter Voter contract address
    function initialize(address _implementation, address _voter) external initializer {
        if (_implementation == address(0)) revert ZeroAddress();

        __Ownable_init(msg.sender);

        implementation = _implementation;
        voter = _voter;
        pauser = msg.sender;
        feeManager = msg.sender;

        // Default fees: 0.3% volatile, 0.05% stable
        volatileFee = 30;
        stableFee = 5;
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPoolFactory
    function allPoolsLength() external view override returns (uint256) {
        return _allPools.length;
    }

    /// @inheritdoc IPoolFactory
    function getPool(address tokenA, address tokenB, bool stable) external view override returns (address) {
        (address token0, address token1) = _sortTokens(tokenA, tokenB);
        return _pools[token0][token1][stable];
    }

    /// @inheritdoc IPoolFactory
    function isPool(address pool) external view override returns (bool) {
        return _isPool[pool];
    }

    /// @inheritdoc IPoolFactory
    function customFee(address pool) external view override returns (uint256) {
        return _customFee[pool];
    }

    /// @inheritdoc IPoolFactory
    function getFee(address pool, bool stable) external view override returns (uint256) {
        uint256 fee = _customFee[pool];
        if (fee == ZERO_FEE_INDICATOR) return 0;
        return fee != 0 ? fee : (stable ? stableFee : volatileFee);
    }

    /*//////////////////////////////////////////////////////////////
                           POOL CREATION
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPoolFactory
    function createPool(address tokenA, address tokenB, bool stable) external override returns (address pool) {
        if (tokenA == tokenB) revert IdenticalAddresses();
        (address token0, address token1) = _sortTokens(tokenA, tokenB);
        if (token0 == address(0)) revert ZeroAddress();
        if (_pools[token0][token1][stable] != address(0)) revert PoolExists();

        // Deploy with CREATE2 for deterministic address
        bytes32 salt = keccak256(abi.encodePacked(token0, token1, stable));
        pool = Clones.cloneDeterministic(implementation, salt);

        IPool(pool).initialize(token0, token1, stable);

        _pools[token0][token1][stable] = pool;
        _pools[token1][token0][stable] = pool;
        _allPools.push(pool);
        _isPool[pool] = true;

        emit PoolCreated(token0, token1, stable, pool, _allPools.length);
    }

    /*//////////////////////////////////////////////////////////////
                          ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPoolFactory
    function setPauseState(bool state) external override {
        if (msg.sender != pauser) revert NotPauser();
        if (isPaused == state) revert SameState();
        isPaused = state;
        emit SetPauseState(state);
    }

    /// @inheritdoc IPoolFactory
    function setPauser(address _pauser) external override onlyOwner {
        if (_pauser == address(0)) revert ZeroAddress();
        pauser = _pauser;
        emit SetPauser(_pauser);
    }

    /// @inheritdoc IPoolFactory
    function setFeeManager(address _feeManager) external override {
        if (msg.sender != feeManager) revert NotFeeManager();
        if (_feeManager == address(0)) revert ZeroAddress();
        feeManager = _feeManager;
        emit SetFeeManager(_feeManager);
    }

    /// @inheritdoc IPoolFactory
    function setVolatileFee(uint256 fee) external override {
        if (msg.sender != feeManager) revert NotFeeManager();
        if (fee > MAX_FEE) revert FeeTooHigh();
        volatileFee = fee;
        emit SetVolatileFee(fee);
    }

    /// @inheritdoc IPoolFactory
    function setStableFee(uint256 fee) external override {
        if (msg.sender != feeManager) revert NotFeeManager();
        if (fee > MAX_FEE) revert FeeTooHigh();
        stableFee = fee;
        emit SetStableFee(fee);
    }

    /// @inheritdoc IPoolFactory
    function setCustomFee(address pool, uint256 fee) external override {
        if (msg.sender != feeManager) revert NotFeeManager();
        if (fee > MAX_FEE && fee != ZERO_FEE_INDICATOR) revert FeeTooHigh();
        if (!_isPool[pool]) revert PoolDoesNotExist();
        _customFee[pool] = fee;
        emit SetCustomFee(pool, fee);
    }

    /// @notice Set the pool implementation
    function setImplementation(address _implementation) external onlyOwner {
        if (_implementation == address(0)) revert ZeroAddress();
        implementation = _implementation;
    }

    /// @notice Set the voter
    function setVoter(address _voter) external onlyOwner {
        voter = _voter;
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
