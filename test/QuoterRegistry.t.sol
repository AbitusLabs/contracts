// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/QuoterRegistry.sol";

contract QuoterRegistryTest is Test {
    QuoterRegistry public registry;
    address public owner;
    address public quoter1;
    address public quoter2;
    address public stranger;

    function setUp() public {
        owner = address(1);
        quoter1 = address(10);
        quoter2 = address(11);
        stranger = address(99);
        vm.prank(owner);
        registry = new QuoterRegistry(owner);
    }

    function test_addQuoter_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        registry.addQuoter(quoter1);
    }

    function test_addQuoter_success() public {
        vm.prank(owner);
        registry.addQuoter(quoter1);
        assertTrue(registry.isQuoter(quoter1));
    }

    function test_addQuoter_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit QuoterRegistry.QuoterAdded(quoter1);
        registry.addQuoter(quoter1);
    }

    function test_addQuoter_alreadyQuoter_reverts() public {
        vm.startPrank(owner);
        registry.addQuoter(quoter1);
        vm.expectRevert("QuoterRegistry: already quoter");
        registry.addQuoter(quoter1);
        vm.stopPrank();
    }

    function test_removeQuoter_onlyOwner() public {
        vm.prank(owner);
        registry.addQuoter(quoter1);
        vm.prank(stranger);
        vm.expectRevert();
        registry.removeQuoter(quoter1);
    }

    function test_removeQuoter_success() public {
        vm.prank(owner);
        registry.addQuoter(quoter1);
        vm.prank(owner);
        registry.removeQuoter(quoter1);
        assertFalse(registry.isQuoter(quoter1));
    }

    function test_removeQuoter_notQuoter_reverts() public {
        vm.prank(owner);
        vm.expectRevert("QuoterRegistry: not quoter");
        registry.removeQuoter(quoter1);
    }

    function test_isQuoter_view() public {
        assertFalse(registry.isQuoter(quoter1));
        vm.prank(owner);
        registry.addQuoter(quoter1);
        assertTrue(registry.isQuoter(quoter1));
        vm.prank(owner);
        registry.addQuoter(quoter2);
        assertTrue(registry.isQuoter(quoter2));
    }
}
