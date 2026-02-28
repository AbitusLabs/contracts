// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/EpochController.sol";
import "../src/SettlementOracle.sol";
import "../src/LongGammaVault.sol";
import "../src/LPVault.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockPriceFeed.sol";

contract EpochControllerTest is Test {
    EpochController public controller;
    SettlementOracle public oracle;
    LongGammaVault public longGammaVault;
    LPVault public lpVault;
    MockERC20 public collateral;
    MockPriceFeed public feed;

    address public owner;
    address public keeper;
    uint256 public epochAnchor;

    function setUp() public {
        owner = address(1);
        keeper = address(2);
        epochAnchor = 10 days;
        vm.warp(epochAnchor + 1);

        collateral = new MockERC20("BTC.b", "BTC.b", 8);
        collateral.mint(owner, 1_000_000 * 1e8);

        vm.prank(owner);
        oracle = new SettlementOracle(owner);
        feed = new MockPriceFeed();
        feed.setPrice(50_000 * 1e8);
        vm.prank(owner);
        oracle.setPriceFeed(address(feed));
        vm.prank(owner);
        oracle.setKeeper(keeper);

        vm.prank(owner);
        lpVault = new LPVault(owner, address(collateral));
        vm.prank(owner);
        longGammaVault = new LongGammaVault(owner, address(collateral));
        vm.prank(owner);
        controller = new EpochController(owner, epochAnchor);

        vm.prank(owner);
        controller.setOracle(oracle);
        vm.prank(owner);
        controller.setKeeper(keeper);
        vm.prank(owner);
        controller.setVaults(longGammaVault, lpVault);
        vm.prank(owner);
        longGammaVault.setEpochController(address(controller));
        vm.prank(owner);
        lpVault.setEpochController(address(controller));
        vm.prank(owner);
        lpVault.setLongGammaVault(address(longGammaVault));
    }

    function test_getCurrentEpochId() public {
        vm.warp(epochAnchor);
        assertEq(controller.getCurrentEpochId(), 0);
        vm.warp(epochAnchor + 1 days);
        assertEq(controller.getCurrentEpochId(), 1);
        vm.warp(epochAnchor + 2 days + 1);
        assertEq(controller.getCurrentEpochId(), 2);
    }

    function test_getEpochStartTime() public view {
        assertEq(controller.getEpochStartTime(0), epochAnchor);
        assertEq(controller.getEpochStartTime(1), epochAnchor + 1 days);
    }

    function test_getEpochEndTime() public view {
        assertEq(controller.getEpochEndTime(0), epochAnchor + 1 days);
        assertEq(controller.getEpochEndTime(1), epochAnchor + 2 days);
    }

    function test_longGammaVault_returnsAddress() public view {
        assertEq(controller.longGammaVault(), address(longGammaVault));
    }

    function test_startEpoch_onlyKeeper() public {
        vm.warp(epochAnchor + 1);
        vm.prank(owner);
        vm.expectRevert(EpochController.OnlyKeeper.selector);
        controller.startEpoch();
    }

    function test_startEpoch_success() public {
        vm.warp(epochAnchor + 1);
        vm.prank(keeper);
        controller.startEpoch();
        assertEq(controller.strikeForEpoch(controller.getCurrentEpochId()), 50_000 * 1e8);
    }

    function test_startEpoch_emitsEvent() public {
        vm.warp(epochAnchor + 1);
        uint256 epochId = controller.getCurrentEpochId();
        vm.prank(keeper);
        vm.expectEmit(true, true, true, true);
        emit EpochController.EpochStarted(epochId, 50_000 * 1e8);
        controller.startEpoch();
    }

    function test_startEpoch_beforeEpochStart_reverts() public {
        vm.warp(epochAnchor - 1);
        vm.prank(keeper);
        vm.expectRevert(EpochController.EpochNotStarted.selector);
        controller.startEpoch();
    }

    function test_startEpoch_alreadySet_reverts() public {
        vm.warp(epochAnchor + 1);
        vm.prank(keeper);
        controller.startEpoch();
        vm.prank(keeper);
        vm.expectRevert(EpochController.SettlementAlreadySet.selector);
        controller.startEpoch();
    }

    function test_settleEpoch_beforeEnd_reverts() public {
        vm.warp(epochAnchor + 1);
        vm.prank(keeper);
        controller.startEpoch();
        vm.prank(keeper);
        oracle.setSettlementPrice(0, 52_000 * 1e8);
        vm.warp(epochAnchor + 1 days - 1);
        vm.expectRevert(EpochController.EpochNotEnded.selector);
        controller.settleEpoch(0);
    }

    function test_settleEpoch_success() public {
        vm.warp(epochAnchor - 1);
        vm.startPrank(owner);
        collateral.approve(address(lpVault), 100_000 * 1e8);
        lpVault.deposit(100_000 * 1e8);
        vm.stopPrank();

        vm.warp(epochAnchor + 1);
        vm.prank(keeper);
        controller.startEpoch();
        vm.prank(keeper);
        oracle.setSettlementPrice(0, 52_000 * 1e8);

        vm.warp(epochAnchor + 1 days + 1);
        controller.settleEpoch(0);
        assertTrue(controller.epochSettled(0));
    }

    function test_settleEpoch_payoffCalculation() public {
        vm.warp(epochAnchor - 1);
        vm.startPrank(owner);
        collateral.approve(address(lpVault), 100_000 * 1e8);
        lpVault.deposit(100_000 * 1e8);
        vm.stopPrank();

        vm.warp(epochAnchor + 1);
        vm.prank(keeper);
        controller.startEpoch();
        uint256 strike = 50_000 * 1e8;
        uint256 settlement = 48_000 * 1e8;
        vm.prank(keeper);
        oracle.setSettlementPrice(0, settlement);

        uint256 expectedPayoff = strike - settlement;
        vm.warp(epochAnchor + 1 days + 1);
        vm.expectEmit(true, true, true, true);
        emit EpochController.EpochSettled(0, settlement, expectedPayoff);
        controller.settleEpoch(0);
        assertEq(collateral.balanceOf(address(longGammaVault)), expectedPayoff);
    }

    function test_settleEpoch_withFee() public {
        vm.prank(owner);
        controller.setFeeRecipient(owner);
        vm.prank(owner);
        controller.setFeeBps(100);

        vm.warp(epochAnchor - 1);
        vm.startPrank(owner);
        collateral.approve(address(lpVault), 100_000 * 1e8);
        lpVault.deposit(100_000 * 1e8);
        vm.stopPrank();

        vm.warp(epochAnchor + 1);
        vm.prank(keeper);
        controller.startEpoch();
        vm.prank(keeper);
        oracle.setSettlementPrice(0, 52_000 * 1e8);

        vm.warp(epochAnchor + 1 days + 1);
        controller.settleEpoch(0);
        uint256 payoff = 2_000 * 1e8;
        uint256 afterFee = (payoff * (10000 - 100)) / 10000;
        assertEq(collateral.balanceOf(address(longGammaVault)), afterFee);
    }

    function test_settleEpoch_alreadySettled_reverts() public {
        vm.warp(epochAnchor - 1);
        vm.startPrank(owner);
        collateral.approve(address(lpVault), 100_000 * 1e8);
        lpVault.deposit(100_000 * 1e8);
        vm.stopPrank();

        vm.warp(epochAnchor + 1);
        vm.prank(keeper);
        controller.startEpoch();
        vm.prank(keeper);
        oracle.setSettlementPrice(0, 52_000 * 1e8);
        vm.warp(epochAnchor + 1 days + 1);
        controller.settleEpoch(0);
        vm.expectRevert(EpochController.EpochAlreadySettled.selector);
        controller.settleEpoch(0);
    }

    function test_setVaults_onlyOwner() public {
        vm.prank(keeper);
        vm.expectRevert();
        controller.setVaults(longGammaVault, lpVault);
    }

    function test_setVaults_zero_reverts() public {
        vm.prank(owner);
        vm.expectRevert(EpochController.InvalidVaults.selector);
        controller.setVaults(LongGammaVault(address(0)), lpVault);
    }
}
