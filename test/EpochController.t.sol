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

    uint256 constant STRIKE = 50_000 * 1e8;

    function warpIntoEpoch(uint256 id) internal {
        vm.warp(epochAnchor + id * 1 days + 1);
    }

    function warpAfterEpoch(uint256 id) internal {
        vm.warp(epochAnchor + (id + 1) * 1 days + 1);
    }

    function fundLP(uint256 amount) internal {
        vm.startPrank(owner);
        collateral.approve(address(lpVault), amount);
        lpVault.deposit(amount, owner);
        vm.stopPrank();
    }

    function setUp() public {
        owner = address(1);
        keeper = address(2);

        epochAnchor = 10 days;

        collateral = new MockERC20("BTC.b", "BTC.b", 8);
        collateral.mint(owner, 1_000_000 * 1e8);

        oracle = new SettlementOracle(owner);

        feed = new MockPriceFeed();
        feed.setPrice(int256(STRIKE));

        vm.prank(owner);
        oracle.setPriceFeed(address(feed));

        vm.prank(owner);
        oracle.setKeeper(keeper);

        lpVault = new LPVault(owner, address(collateral));
        longGammaVault = new LongGammaVault(owner, address(collateral));
        controller = new EpochController(owner, epochAnchor);

        vm.startPrank(owner);

        controller.setOracle(oracle);
        controller.setKeeper(keeper);
        controller.setVaults(longGammaVault, lpVault);

        longGammaVault.setEpochController(address(controller));

        lpVault.setEpochController(address(controller));
        lpVault.setLongGammaVault(address(longGammaVault));

        vm.stopPrank();
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
        warpIntoEpoch(0);

        vm.prank(owner);
        vm.expectRevert(EpochController.OnlyKeeper.selector);

        controller.startEpoch();
    }

    function test_startEpoch_success() public {
        warpIntoEpoch(0);

        vm.prank(keeper);
        controller.startEpoch();

        assertEq(controller.strikeForEpoch(0), STRIKE);
    }

    function test_startEpoch_emitsEvent() public {
        warpIntoEpoch(0);

        vm.expectEmit(true, true, true, true);
        emit EpochController.EpochStarted(0, STRIKE);

        vm.prank(keeper);
        controller.startEpoch();
    }

    function test_startEpoch_beforeEpochStart_reverts() public {
        vm.warp(epochAnchor - 1);

        vm.prank(keeper);
        vm.expectRevert(EpochController.EpochNotStarted.selector);

        controller.startEpoch();
    }

    function test_startEpoch_alreadySet_reverts() public {
        warpIntoEpoch(0);

        vm.prank(keeper);
        controller.startEpoch();

        vm.prank(keeper);
        vm.expectRevert(EpochController.SettlementAlreadySet.selector);

        controller.startEpoch();
    }

    /*//////////////////////////////////////////////////////////////
                             SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    function test_settleEpoch_beforeEnd_reverts() public {
        warpIntoEpoch(0);

        vm.prank(keeper);
        controller.startEpoch();

        vm.prank(keeper);
        oracle.setSettlementPrice(0, 52_000 * 1e8);

        vm.expectRevert(EpochController.EpochNotEnded.selector);

        controller.settleEpoch(0);
    }

    function test_settleEpoch_success() public {
        warpIntoEpoch(0);

        fundLP(100_000 * 1e8);

        vm.prank(keeper);
        controller.startEpoch();

        vm.prank(keeper);
        oracle.setSettlementPrice(0, 52_000 * 1e8);

        warpAfterEpoch(0);

        controller.settleEpoch(0);

        assertTrue(controller.epochSettled(0));
    }

    function test_settleEpoch_payoffCalculation() public {
        warpIntoEpoch(0);

        fundLP(100_000 * 1e8);

        vm.prank(keeper);
        controller.startEpoch();

        uint256 settlement = 48_000 * 1e8;

        vm.prank(keeper);
        oracle.setSettlementPrice(0, settlement);

        uint256 expectedPayoff = STRIKE - settlement;

        vm.expectEmit(true, true, true, true);
        emit EpochController.EpochSettled(0, settlement, expectedPayoff);

        warpAfterEpoch(0);

        controller.settleEpoch(0);

        assertEq(collateral.balanceOf(address(longGammaVault)), expectedPayoff);
    }

    function test_settleEpoch_withFee() public {
        vm.prank(owner);
        controller.setFeeRecipient(owner);

        vm.prank(owner);
        controller.setFeeBps(100);

        warpIntoEpoch(0);

        fundLP(100_000 * 1e8);

        vm.prank(keeper);
        controller.startEpoch();

        vm.prank(keeper);
        oracle.setSettlementPrice(0, 52_000 * 1e8);

        warpAfterEpoch(0);

        controller.settleEpoch(0);

        uint256 payoff = 2_000 * 1e8;
        uint256 afterFee = (payoff * 9900) / 10000;

        assertEq(collateral.balanceOf(address(longGammaVault)), afterFee);
    }

    function test_settleEpoch_alreadySettled_reverts() public {
        warpIntoEpoch(0);

        fundLP(100_000 * 1e8);

        vm.prank(keeper);
        controller.startEpoch();

        vm.prank(keeper);
        oracle.setSettlementPrice(0, 52_000 * 1e8);

        warpAfterEpoch(0);

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
