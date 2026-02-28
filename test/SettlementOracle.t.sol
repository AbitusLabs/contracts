// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/SettlementOracle.sol";
import "./mocks/MockPriceFeed.sol";

contract SettlementOracleTest is Test {
    SettlementOracle public oracle;
    MockPriceFeed public feed;
    address public owner;
    address public keeper;
    address public stranger;

    function setUp() public {
        owner = address(1);
        keeper = address(2);
        stranger = address(99);
        vm.prank(owner);
        oracle = new SettlementOracle(owner);
        feed = new MockPriceFeed();
        feed.setPrice(50_000 * 1e8);
        vm.prank(owner);
        oracle.setPriceFeed(address(feed));
        vm.prank(owner);
        oracle.setKeeper(keeper);
    }

    function test_getCurrentPrice_returnsFeedPrice() public view {
        uint256 price = oracle.getCurrentPrice();
        assertEq(price, 50_000 * 1e8);
    }

    function test_getCurrentPrice_updatesWhenFeedChanges() public {
        feed.setPrice(60_000 * 1e8);
        assertEq(oracle.getCurrentPrice(), 60_000 * 1e8);
    }

    function test_setSettlementPrice_onlyKeeper() public {
        vm.prank(stranger);
        vm.expectRevert(SettlementOracle.OnlyKeeper.selector);
        oracle.setSettlementPrice(1, 50_000 * 1e8);
    }

    function test_setSettlementPrice_success() public {
        vm.prank(keeper);
        oracle.setSettlementPrice(1, 52_000 * 1e8);
        assertEq(oracle.settlementPrice(1), 52_000 * 1e8);
    }

    function test_setSettlementPrice_emitsEvent() public {
        vm.prank(keeper);
        vm.expectEmit(true, true, true, true);
        emit SettlementOracle.SettlementPriceSet(1, 52_000 * 1e8);
        oracle.setSettlementPrice(1, 52_000 * 1e8);
    }

    function test_setSettlementPrice_alreadySet_reverts() public {
        vm.prank(keeper);
        oracle.setSettlementPrice(1, 50_000 * 1e8);
        vm.prank(keeper);
        vm.expectRevert(SettlementOracle.PriceAlreadySet.selector);
        oracle.setSettlementPrice(1, 51_000 * 1e8);
    }

    function test_setSettlementPrice_zero_reverts() public {
        vm.prank(keeper);
        vm.expectRevert(SettlementOracle.InvalidPrice.selector);
        oracle.setSettlementPrice(1, 0);
    }

    function test_getSettlementPrice_returnsWhenSet() public {
        vm.prank(keeper);
        oracle.setSettlementPrice(1, 55_000 * 1e8);
        assertEq(oracle.getSettlementPrice(1), 55_000 * 1e8);
    }

    function test_getSettlementPrice_notSet_reverts() public {
        vm.expectRevert("SettlementOracle: price not set");
        oracle.getSettlementPrice(1);
    }

    function test_setPriceFeed_onlyOwner() public {
        MockPriceFeed newFeed = new MockPriceFeed();
        vm.prank(stranger);
        vm.expectRevert();
        oracle.setPriceFeed(address(newFeed));
    }

    function test_setKeeper_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        oracle.setKeeper(stranger);
    }

    function test_feedNegativePrice_reverts() public {
        feed.setPrice(-1);
        vm.expectRevert("SettlementOracle: invalid feed");
        oracle.getCurrentPrice();
    }
}
