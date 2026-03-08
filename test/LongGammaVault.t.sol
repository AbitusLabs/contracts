// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/LongGammaVault.sol";
import "../src/QuoterRegistry.sol";
import "../src/LPVault.sol";
import "../src/EpochController.sol";
import "../src/SettlementOracle.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockPriceFeed.sol";
import "./QuoteDigestHelper.sol";

contract LongGammaVaultTest is Test {
    MockERC20 public collateral;
    LongGammaVault public longGammaVault;
    LPVault public lpVault;
    QuoterRegistry public quoterRegistry;
    EpochController public controller;
    SettlementOracle public oracle;
    MockPriceFeed public feed;
    QuoteDigestHelper public digestHelper;

    address public owner;
    address public user1;
    uint256 public quoterPk;
    address public quoter;
    uint256 public epochAnchor;

    function setUp() public {
        owner = address(1);
        user1 = address(10);
        quoterPk = 0xA11CE;
        quoter = vm.addr(quoterPk);
        epochAnchor = 10 days;
        vm.warp(epochAnchor + 1);

        collateral = new MockERC20("BTC.b", "BTC.b", 8);
        collateral.mint(user1, 1_000_000 * 1e8);

        vm.prank(owner);
        quoterRegistry = new QuoterRegistry(owner);
        vm.prank(owner);
        quoterRegistry.addQuoter(quoter);

        vm.prank(owner);
        lpVault = new LPVault(owner, address(collateral));
        vm.prank(owner);
        longGammaVault = new LongGammaVault(owner, address(collateral));

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
        controller.setVaults(longGammaVault, lpVault);

        vm.prank(owner);
        longGammaVault.setEpochController(address(controller));
        vm.prank(owner);
        longGammaVault.setQuoterRegistry(address(quoterRegistry));
        vm.prank(owner);
        longGammaVault.setLPVault(address(lpVault));
        vm.prank(owner);
        longGammaVault.setCap(500_000 * 1e8);
        vm.prank(owner);
        lpVault.setEpochController(address(controller));
        vm.prank(owner);
        lpVault.setLongGammaVault(address(longGammaVault));

        digestHelper = new QuoteDigestHelper();
    }

    function _warpToDepositWindow() internal {
        vm.warp(epochAnchor);
    }

    function _signQuote(uint256 epochId, uint256 notional, uint256 premium, uint256 expiry)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest =
            digestHelper.getDigest(address(longGammaVault), block.chainid, epochId, notional, premium, expiry);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(quoterPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_deposit_validQuote_success() public {
        _warpToDepositWindow();
        uint256 epochId = controller.getCurrentEpochId();
        uint256 amount = 100 * 1e8;
        uint256 premium = 5 * 1e8;
        ILongGammaVault.Quote memory quote = ILongGammaVault.Quote({
            epochId: epochId, notional: amount, premium: premium, expiry: block.timestamp + 1 hours
        });
        bytes memory sig = _signQuote(quote.epochId, quote.notional, quote.premium, quote.expiry);

        vm.startPrank(user1);
        collateral.approve(address(longGammaVault), amount);
        longGammaVault.depositWithQuote(amount, user1, quote, sig);
        vm.stopPrank();

        assertEq(longGammaVault.balanceOf(user1), amount - premium);
        assertEq(longGammaVault.totalDepositsCurrentEpoch(), amount);
        assertEq(collateral.balanceOf(address(lpVault)), premium);
    }

    function test_deposit_invalidQuoter_reverts() public {
        _warpToDepositWindow();
        uint256 epochId = controller.getCurrentEpochId();
        uint256 amount = 100 * 1e8;
        uint256 premium = 5 * 1e8;
        vm.prank(owner);
        quoterRegistry.removeQuoter(quoter);
        ILongGammaVault.Quote memory quote = ILongGammaVault.Quote({
            epochId: epochId, notional: amount, premium: premium, expiry: block.timestamp + 1 hours
        });
        bytes memory sig = _signQuote(quote.epochId, quote.notional, quote.premium, quote.expiry);
        vm.prank(user1);
        collateral.approve(address(longGammaVault), amount);
        vm.prank(user1);
        vm.expectRevert(LongGammaVault.InvalidQuote.selector);
        longGammaVault.depositWithQuote(amount, user1, quote, sig);
    }

    function test_deposit_wrongEpoch_reverts() public {
        _warpToDepositWindow();
        uint256 wrongEpoch = controller.getCurrentEpochId() + 1;
        ILongGammaVault.Quote memory quote = ILongGammaVault.Quote({
            epochId: wrongEpoch, notional: 100 * 1e8, premium: 5 * 1e8, expiry: block.timestamp + 1 hours
        });
        bytes memory sig = _signQuote(quote.epochId, quote.notional, quote.premium, quote.expiry);
        vm.prank(user1);
        collateral.approve(address(longGammaVault), 100 * 1e8);
        vm.prank(user1);
        vm.expectRevert(LongGammaVault.InvalidQuote.selector);
        longGammaVault.depositWithQuote(100 * 1e8, user1, quote, sig);
    }

    function test_deposit_capExceeded_reverts() public {
        _warpToDepositWindow();
        vm.prank(owner);
        longGammaVault.setCap(50 * 1e8);
        uint256 epochId = controller.getCurrentEpochId();
        ILongGammaVault.Quote memory quote = ILongGammaVault.Quote({
            epochId: epochId, notional: 100 * 1e8, premium: 5 * 1e8, expiry: block.timestamp + 1 hours
        });
        bytes memory sig = _signQuote(quote.epochId, quote.notional, quote.premium, quote.expiry);
        vm.prank(user1);
        collateral.approve(address(longGammaVault), 100 * 1e8);
        vm.prank(user1);
        vm.expectRevert(LongGammaVault.CapExceeded.selector);
        longGammaVault.depositWithQuote(100 * 1e8, user1, quote, sig);
    }

    function test_deposit_windowClosed_reverts() public {
        _warpToDepositWindow();
        vm.prank(owner);
        controller.startEpoch();
        uint256 epochId = controller.getCurrentEpochId();
        ILongGammaVault.Quote memory quote = ILongGammaVault.Quote({
            epochId: epochId, notional: 100 * 1e8, premium: 5 * 1e8, expiry: block.timestamp + 1 hours
        });
        bytes memory sig = _signQuote(quote.epochId, quote.notional, quote.premium, quote.expiry);
        vm.prank(user1);
        collateral.approve(address(longGammaVault), 100 * 1e8);
        vm.prank(user1);
        vm.expectRevert(LongGammaVault.DepositWindowClosed.selector);
        longGammaVault.depositWithQuote(100 * 1e8, user1, quote, sig);
    }

    function test_receiveSettlement_onlyController() public {
        vm.prank(user1);
        vm.expectRevert(LongGammaVault.OnlyEpochController.selector);
        longGammaVault.receiveSettlement(100 * 1e8);
    }

    function test_onEpochStarted_resetsTotalDeposits() public {
        _warpToDepositWindow();
        uint256 epochId = controller.getCurrentEpochId();
        ILongGammaVault.Quote memory quote = ILongGammaVault.Quote({
            epochId: epochId, notional: 100 * 1e8, premium: 5 * 1e8, expiry: block.timestamp + 1 hours
        });
        bytes memory sig = _signQuote(quote.epochId, quote.notional, quote.premium, quote.expiry);
        vm.startPrank(user1);
        collateral.approve(address(longGammaVault), 100 * 1e8);
        longGammaVault.depositWithQuote(100 * 1e8, user1, quote, sig);
        vm.stopPrank();
        assertEq(longGammaVault.totalDepositsCurrentEpoch(), 100 * 1e8);

        vm.warp(epochAnchor + 1);
        vm.prank(owner);
        controller.startEpoch();
        assertEq(longGammaVault.totalDepositsCurrentEpoch(), 0);
    }

    function test_redeem_afterSettlement_success() public {
        _warpToDepositWindow();
        vm.startPrank(user1);
        collateral.approve(address(lpVault), 500 * 1e8);
        lpVault.deposit(500 * 1e8, user1);
        vm.stopPrank();

        uint256 epochId = controller.getCurrentEpochId();
        uint256 amount = 100 * 1e8;
        uint256 premium = 10 * 1e8;
        ILongGammaVault.Quote memory quote = ILongGammaVault.Quote({
            epochId: epochId, notional: amount, premium: premium, expiry: block.timestamp + 1 hours
        });
        bytes memory sig = _signQuote(quote.epochId, quote.notional, quote.premium, quote.expiry);
        vm.startPrank(user1);
        collateral.approve(address(longGammaVault), amount);
        longGammaVault.depositWithQuote(amount, user1, quote, sig);
        vm.stopPrank();

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
        oracle.setSettlementPrice(2, 50_500 * 1e8);
        vm.warp(epochAnchor + 3 days + 1);
        controller.settleEpoch(2);

        vm.prank(owner);
        controller.startEpoch();
        vm.prank(owner);
        oracle.setSettlementPrice(3, 50_000 * 1e8);
        vm.warp(epochAnchor + 4 days + 1);
        controller.settleEpoch(3);

        uint256 shares = longGammaVault.balanceOf(user1);
        vm.prank(user1);
        longGammaVault.redeem(shares, user1, user1);
        assertEq(longGammaVault.balanceOf(user1), 0);
    }

    function test_withdraw_afterSettlement_success() public {
        _warpToDepositWindow();
        vm.startPrank(user1);
        collateral.approve(address(lpVault), 500 * 1e8);
        lpVault.deposit(500 * 1e8, user1);
        vm.stopPrank();

        uint256 epochId = controller.getCurrentEpochId();
        uint256 amount = 100 * 1e8;
        uint256 premium = 10 * 1e8;
        ILongGammaVault.Quote memory quote = ILongGammaVault.Quote({
            epochId: epochId, notional: amount, premium: premium, expiry: block.timestamp + 1 hours
        });
        bytes memory sig = _signQuote(quote.epochId, quote.notional, quote.premium, quote.expiry);
        vm.startPrank(user1);
        collateral.approve(address(longGammaVault), amount);
        longGammaVault.depositWithQuote(amount, user1, quote, sig);
        vm.stopPrank();

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
        oracle.setSettlementPrice(2, 50_500 * 1e8);
        vm.warp(epochAnchor + 3 days + 1);
        controller.settleEpoch(2);

        vm.prank(owner);
        controller.startEpoch();
        vm.prank(owner);
        oracle.setSettlementPrice(3, 50_000 * 1e8);
        vm.warp(epochAnchor + 4 days + 1);
        controller.settleEpoch(3);

        uint256 shares = longGammaVault.balanceOf(user1);
        uint256 assets = longGammaVault.previewRedeem(shares);
        vm.prank(user1);
        longGammaVault.withdraw(assets, user1, user1);
        assertEq(longGammaVault.balanceOf(user1), 0);
    }

    function test_withdraw_beforeSettlement_reverts() public {
        _warpToDepositWindow();
        uint256 epochId = controller.getCurrentEpochId();
        ILongGammaVault.Quote memory quote = ILongGammaVault.Quote({
            epochId: epochId, notional: 100 * 1e8, premium: 5 * 1e8, expiry: block.timestamp + 1 hours
        });
        bytes memory sig = _signQuote(quote.epochId, quote.notional, quote.premium, quote.expiry);
        vm.startPrank(user1);
        collateral.approve(address(longGammaVault), 100 * 1e8);
        longGammaVault.depositWithQuote(100 * 1e8, user1, quote, sig);
        vm.stopPrank();
        vm.prank(user1);
        vm.expectRevert(LongGammaVault.WithdrawBeforeSettlement.selector);
        longGammaVault.withdraw(50 * 1e8, user1, user1);
    }

    function test_redeem_beforeSettlement_reverts() public {
        _warpToDepositWindow();
        uint256 epochId = controller.getCurrentEpochId();
        ILongGammaVault.Quote memory quote = ILongGammaVault.Quote({
            epochId: epochId, notional: 100 * 1e8, premium: 5 * 1e8, expiry: block.timestamp + 1 hours
        });
        bytes memory sig = _signQuote(quote.epochId, quote.notional, quote.premium, quote.expiry);
        vm.startPrank(user1);
        collateral.approve(address(longGammaVault), 100 * 1e8);
        longGammaVault.depositWithQuote(100 * 1e8, user1, quote, sig);
        vm.stopPrank();
        vm.prank(user1);
        vm.expectRevert(LongGammaVault.WithdrawBeforeSettlement.selector);
        longGammaVault.redeem(50 * 1e8, user1, user1);
    }

    function test_roll_noOp() public {
        vm.prank(user1);
        longGammaVault.roll(100);
    }
}
