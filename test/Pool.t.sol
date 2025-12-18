// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Pool} from "../src/core/Pool.sol";
import {PoolFactory} from "../src/core/PoolFactory.sol";

/// @dev Simple mock ERC20 for testing
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PoolTest is Test {
    PoolFactory public factoryImplementation;
    PoolFactory public factory;
    Pool public poolImplementation;

    MockERC20 public tokenA;
    MockERC20 public tokenB;

    address public owner = address(0x1);
    address public user = address(0x2);

    function setUp() public {
        // Deploy tokens
        tokenA = new MockERC20("Token A", "TKNA");
        tokenB = new MockERC20("Token B", "TKNB");

        // Ensure tokenA < tokenB
        if (address(tokenA) > address(tokenB)) {
            (tokenA, tokenB) = (tokenB, tokenA);
        }

        // Deploy pool implementation
        poolImplementation = new Pool();

        // Deploy factory with proxy
        factoryImplementation = new PoolFactory();
        bytes memory initData =
            abi.encodeWithSelector(PoolFactory.initialize.selector, address(poolImplementation), address(0));
        ERC1967Proxy proxy = new ERC1967Proxy(address(factoryImplementation), initData);
        factory = PoolFactory(address(proxy));

        // Mint tokens to user
        tokenA.mint(user, 1_000_000 ether);
        tokenB.mint(user, 1_000_000 ether);
    }

    function test_createPool() public {
        address pool = factory.createPool(address(tokenA), address(tokenB), false);
        assertTrue(pool != address(0));
        assertTrue(factory.isPool(pool));
        assertEq(factory.getPool(address(tokenA), address(tokenB), false), pool);
    }

    function test_createPool_stable() public {
        address pool = factory.createPool(address(tokenA), address(tokenB), true);
        assertTrue(pool != address(0));
        assertTrue(Pool(pool).stable());
    }

    function test_addLiquidity() public {
        address poolAddr = factory.createPool(address(tokenA), address(tokenB), false);
        Pool pool = Pool(poolAddr);

        uint256 amountA = 100 ether;
        uint256 amountB = 200 ether;

        vm.startPrank(user);
        tokenA.transfer(poolAddr, amountA);
        tokenB.transfer(poolAddr, amountB);
        uint256 liquidity = pool.mint(user);
        vm.stopPrank();

        assertTrue(liquidity > 0);
        assertEq(pool.balanceOf(user), liquidity);

        (uint112 reserve0, uint112 reserve1,) = pool.getReserves();
        assertEq(reserve0, amountA);
        assertEq(reserve1, amountB);
    }

    function test_swap() public {
        // Setup pool with liquidity
        address poolAddr = factory.createPool(address(tokenA), address(tokenB), false);
        Pool pool = Pool(poolAddr);

        vm.startPrank(user);
        tokenA.transfer(poolAddr, 100 ether);
        tokenB.transfer(poolAddr, 100 ether);
        pool.mint(user);

        // Swap A for B
        uint256 swapAmount = 10 ether;
        uint256 expectedOut = pool.getAmountOut(swapAmount, address(tokenA));

        uint256 balanceBBefore = tokenB.balanceOf(user);
        tokenA.transfer(poolAddr, swapAmount);
        pool.swap(0, expectedOut, user, "");
        uint256 balanceBAfter = tokenB.balanceOf(user);

        assertEq(balanceBAfter - balanceBBefore, expectedOut);
        vm.stopPrank();
    }

    function test_removeLiquidity() public {
        address poolAddr = factory.createPool(address(tokenA), address(tokenB), false);
        Pool pool = Pool(poolAddr);

        vm.startPrank(user);
        tokenA.transfer(poolAddr, 100 ether);
        tokenB.transfer(poolAddr, 100 ether);
        uint256 liquidity = pool.mint(user);

        // Remove half
        uint256 toRemove = liquidity / 2;
        pool.transfer(poolAddr, toRemove);
        (uint256 amount0, uint256 amount1) = pool.burn(user);

        assertTrue(amount0 > 0);
        assertTrue(amount1 > 0);
        vm.stopPrank();
    }
}
