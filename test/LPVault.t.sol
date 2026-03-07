// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/LPVault.sol";
import "../src/EpochController.sol";
import "../src/SettlementOracle.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockPriceFeed.sol";
import "./mocks/MockLongGammaVault.sol";

contract LPVaultTest is Test {
    MockERC20 public collateral;
    LPVault public lpVault;
    EpochController public controller;
    SettlementOracle public oracle;
    MockPriceFeed public feed;
    MockLongGammaVault public mockLongGammaVault;

    address public owner;
    address public user1;
    uint256 public epochAnchor;

    function setUp() public {
        owner = address(1);
        user1 = address(10);
        epochAnchor = 10 days;
        vm.warp(epochAnchor + 1);

        collateral = new MockERC20("BTC.b", "BTC.b", 8);
        collateral.mint(user1, 1_000_000 * 1e8);

        vm.prank(owner);
        lpVault = new LPVault(owner, address(collateral));

        mockLongGammaVault = new MockLongGammaVault();

        vm.prank(owner);
        oracle = new SettlementOracle(owner);
        feed = new MockPriceFeed();
        feed.setPrice(50_000 * 1e8);
        vm.prank(owner);
        oracle.setPriceFeed(address(feed));
        vm.prank(owner);
        oracle.setKeeper(owner);

        vm.prank(owner);
        controller = new EpochController(owner, epochAnchor);
        vm.prank(owner);
        controller.setOracle(oracle);
        vm.prank(owner);
        controller.setKeeper(owner);
        vm.prank(owner);
        controller.setVaults(mockLongGammaVault, lpVault);

        vm.prank(owner);
        lpVault.setEpochController(address(controller));
        vm.prank(owner);
        lpVault.setLongGammaVault(address(mockLongGammaVault));
    }

    function _warpToDepositWindow() internal {
        vm.warp(epochAnchor);
    }

    function test_deposit_inWindow_success() public {
        _warpToDepositWindow();
        uint256 amount = 100 * 1e8;
        vm.startPrank(user1);
        collateral.approve(address(lpVault), amount);
        lpVault.deposit(amount, user1);
        vm.stopPrank();
        assertEq(lpVault.balanceOf(user1), amount);
        assertEq(collateral.balanceOf(address(lpVault)), amount);
    }

    function test_deposit_outOfWindow_reverts() public {
        vm.warp(epochAnchor - 1);
        vm.prank(user1);
        collateral.approve(address(lpVault), 100 * 1e8);
        vm.prank(user1);
        vm.expectRevert(LPVault.DepositWindowClosed.selector);
        lpVault.deposit(100 * 1e8, user1);
    }

    function test_deposit_noController_reverts() public {
        vm.prank(owner);
        lpVault.setEpochController(address(0));
        vm.prank(user1);
        collateral.approve(address(lpVault), 100 * 1e8);
        vm.prank(user1);
        vm.expectRevert(LPVault.NoController.selector);
        lpVault.deposit(100 * 1e8, user1);
    }

    function test_withdraw_afterSettlement_success() public {
        _warpToDepositWindow();
        uint256 amount = 100 * 1e8;
        vm.startPrank(user1);
        collateral.approve(address(lpVault), amount);
        lpVault.deposit(amount, user1);
        vm.stopPrank();

        vm.prank(owner);
        controller.setKeeper(owner);
        vm.warp(epochAnchor + 1);
        vm.prank(owner);
        controller.startEpoch();
        vm.prank(owner);
        oracle.setSettlementPrice(0, 50_000 * 1e8);
        vm.warp(epochAnchor + 1 days + 1);
        controller.settleEpoch(0);

        vm.prank(owner);
        controller.startEpoch();
        vm.prank(owner);
        oracle.setSettlementPrice(1, 50_000 * 1e8);
        vm.warp(epochAnchor + 2 days + 1);
        controller.settleEpoch(1);

        vm.prank(owner);
        controller.startEpoch();
        vm.prank(owner);
        oracle.setSettlementPrice(2, 50_000 * 1e8);
        vm.warp(epochAnchor + 3 days + 1);
        controller.settleEpoch(2);

        vm.prank(owner);
        controller.startEpoch();
        vm.prank(owner);
        oracle.setSettlementPrice(3, 50_000 * 1e8);
        vm.warp(epochAnchor + 4 days + 1);
        controller.settleEpoch(3);

        uint256 shares = lpVault.balanceOf(user1);
        vm.prank(user1);
        lpVault.withdraw(shares, user1, user1);
        assertEq(lpVault.balanceOf(user1), 0);
        assertEq(collateral.balanceOf(user1), 1_000_000 * 1e8);
    }

    function test_withdraw_beforeSettlement_reverts() public {
        _warpToDepositWindow();
        vm.startPrank(user1);
        collateral.approve(address(lpVault), 100 * 1e8);
        lpVault.deposit(100 * 1e8, user1);
        vm.stopPrank();
        vm.prank(user1);
        vm.expectRevert(LPVault.WithdrawBeforeSettlement.selector);
        lpVault.withdraw(50 * 1e8, user1, user1);
    }

    function test_receivePremium_fromLongGammaVault() public {
        collateral.mint(address(mockLongGammaVault), 50 * 1e8);
        vm.startPrank(address(mockLongGammaVault));
        collateral.approve(address(lpVault), 50 * 1e8);
        lpVault.receivePremium(50 * 1e8);
        vm.stopPrank();
        assertEq(collateral.balanceOf(address(lpVault)), 50 * 1e8);
    }

    function test_receivePremium_unauthorized_reverts() public {
        collateral.mint(user1, 50 * 1e8);
        vm.prank(user1);
        collateral.approve(address(lpVault), 50 * 1e8);
        vm.prank(user1);
        vm.expectRevert(LPVault.OnlyPremiumCaller.selector);
        lpVault.receivePremium(50 * 1e8);
    }

    function test_paySettlement_onlyEpochController() public {
        _warpToDepositWindow();
        vm.startPrank(user1);
        collateral.approve(address(lpVault), 100 * 1e8);
        lpVault.deposit(100 * 1e8, user1);
        vm.stopPrank();
        vm.prank(user1);
        vm.expectRevert(LPVault.OnlyEpochController.selector);
        lpVault.paySettlement(10 * 1e8);
    }

    function test_paySettlement_success() public {
        _warpToDepositWindow();
        vm.startPrank(user1);
        collateral.approve(address(lpVault), 100 * 1e8);
        lpVault.deposit(100 * 1e8, user1);
        vm.stopPrank();
        uint256 pay = 20 * 1e8;
        vm.prank(address(controller));
        lpVault.paySettlement(pay);
        assertEq(collateral.balanceOf(address(mockLongGammaVault)), pay);
        assertEq(collateral.balanceOf(address(lpVault)), 100 * 1e8 - pay);
    }

    function test_roll_noOp() public {
        vm.prank(user1);
        lpVault.roll(100);
    }
}
