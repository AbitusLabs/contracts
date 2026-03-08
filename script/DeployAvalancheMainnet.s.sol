// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import "../src/QuoterRegistry.sol";
import "../src/SettlementOracle.sol";
import "../src/LPVault.sol";
import "../src/LongGammaVault.sol";
import "../src/OptionsMarket.sol";
import "../src/EpochController.sol";

contract DeployAvalancheMainnet is Script {
    using stdJson for string;

    address internal constant BTC_B = 0x152b9d0FdC40C096757F570A51E494bd4b943E50;
    address internal constant BTC_USD_FEED = 0x2779D32d5166BAaa2B2b658333bA7e6Ec0C65743;
    uint256 internal constant AVALANCHE_MAINNET_CHAIN_ID = 43114;
    uint256 internal constant DAY = 1 days;
    uint16 internal constant DEFAULT_FEE_BPS = 50;
    uint256 internal constant DEFAULT_LONG_GAMMA_CAP = 74 * 1e8;

    struct DeployConfig {
        uint256 deployerPk;
        address deployer;
        address owner;
        address keeper;
        address quoter;
        address feeRecipient;
        uint256 epochAnchor;
        uint16 feeBps;
        uint256 longGammaCap;
    }

    function run() external {
        DeployConfig memory cfg = _readConfig();

        require(block.chainid == AVALANCHE_MAINNET_CHAIN_ID, "wrong chain");

        vm.startBroadcast(cfg.deployerPk);

        QuoterRegistry quoterRegistry = new QuoterRegistry(cfg.deployer);
        SettlementOracle oracle = new SettlementOracle(cfg.deployer);
        LPVault lpVault = new LPVault(cfg.deployer, BTC_B);
        LongGammaVault longGammaVault = new LongGammaVault(cfg.deployer, BTC_B);
        OptionsMarket optionsMarket = new OptionsMarket(cfg.deployer, BTC_B);
        EpochController controller = new EpochController(cfg.deployer, cfg.epochAnchor);

        _wireContracts(cfg, quoterRegistry, oracle, lpVault, longGammaVault, optionsMarket, controller);
        _transferOwnerships(cfg, quoterRegistry, oracle, lpVault, longGammaVault, optionsMarket, controller);
        _logAddresses(cfg, quoterRegistry, oracle, lpVault, longGammaVault, optionsMarket, controller);

        vm.stopBroadcast();

        _writeDeploymentJson(cfg, quoterRegistry, oracle, lpVault, longGammaVault, optionsMarket, controller);
    }

    function _readConfig() internal view returns (DeployConfig memory cfg) {
        cfg.deployerPk = vm.envUint("DEPLOYER_PK");
        cfg.deployer = vm.addr(cfg.deployerPk);
        cfg.owner = vm.envOr("OWNER_ADDRESS", cfg.deployer);
        cfg.keeper = vm.envOr("KEEPER_ADDRESS", cfg.deployer);
        cfg.quoter = vm.envOr("QUOTER_ADDRESS", cfg.deployer);
        cfg.feeRecipient = vm.envOr("FEE_RECIPIENT_ADDRESS", cfg.deployer);
        cfg.epochAnchor = vm.envOr("EPOCH_ANCHOR", _nextMidnightUtc());
        cfg.feeBps = uint16(vm.envOr("FEE_BPS", uint256(DEFAULT_FEE_BPS)));
        cfg.longGammaCap = vm.envOr("LONG_GAMMA_CAP", DEFAULT_LONG_GAMMA_CAP);

        require(cfg.owner != address(0), "owner required");
        require(cfg.keeper != address(0), "keeper required");
        require(cfg.quoter != address(0), "quoter required");
        require(cfg.feeRecipient != address(0), "fee recipient required");
        require(cfg.longGammaCap > 0, "cap required");
    }

    function _nextMidnightUtc() internal view returns (uint256) {
        return ((block.timestamp / DAY) + 1) * DAY;
    }

    function _wireContracts(
        DeployConfig memory cfg,
        QuoterRegistry quoterRegistry,
        SettlementOracle oracle,
        LPVault lpVault,
        LongGammaVault longGammaVault,
        OptionsMarket optionsMarket,
        EpochController controller
    ) internal {
        quoterRegistry.addQuoter(cfg.quoter);

        oracle.setPriceFeed(BTC_USD_FEED);
        oracle.setKeeper(cfg.keeper);

        controller.setOracle(oracle);
        controller.setKeeper(cfg.keeper);
        controller.setFeeRecipient(cfg.feeRecipient);
        controller.setFeeBps(cfg.feeBps);
        controller.setVaults(longGammaVault, lpVault);
        controller.setOptionsMarket(optionsMarket);

        longGammaVault.setEpochController(address(controller));
        longGammaVault.setQuoterRegistry(address(quoterRegistry));
        longGammaVault.setLPVault(address(lpVault));
        longGammaVault.setCap(cfg.longGammaCap);

        lpVault.setEpochController(address(controller));
        lpVault.setLongGammaVault(address(longGammaVault));
        lpVault.setOptionsMarket(address(optionsMarket));

        optionsMarket.setEpochController(address(controller));
        optionsMarket.setLPVault(address(lpVault));
        optionsMarket.setQuoterRegistry(address(quoterRegistry));
    }

    function _transferOwnerships(
        DeployConfig memory cfg,
        QuoterRegistry quoterRegistry,
        SettlementOracle oracle,
        LPVault lpVault,
        LongGammaVault longGammaVault,
        OptionsMarket optionsMarket,
        EpochController controller
    ) internal {
        if (cfg.owner == cfg.deployer) {
            return;
        }

        quoterRegistry.transferOwnership(cfg.owner);
        oracle.transferOwnership(cfg.owner);
        lpVault.transferOwnership(cfg.owner);
        longGammaVault.transferOwnership(cfg.owner);
        optionsMarket.transferOwnership(cfg.owner);
        controller.transferOwnership(cfg.owner);
    }

    function _logAddresses(
        DeployConfig memory cfg,
        QuoterRegistry quoterRegistry,
        SettlementOracle oracle,
        LPVault lpVault,
        LongGammaVault longGammaVault,
        OptionsMarket optionsMarket,
        EpochController controller
    ) internal view {
        console2.log("chainId          ", block.chainid);
        console2.log("deployer         ", cfg.deployer);
        console2.log("owner            ", cfg.owner);
        console2.log("keeper           ", cfg.keeper);
        console2.log("quoter           ", cfg.quoter);
        console2.log("feeRecipient     ", cfg.feeRecipient);
        console2.log("btc.b            ", BTC_B);
        console2.log("btcUsdFeed       ", BTC_USD_FEED);
        console2.log("epochAnchor      ", cfg.epochAnchor);
        console2.log("feeBps           ", uint256(cfg.feeBps));
        console2.log("longGammaCap     ", cfg.longGammaCap);
        console2.log("quoterRegistry   ", address(quoterRegistry));
        console2.log("oracle           ", address(oracle));
        console2.log("lpVault          ", address(lpVault));
        console2.log("longGammaVault   ", address(longGammaVault));
        console2.log("optionsMarket    ", address(optionsMarket));
        console2.log("controller       ", address(controller));
    }

    function _writeDeploymentJson(
        DeployConfig memory cfg,
        QuoterRegistry quoterRegistry,
        SettlementOracle oracle,
        LPVault lpVault,
        LongGammaVault longGammaVault,
        OptionsMarket optionsMarket,
        EpochController controller
    ) internal {
        string memory contractsKey = "contracts";
        contractsKey.serialize("quoterRegistry", address(quoterRegistry));
        contractsKey.serialize("oracle", address(oracle));
        contractsKey.serialize("lpVault", address(lpVault));
        contractsKey.serialize("longGammaVault", address(longGammaVault));
        contractsKey.serialize("optionsMarket", address(optionsMarket));
        string memory contractsJson = contractsKey.serialize("epochController", address(controller));

        string memory rootKey = "deployment";
        rootKey.serialize("chainId", block.chainid);
        string memory networkName = "avalanche-mainnet";
        rootKey.serialize("network", networkName);
        rootKey.serialize("blockNumber", block.number);
        rootKey.serialize("deployer", cfg.deployer);
        rootKey.serialize("owner", cfg.owner);
        rootKey.serialize("keeper", cfg.keeper);
        rootKey.serialize("quoter", cfg.quoter);
        rootKey.serialize("feeRecipient", cfg.feeRecipient);
        rootKey.serialize("btcB", BTC_B);
        rootKey.serialize("btcUsdFeed", BTC_USD_FEED);
        rootKey.serialize("epochAnchor", cfg.epochAnchor);
        rootKey.serialize("feeBps", uint256(cfg.feeBps));
        rootKey.serialize("longGammaCap", cfg.longGammaCap);
        string memory rootJson = rootKey.serialize("contracts", contractsJson);

        string memory path = string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json");
        rootJson.write(path);

        console2.log("deploymentJson   ", path);
    }
}
