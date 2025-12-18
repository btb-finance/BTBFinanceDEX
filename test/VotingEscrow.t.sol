// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {VotingEscrow} from "../src/governance/VotingEscrow.sol";

/// @dev Simple mock ERC20 for testing
contract MockBTB is ERC20 {
    constructor() ERC20("BTB Finance", "BTB") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract VotingEscrowTest is Test {
    VotingEscrow public veImplementation;
    VotingEscrow public ve;
    MockBTB public btb;

    address public user = address(0x2);
    address public voter = address(0x3);

    uint256 constant WEEK = 7 days;
    uint256 constant MAXTIME = 4 * 365 days;

    function setUp() public {
        // Deploy BTB token
        btb = new MockBTB();

        // Deploy VotingEscrow with proxy
        veImplementation = new VotingEscrow();
        bytes memory initData = abi.encodeWithSelector(VotingEscrow.initialize.selector, address(btb), voter);
        ERC1967Proxy proxy = new ERC1967Proxy(address(veImplementation), initData);
        ve = VotingEscrow(address(proxy));

        // Mint BTB to user
        btb.mint(user, 1_000_000 ether);
    }

    function test_initialize() public view {
        assertEq(ve.name(), "Vote-escrowed BTB");
        assertEq(ve.symbol(), "veBTB");
        assertEq(ve.token(), address(btb));
        assertEq(ve.voter(), voter);
    }

    function test_createLock() public {
        uint256 amount = 100 ether;
        uint256 lockDuration = 365 days; // 1 year

        vm.startPrank(user);
        btb.approve(address(ve), amount);
        uint256 tokenId = ve.createLock(amount, lockDuration);
        vm.stopPrank();

        assertEq(tokenId, 1);
        assertEq(ve.ownerOf(tokenId), user);
        assertEq(ve.supply(), amount);

        // Voting power should be > 0
        uint256 votingPower = ve.balanceOfNFT(tokenId);
        assertTrue(votingPower > 0);
        assertTrue(votingPower <= amount); // Should decay
    }

    function test_increaseAmount() public {
        uint256 initialAmount = 100 ether;
        uint256 additionalAmount = 50 ether;

        vm.startPrank(user);
        btb.approve(address(ve), initialAmount + additionalAmount);
        uint256 tokenId = ve.createLock(initialAmount, 365 days);

        uint256 votingPowerBefore = ve.balanceOfNFT(tokenId);
        ve.increaseAmount(tokenId, additionalAmount);
        uint256 votingPowerAfter = ve.balanceOfNFT(tokenId);
        vm.stopPrank();

        assertTrue(votingPowerAfter > votingPowerBefore);
        assertEq(ve.supply(), initialAmount + additionalAmount);
    }

    function test_withdraw() public {
        uint256 amount = 100 ether;
        uint256 shortLock = 1 weeks;

        vm.startPrank(user);
        btb.approve(address(ve), amount);
        uint256 tokenId = ve.createLock(amount, shortLock);

        // Fast forward past lock expiry
        vm.warp(block.timestamp + shortLock + 1);

        uint256 balanceBefore = btb.balanceOf(user);
        ve.withdraw(tokenId);
        uint256 balanceAfter = btb.balanceOf(user);
        vm.stopPrank();

        assertEq(balanceAfter - balanceBefore, amount);
        assertEq(ve.supply(), 0);
    }

    function test_votingPowerDecays() public {
        uint256 amount = 100 ether;
        uint256 lockDuration = 365 days;

        vm.startPrank(user);
        btb.approve(address(ve), amount);
        uint256 tokenId = ve.createLock(amount, lockDuration);
        vm.stopPrank();

        uint256 powerNow = ve.balanceOfNFT(tokenId);

        // Fast forward 6 months
        vm.warp(block.timestamp + 180 days);
        uint256 powerLater = ve.balanceOfNFT(tokenId);

        assertTrue(powerLater < powerNow); // Power should decay
    }

    function test_maxLock() public {
        uint256 amount = 100 ether;

        vm.startPrank(user);
        btb.approve(address(ve), amount);
        uint256 tokenId = ve.createLock(amount, MAXTIME);
        vm.stopPrank();

        uint256 votingPower = ve.balanceOfNFT(tokenId);
        // Max lock should give approximately 1:1 voting power
        assertTrue(votingPower > amount * 99 / 100);
    }
}
