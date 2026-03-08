// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "../src/EpochController.sol";
import "../src/LPVault.sol";
import "../src/OptionsMarket.sol";
import "../src/QuoterRegistry.sol";
import "../src/SettlementOracle.sol";
import "./QuoteDigestHelper.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockLongGammaVault.sol";
import "./mocks/MockPriceFeed.sol";

contract OptionsMarketTest is Test {
    MockERC20 public collateral;
    MockPriceFeed public feed;
    QuoterRegistry public quoterRegistry;
    SettlementOracle public oracle;
    LPVault public lpVault;
    MockLongGammaVault public longGammaVault;
    OptionsMarket public optionsMarket;
    EpochController public controller;
    QuoteDigestHelper public digestHelper;

    address public owner;
    address public keeper;
    address public lpUser;
    address public buyer;
    uint256 public quoterPk;
    address public quoter;
    uint256 public epochAnchor;

    function setUp() public {
        owner = address(1);
        keeper = address(2);
        lpUser = address(10);
        buyer = address(11);
        quoterPk = 0xB0B;
        quoter = vm.addr(quoterPk);
        epochAnchor = 10 days;
        vm.warp(epochAnchor);

        collateral = new MockERC20("BTC.b", "BTC.b", 8);
        collateral.mint(lpUser, 1_000_000 * 1e8);
        collateral.mint(buyer, 1_000_000 * 1e8);

        feed = new MockPriceFeed();
        feed.setPrice(50_000 * 1e8);

        vm.startPrank(owner);
        quoterRegistry = new QuoterRegistry(owner);
        quoterRegistry.addQuoter(quoter);
        oracle = new SettlementOracle(owner);
        oracle.setPriceFeed(address(feed));
        oracle.setKeeper(keeper);
        lpVault = new LPVault(owner, address(collateral));
        longGammaVault = new MockLongGammaVault();
        optionsMarket = new OptionsMarket(owner, address(collateral));
        controller = new EpochController(owner, epochAnchor);

        controller.setOracle(oracle);
        controller.setKeeper(keeper);
        controller.setFeeRecipient(owner);
        controller.setFeeBps(0);
        controller.setVaults(longGammaVault, lpVault);
        controller.setOptionsMarket(optionsMarket);

        lpVault.setEpochController(address(controller));
        lpVault.setLongGammaVault(address(longGammaVault));
        lpVault.setOptionsMarket(address(optionsMarket));

        optionsMarket.setEpochController(address(controller));
        optionsMarket.setLPVault(address(lpVault));
        optionsMarket.setQuoterRegistry(address(quoterRegistry));
        vm.stopPrank();

        digestHelper = new QuoteDigestHelper();
    }

    function _signQuote(address quoteBuyer, uint256 epochId, bool isCall, uint256 notional, uint256 premium, uint256 expiry)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest =
            digestHelper.getOptionsDigest(address(optionsMarket), block.chainid, quoteBuyer, epochId, isCall, notional, premium, expiry);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(quoterPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_buy_settle_and_claim_call_option() public {
        vm.startPrank(lpUser);
        collateral.approve(address(lpVault), 300_000 * 1e8);
        lpVault.deposit(300_000 * 1e8, lpUser);
        vm.stopPrank();

        IOptionsMarket.Quote memory quote =
            IOptionsMarket.Quote({buyer: buyer, epochId: 0, isCall: true, notional: 10 * 1e8, premium: 1 * 1e8, expiry: block.timestamp + 2 hours});
        bytes memory signature =
            _signQuote(quote.buyer, quote.epochId, quote.isCall, quote.notional, quote.premium, quote.expiry);

        vm.startPrank(buyer);
        collateral.approve(address(optionsMarket), quote.premium);
        uint256 positionId = optionsMarket.buyOption(quote, signature);
        vm.stopPrank();

        assertEq(ownerOfPosition(positionId), buyer);
        assertEq(collateral.balanceOf(address(lpVault)), 300_001 * 1e8);
        assertEq(lpVault.reservedCollateralByEpoch(0), 10 * 1e8);

        vm.warp(epochAnchor + 1);
        vm.prank(keeper);
        controller.startEpoch();
        vm.prank(keeper);
        oracle.setSettlementPrice(0, 50_500 * 1e8);

        vm.warp(epochAnchor + 1 days + 1);
        controller.settleEpoch(0);

        uint256 expectedPayout = (uint256(10) * 1e8 * 500) / 50_500;

        vm.prank(buyer);
        uint256 claimed = optionsMarket.claim(positionId);

        assertEq(claimed, expectedPayout);
        assertEq(lpVault.reservedCollateralByEpoch(0), 0);
        assertEq(collateral.balanceOf(buyer), 1_000_000 * 1e8 - quote.premium + expectedPayout);
    }

    function ownerOfPosition(uint256 positionId) internal view returns (address) {
        return optionsMarket.ownerOf(positionId);
    }
}
