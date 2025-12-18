// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ICLFactory} from "../interfaces/ICLFactory.sol";
import {CLPool} from "./CLPool.sol";

/// @title BTB Finance CL Factory
/// @author BTB Finance
/// @notice Factory for deploying Concentrated Liquidity pools
/// @dev Uses CREATE2 with Clones for deterministic addresses. UUPS upgradeable.
contract CLFactory is ICLFactory, OwnableUpgradeable, UUPSUpgradeable {
    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICLFactory
    address public override implementation;

    /// @dev token0 => token1 => tickSpacing => pool
    mapping(address => mapping(address => mapping(int24 => address))) internal _pools;

    /// @dev All pools array
    address[] internal _allPools;

    /// @dev Is valid pool
    mapping(address => bool) internal _isPool;

    /// @inheritdoc ICLFactory
    mapping(int24 => uint24) public override tickSpacingToFee;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                              INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialize the factory
    /// @param _implementation CLPool implementation address
    function initialize(address _implementation) external initializer {
        if (_implementation == address(0)) revert ZeroAddress();

        __Ownable_init(msg.sender);

        implementation = _implementation;

        // Default tick spacings and fees
        // 1 = 0.01% (stablecoins)
        // 10 = 0.05% (most pairs)
        // 60 = 0.30% (volatile)
        // 200 = 1.00% (exotic)
        tickSpacingToFee[1] = 100;      // 0.01%
        tickSpacingToFee[10] = 500;     // 0.05%
        tickSpacingToFee[60] = 3000;    // 0.30%
        tickSpacingToFee[200] = 10000;  // 1.00%
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICLFactory
    function owner() public view override(ICLFactory, OwnableUpgradeable) returns (address) {
        return OwnableUpgradeable.owner();
    }

    /// @inheritdoc ICLFactory
    function allPoolsLength() external view override returns (uint256) {
        return _allPools.length;
    }

    /// @inheritdoc ICLFactory
    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view override returns (address) {
        (address token0, address token1) = _sortTokens(tokenA, tokenB);
        return _pools[token0][token1][tickSpacing];
    }

    /// @inheritdoc ICLFactory
    function isPool(address pool) external view override returns (bool) {
        return _isPool[pool];
    }

    /*//////////////////////////////////////////////////////////////
                           POOL CREATION
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICLFactory
    function createPool(address tokenA, address tokenB, int24 tickSpacing, uint160 sqrtPriceX96)
        external
        override
        returns (address pool)
    {
        if (tokenA == tokenB) revert IdenticalAddresses();
        (address token0, address token1) = _sortTokens(tokenA, tokenB);
        if (token0 == address(0)) revert ZeroAddress();
        if (_pools[token0][token1][tickSpacing] != address(0)) revert PoolExists();
        
        uint24 fee = tickSpacingToFee[tickSpacing];
        if (fee == 0) revert InvalidTickSpacing();

        // Deploy with CREATE2 for deterministic address
        bytes32 salt = keccak256(abi.encodePacked(token0, token1, tickSpacing));
        pool = Clones.cloneDeterministic(implementation, salt);

        // Initialize the pool
        CLPool(pool).initializePool(address(this), token0, token1, tickSpacing, fee);
        CLPool(pool).initialize(sqrtPriceX96);

        _pools[token0][token1][tickSpacing] = pool;
        _pools[token1][token0][tickSpacing] = pool;
        _allPools.push(pool);
        _isPool[pool] = true;

        emit PoolCreated(token0, token1, tickSpacing, pool, _allPools.length);
    }

    /*//////////////////////////////////////////////////////////////
                          ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICLFactory
    function setOwner(address newOwner) external override {
        if (msg.sender != owner()) revert NotOwner();
        if (newOwner == address(0)) revert ZeroAddress();
        _transferOwnership(newOwner);
        emit OwnerChanged(msg.sender, newOwner);
    }

    /// @inheritdoc ICLFactory
    function enableTickSpacing(int24 tickSpacing, uint24 fee) external override onlyOwner {
        if (tickSpacingToFee[tickSpacing] != 0) revert InvalidTickSpacing();
        tickSpacingToFee[tickSpacing] = fee;
        emit TickSpacingEnabled(tickSpacing, fee);
    }

    /// @notice Set the pool implementation
    function setImplementation(address _implementation) external onlyOwner {
        if (_implementation == address(0)) revert ZeroAddress();
        implementation = _implementation;
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
