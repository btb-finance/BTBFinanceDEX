// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CLPool} from "../src/core/CLPool.sol";
import {CLFactory} from "../src/core/CLFactory.sol";
import {TickMath} from "../src/libraries/TickMath.sol";

/// @dev Simple mock ERC20 for testing
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract CLPoolTest is Test {
    CLFactory public factoryImplementation;
    CLFactory public factory;
    CLPool public poolImplementation;

    MockERC20 public tokenA;
    MockERC20 public tokenB;

    address public owner = address(this);
    address public user = address(0x2);

    // Common tick spacing
    int24 public constant TICK_SPACING = 60;

    // Initial price: 1:1
    uint160 public initialSqrtPrice;

    function setUp() public {
        // Deploy tokens
        tokenA = new MockERC20("Token A", "TKNA");
        tokenB = new MockERC20("Token B", "TKNB");

        // Ensure tokenA < tokenB
        if (address(tokenA) > address(tokenB)) {
            (tokenA, tokenB) = (tokenB, tokenA);
        }

        // Deploy pool implementation
        poolImplementation = new CLPool();

        // Deploy factory with proxy
        factoryImplementation = new CLFactory();
        bytes memory initData = abi.encodeWithSelector(CLFactory.initialize.selector, address(poolImplementation));
        ERC1967Proxy proxy = new ERC1967Proxy(address(factoryImplementation), initData);
        factory = CLFactory(address(proxy));

        // Mint tokens to user
        tokenA.mint(user, 1_000_000 ether);
        tokenB.mint(user, 1_000_000 ether);

        // Initial sqrt price (1:1 = tick 0)
        initialSqrtPrice = TickMath.getSqrtRatioAtTick(0);
    }

    function test_createPool() public {
        address pool = factory.createPool(address(tokenA), address(tokenB), TICK_SPACING, initialSqrtPrice);
        assertTrue(pool != address(0));
        assertTrue(factory.isPool(pool));
        assertEq(factory.getPool(address(tokenA), address(tokenB), TICK_SPACING), pool);
    }

    function test_poolInitialization() public {
        address poolAddr = factory.createPool(address(tokenA), address(tokenB), TICK_SPACING, initialSqrtPrice);
        CLPool pool = CLPool(poolAddr);

        assertEq(pool.token0(), address(tokenA));
        assertEq(pool.token1(), address(tokenB));
        assertEq(pool.tickSpacing(), TICK_SPACING);
        assertEq(pool.fee(), 3000); // 0.30%

        (uint160 sqrtPriceX96, int24 tick, bool unlocked) = pool.slot0();
        assertEq(sqrtPriceX96, initialSqrtPrice);
        assertEq(tick, 0);
        assertTrue(unlocked);
    }

    function test_mint() public {
        address poolAddr = factory.createPool(address(tokenA), address(tokenB), TICK_SPACING, initialSqrtPrice);
        CLPool pool = CLPool(poolAddr);

        // Mint liquidity in a range
        int24 tickLower = -TICK_SPACING * 10;
        int24 tickUpper = TICK_SPACING * 10;
        uint128 liquidityAmount = 1_000_000;

        vm.startPrank(user);
        tokenA.approve(poolAddr, type(uint256).max);
        tokenB.approve(poolAddr, type(uint256).max);

        (uint256 amount0, uint256 amount1) = pool.mint(user, tickLower, tickUpper, liquidityAmount, "");
        vm.stopPrank();

        assertTrue(amount0 > 0 || amount1 > 0);
        assertEq(pool.liquidity(), liquidityAmount);
    }

    function test_burn() public {
        address poolAddr = factory.createPool(address(tokenA), address(tokenB), TICK_SPACING, initialSqrtPrice);
        CLPool pool = CLPool(poolAddr);

        int24 tickLower = -TICK_SPACING * 10;
        int24 tickUpper = TICK_SPACING * 10;
        uint128 liquidityAmount = 1_000_000;

        vm.startPrank(user);
        tokenA.approve(poolAddr, type(uint256).max);
        tokenB.approve(poolAddr, type(uint256).max);

        pool.mint(user, tickLower, tickUpper, liquidityAmount, "");

        // Burn half
        (uint256 amount0, uint256 amount1) = pool.burn(tickLower, tickUpper, liquidityAmount / 2);
        vm.stopPrank();

        assertTrue(amount0 > 0 || amount1 > 0);
        assertEq(pool.liquidity(), liquidityAmount / 2);
    }

    function test_swap() public {
        address poolAddr = factory.createPool(address(tokenA), address(tokenB), TICK_SPACING, initialSqrtPrice);
        CLPool pool = CLPool(poolAddr);

        // First add substantial liquidity
        int24 tickLower = -TICK_SPACING * 100;
        int24 tickUpper = TICK_SPACING * 100;
        uint128 liquidityAmount = 10_000_000_000_000_000_000; // 10e18

        vm.startPrank(user);
        tokenA.approve(poolAddr, type(uint256).max);
        tokenB.approve(poolAddr, type(uint256).max);

        pool.mint(user, tickLower, tickUpper, liquidityAmount, "");

        // Swap a small amount of token0 for token1
        uint256 balanceBBefore = tokenB.balanceOf(user);
        int256 amountIn = 0.01 ether; // Small swap

        (int256 amount0, int256 amount1) = pool.swap(
            user,
            true, // zeroForOne
            amountIn,
            TickMath.MIN_SQRT_RATIO + 1,
            ""
        );

        uint256 balanceBAfter = tokenB.balanceOf(user);
        vm.stopPrank();

        assertGt(amount0, 0); // We sent token0
        assertLt(amount1, 0); // We received token1
        assertGt(balanceBAfter, balanceBBefore);
    }

    function test_tickMath() public pure {
        // Test tick 0 = 1:1 price
        uint160 sqrtPrice = TickMath.getSqrtRatioAtTick(0);
        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPrice);
        assertEq(tick, 0);

        // Test positive tick
        sqrtPrice = TickMath.getSqrtRatioAtTick(1000);
        tick = TickMath.getTickAtSqrtRatio(sqrtPrice);
        assertEq(tick, 1000);

        // Test negative tick
        sqrtPrice = TickMath.getSqrtRatioAtTick(-1000);
        tick = TickMath.getTickAtSqrtRatio(sqrtPrice);
        assertEq(tick, -1000);
    }
}
