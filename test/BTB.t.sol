// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BTB} from "../src/token/BTB.sol";

contract BTBTest is Test {
    BTB public btbImplementation;
    BTB public btb;

    address public owner = address(0x1);
    address public minter = address(0x2);
    address public user = address(0x3);

    function setUp() public {
        // Deploy implementation
        btbImplementation = new BTB();

        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(BTB.initialize.selector, owner, minter);
        ERC1967Proxy proxy = new ERC1967Proxy(address(btbImplementation), initData);
        btb = BTB(address(proxy));
    }

    function test_initialize() public view {
        assertEq(btb.name(), "BTB Finance");
        assertEq(btb.symbol(), "BTB");
        assertEq(btb.owner(), owner);
        assertEq(btb.minter(), minter);
        assertEq(btb.totalSupply(), 0);
    }

    function test_mint_onlyMinter() public {
        // Minter can mint
        vm.prank(minter);
        btb.mint(user, 100 ether);
        assertEq(btb.balanceOf(user), 100 ether);

        // Non-minter cannot mint
        vm.prank(user);
        vm.expectRevert(BTB.NotMinter.selector);
        btb.mint(user, 100 ether);
    }

    function test_mint_maxSupply() public {
        // Mint up to max
        vm.startPrank(minter);
        btb.mint(user, btb.MAX_SUPPLY());
        assertEq(btb.totalSupply(), btb.MAX_SUPPLY());

        // Cannot exceed max
        vm.expectRevert(BTB.MaxSupplyExceeded.selector);
        btb.mint(user, 1);
        vm.stopPrank();
    }

    function test_setMinter_onlyOwner() public {
        address newMinter = address(0x4);

        // Owner can set minter
        vm.prank(owner);
        btb.setMinter(newMinter);
        assertEq(btb.minter(), newMinter);

        // Non-owner cannot
        vm.prank(user);
        vm.expectRevert();
        btb.setMinter(user);
    }

    function test_burn() public {
        vm.prank(minter);
        btb.mint(user, 100 ether);

        vm.prank(user);
        btb.burn(50 ether);
        assertEq(btb.balanceOf(user), 50 ether);
    }

    function test_vote_delegation() public {
        vm.prank(minter);
        btb.mint(user, 100 ether);

        // Self-delegate to activate voting
        vm.prank(user);
        btb.delegate(user);

        assertEq(btb.getVotes(user), 100 ether);
    }

    function testFuzz_mint(address to, uint256 amount) public {
        vm.assume(to != address(0));
        amount = bound(amount, 0, btb.MAX_SUPPLY());

        vm.prank(minter);
        btb.mint(to, amount);
        assertEq(btb.balanceOf(to), amount);
    }
}
