// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../../src/QuoterRegistry.sol";
import "../../src/SettlementOracle.sol";
import "../../src/LPVault.sol";
import "../../src/LongGammaVault.sol";
import "../../src/EpochController.sol";
import "../mocks/MockERC20.sol";
import "../mocks/MockPriceFeed.sol";
import "../QuoteDigestHelper.sol";

contract EpochFlowTest is Test {
    MockERC20 public collateral;
    MockPriceFeed public feed;
    QuoterRegistry public quoterRegistry;
    SettlementOracle public oracle;
    LPVault public lpVault;
    LongGammaVault public longGammaVault;
    EpochController public controller;
    QuoteDigestHelper public digestHelper;

    address public owner;
    address public keeper;
    address public lpUser;
    address public stratUser;
    uint256 public quoterPk;
    address public quoter;
    uint256 public epochAnchor;

    function setUp() public {
        owner = address(1);
        keeper = address(2);
        lpUser = address(10);
        stratUser = address(11);
        quoterPk = 0xB0B;
        quoter = vm.addr(quoterPk);
        epochAnchor = 10 days;
        vm.warp(epochAnchor + 1);

        collateral = new MockERC20("BTC.b", "BTC.b", 8);
        collateral.mint(lpUser, 1_000_000 * 1e8);
        collateral.mint(stratUser, 1_000_000 * 1e8);

        feed = new MockPriceFeed();
        feed.setPrice(50_000 * 1e8);

        vm.startPrank(owner);
        quoterRegistry = new QuoterRegistry(owner);
        quoterRegistry.addQuoter(quoter);
        oracle = new SettlementOracle(owner);
        oracle.setPriceFeed(address(feed));
        oracle.setKeeper(keeper);
        lpVault = new LPVault(owner, address(collateral));
        longGammaVault = new LongGammaVault(owner, address(collateral));
        controller = new EpochController(owner, epochAnchor);
        controller.setOracle(oracle);
        controller.setKeeper(keeper);
        controller.setVaults(longGammaVault, lpVault);
        controller.setFeeBps(50);
        controller.setFeeRecipient(owner);

        longGammaVault.setEpochController(address(controller));
        longGammaVault.setQuoterRegistry(address(quoterRegistry));
        longGammaVault.setLPVault(address(lpVault));
        longGammaVault.setCap(200_000 * 1e8);

        lpVault.setEpochController(address(controller));
        lpVault.setLongGammaVault(address(longGammaVault));
        vm.stopPrank();

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

    function test_fullEpochFlow() public {
        _warpToDepositWindow();
        uint256 epochId = controller.getCurrentEpochId();

        vm.startPrank(lpUser);
        collateral.approve(address(lpVault), 300_000 * 1e8);
        lpVault.deposit(300_000 * 1e8, lpUser);
        vm.stopPrank();
        assertEq(lpVault.balanceOf(lpUser), 300_000 * 1e8);

        ILongGammaVault.Quote memory quote = ILongGammaVault.Quote({
            epochId: epochId, notional: 100 * 1e8, premium: 8 * 1e8, expiry: block.timestamp + 2 hours
        });
        bytes memory sig = _signQuote(quote.epochId, quote.notional, quote.premium, quote.expiry);
        vm.startPrank(stratUser);
        collateral.approve(address(longGammaVault), 100 * 1e8);
        longGammaVault.depositWithQuote(100 * 1e8, stratUser, quote, sig);
        vm.stopPrank();
        assertEq(longGammaVault.balanceOf(stratUser), 92 * 1e8);
        assertEq(collateral.balanceOf(address(lpVault)), 300_000 * 1e8 + 8 * 1e8);

        vm.warp(epochAnchor + 1);
        vm.prank(keeper);
        controller.startEpoch();
        vm.prank(keeper);
        oracle.setSettlementPrice(0, 52_500 * 1e8);

        vm.warp(epochAnchor + 1 days + 1);
        controller.settleEpoch(0);
        assertTrue(controller.epochSettled(0));
        uint256 payoff = 2_500 * 1e8;
        uint256 afterFee = (payoff * (10000 - 50)) / 10000;
        assertEq(collateral.balanceOf(address(longGammaVault)), 92 * 1e8 + afterFee);

        vm.prank(keeper);
        controller.startEpoch();
        vm.prank(keeper);
        oracle.setSettlementPrice(1, 51_000 * 1e8);
        vm.warp(epochAnchor + 3 days - 1);
        controller.settleEpoch(1);

        vm.warp(epochAnchor + 2 days + 1);
        vm.prank(keeper);
        controller.startEpoch();
        vm.prank(keeper);
        oracle.setSettlementPrice(2, 52_000 * 1e8);
        vm.warp(epochAnchor + 3 days + 1);
        controller.settleEpoch(2);

        uint256 stratShares = longGammaVault.balanceOf(stratUser);
        vm.prank(stratUser);
        longGammaVault.redeem(stratShares, stratUser, stratUser);
        assertEq(longGammaVault.balanceOf(stratUser), 0);

        uint256 lpShares = lpVault.balanceOf(lpUser);
        vm.prank(lpUser);
        lpVault.redeem(lpShares, lpUser, lpUser);
        assertEq(lpVault.balanceOf(lpUser), 0);
    }
}
