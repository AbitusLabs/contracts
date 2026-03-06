// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

import "../src/QuoterRegistry.sol";
import "../src/SettlementOracle.sol";
import "../src/LPVault.sol";
import "../src/LongGammaVault.sol";
import "../src/EpochController.sol";
import "../test/mocks/MockERC20.sol";
import "../test/mocks/MockPriceFeed.sol";

contract DeployDemo is Script {
    function run() external {
        uint256 ownerPk = vm.envUint("OWNER_PK");
        address owner = vm.addr(ownerPk);

        address keeper = vm.envAddress("KEEPER_ADDRESS");
        address quoter = vm.envAddress("QUOTER_ADDRESS");
        address lpUser = vm.envAddress("LP_USER");
        address stratUser = vm.envAddress("STRAT_USER");

        uint256 epochAnchor = vm.envUint("EPOCH_ANCHOR");
        uint16 feeBps = uint16(vm.envUint("FEE_BPS"));
        uint256 longGammaCap = vm.envUint("LONG_GAMMA_CAP");
        int256 initialPrice = int256(vm.envUint("INITIAL_PRICE"));

        address demoWalletTarget = 0xE7CeC6a8d8B152B7acD037c184BBC48Da1c29b30;

        vm.startBroadcast(ownerPk);
        payable(demoWalletTarget).transfer(10 ether);

        MockERC20 collateral = new MockERC20("BTC.b", "BTC.b", 8);
        MockPriceFeed feed = new MockPriceFeed();

        QuoterRegistry quoterRegistry = new QuoterRegistry(owner);
        SettlementOracle oracle = new SettlementOracle(owner);
        LPVault lpVault = new LPVault(owner, address(collateral));
        LongGammaVault longGammaVault = new LongGammaVault(owner, address(collateral));
        EpochController controller = new EpochController(owner, epochAnchor);

        feed.setPrice(initialPrice);

        quoterRegistry.addQuoter(owner);

        oracle.setPriceFeed(address(feed));
        oracle.setKeeper(keeper);

        controller.setOracle(oracle);
        controller.setKeeper(keeper);
        controller.setFeeRecipient(owner);
        controller.setFeeBps(feeBps);
        controller.setVaults(longGammaVault, lpVault);

        longGammaVault.setEpochController(address(controller));
        longGammaVault.setQuoterRegistry(address(quoterRegistry));
        longGammaVault.setLPVault(address(lpVault));
        longGammaVault.setCap(longGammaCap);

        lpVault.setEpochController(address(controller));
        lpVault.setLongGammaVault(address(longGammaVault));

        collateral.mint(lpUser, 1_000_000 * 1e8);
        collateral.mint(stratUser, 1_000_000 * 1e8);

        console2.log("owner            ", owner);
        console2.log("collateral       ", address(collateral));
        console2.log("feed             ", address(feed));
        console2.log("quoterRegistry   ", address(quoterRegistry));
        console2.log("oracle           ", address(oracle));
        console2.log("lpVault          ", address(lpVault));
        console2.log("longGammaVault   ", address(longGammaVault));
        console2.log("controller       ", address(controller));

        vm.stopBroadcast();
    }
}