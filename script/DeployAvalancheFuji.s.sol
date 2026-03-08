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
import "../test/mocks/MockERC20.sol";
import "../test/mocks/MockPriceFeed.sol";

contract DeployAvalancheFuji is Script {
    using stdJson for string;

    uint256 internal constant AVALANCHE_FUJI_CHAIN_ID = 43113;
    uint256 internal constant DAY = 1 days;
    uint16 internal constant DEFAULT_FEE_BPS = 50;
    uint256 internal constant DEFAULT_LONG_GAMMA_CAP = 74 * 1e8;
    uint256 internal constant DEFAULT_INITIAL_PRICE = 100_000 * 1e8;

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
        uint256 initialPrice;
    }

    struct Deployment {
        MockERC20 collateral;
        MockPriceFeed feed;
        QuoterRegistry quoterRegistry;
        SettlementOracle oracle;
        LPVault lpVault;
        LongGammaVault longGammaVault;
        OptionsMarket optionsMarket;
        EpochController controller;
    }

    function run() external {
        DeployConfig memory cfg = _readConfig();

        require(block.chainid == AVALANCHE_FUJI_CHAIN_ID, "wrong chain");

        vm.startBroadcast(cfg.deployerPk);

        Deployment memory deployment = _deployContracts(cfg);

        _wireContracts(cfg, deployment);
        _transferOwnerships(cfg, deployment);
        _logAddresses(cfg, deployment);

        vm.stopBroadcast();

        _writeDeploymentJson(cfg, deployment);
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
        cfg.initialPrice = vm.envOr("INITIAL_PRICE", DEFAULT_INITIAL_PRICE);

        require(cfg.owner != address(0), "owner required");
        require(cfg.keeper != address(0), "keeper required");
        require(cfg.quoter != address(0), "quoter required");
        require(cfg.feeRecipient != address(0), "fee recipient required");
        require(cfg.longGammaCap > 0, "cap required");
        require(cfg.initialPrice > 0, "initial price required");
    }

    function _nextMidnightUtc() internal view returns (uint256) {
        return ((block.timestamp / DAY) + 1) * DAY;
    }

    function _deployContracts(DeployConfig memory cfg) internal returns (Deployment memory deployment) {
        deployment.collateral = new MockERC20("BTC.b", "BTC.b", 8);
        deployment.feed = new MockPriceFeed();
        deployment.quoterRegistry = new QuoterRegistry(cfg.deployer);
        deployment.oracle = new SettlementOracle(cfg.deployer);
        deployment.lpVault = new LPVault(cfg.deployer, address(deployment.collateral));
        deployment.longGammaVault = new LongGammaVault(cfg.deployer, address(deployment.collateral));
        deployment.optionsMarket = new OptionsMarket(cfg.deployer, address(deployment.collateral));
        deployment.controller = new EpochController(cfg.deployer, cfg.epochAnchor);
    }

    function _wireContracts(DeployConfig memory cfg, Deployment memory deployment) internal {
        _configureMocks(cfg, deployment);
        _configureOracle(cfg, deployment);
        _configureController(cfg, deployment);
        _configureVaults(cfg, deployment);
        _configureOptionsMarket(deployment);
    }

    function _configureMocks(DeployConfig memory cfg, Deployment memory deployment) internal {
        deployment.feed.setPrice(int256(cfg.initialPrice));
        deployment.quoterRegistry.addQuoter(cfg.quoter);
    }

    function _configureOracle(DeployConfig memory cfg, Deployment memory deployment) internal {
        deployment.oracle.setPriceFeed(address(deployment.feed));
        deployment.oracle.setKeeper(cfg.keeper);
    }

    function _configureController(DeployConfig memory cfg, Deployment memory deployment) internal {
        deployment.controller.setOracle(deployment.oracle);
        deployment.controller.setKeeper(cfg.keeper);
        deployment.controller.setFeeRecipient(cfg.feeRecipient);
        deployment.controller.setFeeBps(cfg.feeBps);
        deployment.controller.setVaults(deployment.longGammaVault, deployment.lpVault);
        deployment.controller.setOptionsMarket(deployment.optionsMarket);
    }

    function _configureVaults(DeployConfig memory cfg, Deployment memory deployment) internal {
        deployment.longGammaVault.setEpochController(address(deployment.controller));
        deployment.longGammaVault.setQuoterRegistry(address(deployment.quoterRegistry));
        deployment.longGammaVault.setLPVault(address(deployment.lpVault));
        deployment.longGammaVault.setCap(cfg.longGammaCap);

        deployment.lpVault.setEpochController(address(deployment.controller));
        deployment.lpVault.setLongGammaVault(address(deployment.longGammaVault));
        deployment.lpVault.setOptionsMarket(address(deployment.optionsMarket));
    }

    function _configureOptionsMarket(Deployment memory deployment) internal {
        deployment.optionsMarket.setEpochController(address(deployment.controller));
        deployment.optionsMarket.setLPVault(address(deployment.lpVault));
        deployment.optionsMarket.setQuoterRegistry(address(deployment.quoterRegistry));
    }

    function _transferOwnerships(DeployConfig memory cfg, Deployment memory deployment) internal {
        if (cfg.owner == cfg.deployer) {
            return;
        }

        deployment.quoterRegistry.transferOwnership(cfg.owner);
        deployment.oracle.transferOwnership(cfg.owner);
        deployment.lpVault.transferOwnership(cfg.owner);
        deployment.longGammaVault.transferOwnership(cfg.owner);
        deployment.optionsMarket.transferOwnership(cfg.owner);
        deployment.controller.transferOwnership(cfg.owner);
    }

    function _logAddresses(DeployConfig memory cfg, Deployment memory deployment) internal view {
        console2.log("chainId          ", block.chainid);
        console2.log("deployer         ", cfg.deployer);
        console2.log("owner            ", cfg.owner);
        console2.log("keeper           ", cfg.keeper);
        console2.log("quoter           ", cfg.quoter);
        console2.log("feeRecipient     ", cfg.feeRecipient);
        console2.log("collateral       ", address(deployment.collateral));
        console2.log("priceFeed        ", address(deployment.feed));
        console2.log("epochAnchor      ", cfg.epochAnchor);
        console2.log("feeBps           ", uint256(cfg.feeBps));
        console2.log("longGammaCap     ", cfg.longGammaCap);
        console2.log("initialPrice     ", cfg.initialPrice);
        console2.log("quoterRegistry   ", address(deployment.quoterRegistry));
        console2.log("oracle           ", address(deployment.oracle));
        console2.log("lpVault          ", address(deployment.lpVault));
        console2.log("longGammaVault   ", address(deployment.longGammaVault));
        console2.log("optionsMarket    ", address(deployment.optionsMarket));
        console2.log("controller       ", address(deployment.controller));
    }

    function _writeDeploymentJson(DeployConfig memory cfg, Deployment memory deployment) internal {
        string memory contractsKey = "contracts";
        contractsKey.serialize("quoterRegistry", address(deployment.quoterRegistry));
        contractsKey.serialize("oracle", address(deployment.oracle));
        contractsKey.serialize("lpVault", address(deployment.lpVault));
        contractsKey.serialize("longGammaVault", address(deployment.longGammaVault));
        contractsKey.serialize("optionsMarket", address(deployment.optionsMarket));
        string memory contractsJson = contractsKey.serialize("epochController", address(deployment.controller));

        string memory rootKey = "deployment";
        string memory networkName = "avalanche-fuji";
        rootKey.serialize("chainId", block.chainid);
        rootKey.serialize("network", networkName);
        rootKey.serialize("blockNumber", block.number);
        rootKey.serialize("deployer", cfg.deployer);
        rootKey.serialize("owner", cfg.owner);
        rootKey.serialize("keeper", cfg.keeper);
        rootKey.serialize("quoter", cfg.quoter);
        rootKey.serialize("feeRecipient", cfg.feeRecipient);
        rootKey.serialize("collateral", address(deployment.collateral));
        rootKey.serialize("priceFeed", address(deployment.feed));
        rootKey.serialize("epochAnchor", cfg.epochAnchor);
        rootKey.serialize("feeBps", uint256(cfg.feeBps));
        rootKey.serialize("longGammaCap", cfg.longGammaCap);
        rootKey.serialize("initialPrice", cfg.initialPrice);
        string memory rootJson = rootKey.serialize("contracts", contractsJson);

        string memory path = string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json");
        rootJson.write(path);

        console2.log("deploymentJson   ", path);
    }
}
