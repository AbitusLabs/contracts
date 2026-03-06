// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "../src/interfaces/IEpochController.sol";
import "../src/interfaces/ISettlementOracle.sol";
import "../src/interfaces/ILongGammaVault.sol";
import "../src/interfaces/ILPVault.sol";

interface IMockERC20 {
    function mint(address to, uint256 amount) external;
}

bytes32 constant QUOTE_TYPEHASH = keccak256("Quote(uint256 epochId,uint256 notional,uint256 premium,uint256 expiry)");

bytes32 constant DOMAIN_TYPEHASH =
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

contract DemoController is Script {
    address LP_VAULT = vm.envAddress("LP_VAULT");
    address LONG_GAMMA = vm.envAddress("LONG_GAMMA_VAULT");
    address CONTROLLER = vm.envAddress("EPOCH_CONTROLLER");
    address ORACLE = vm.envAddress("SETTLEMENT_ORACLE");
    address COLLATERAL = vm.envAddress("BTC_B");

    uint256 LP_USER_PK = vm.envUint("LP_USER_PK");
    uint256 STRAT_USER_PK = vm.envUint("STRAT_USER_PK");
    uint256 OWNER_PK = vm.envUint("OWNER_PK");
    uint256 QUOTER_PK = vm.envUint("OWNER_PK");
    uint256 KEEPER_PK = vm.envUint("KEEPER_PK");

    function run() external {
        address lpUser = vm.addr(LP_USER_PK);
        address stratUser = vm.addr(STRAT_USER_PK);
        address owner = vm.addr(OWNER_PK);

        IEpochController controller = IEpochController(CONTROLLER);
        ISettlementOracle oracle = ISettlementOracle(ORACLE);

        vm.startBroadcast(OWNER_PK);

        IMockERC20(COLLATERAL).mint(lpUser, 1_000_000 * 1e8);
        IMockERC20(COLLATERAL).mint(stratUser, 1_000 * 1e8);

        vm.stopBroadcast();

        uint256 epochId = controller.getCurrentEpochId();
        uint256 nextEpochStart = controller.getEpochStartTime(epochId + 1);

        vm.warp(nextEpochStart - 3600);

        vm.startBroadcast(LP_USER_PK);

        IERC20(COLLATERAL).approve(LP_VAULT, 1000 * 1e8);
        IERC4626(LP_VAULT).deposit(500 * 1e8, lpUser);

        vm.stopBroadcast();

        epochId = controller.getCurrentEpochId();

        vm.startBroadcast(STRAT_USER_PK);

        IERC20(COLLATERAL).approve(LONG_GAMMA, 100 * 1e8);

        ILongGammaVault.Quote memory q = ILongGammaVault.Quote(epochId, 100 * 1e8, 10 * 1e8, block.timestamp + 1 hours);

        bytes memory sig = _signQuote(QUOTER_PK, LONG_GAMMA, q.epochId, q.notional, q.premium, q.expiry);

        ILongGammaVault(LONG_GAMMA).depositWithQuote(100 * 1e8, stratUser, q, sig);

        vm.stopBroadcast();

        vm.startBroadcast(KEEPER_PK);

        controller.startEpoch();
        oracle.setSettlementPrice(epochId, 50000 * 1e8);

        vm.stopBroadcast();

        uint256 endTime = controller.getEpochEndTime(epochId);
        // _anvilSetNextBlockTimestamp(endTime + 1000000000000000);
        vm.warp(endTime + 1000000000);

        vm.startBroadcast(KEEPER_PK);

        controller.settleEpoch(epochId);

        vm.stopBroadcast();
    }

    function _signQuote(
        uint256 quoterPk,
        address verifyingContract,
        uint256 epochId,
        uint256 notional,
        uint256 premium,
        uint256 expiry
    ) internal view returns (bytes memory) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH, keccak256("AbitusLongGammaQuote"), keccak256("1"), block.chainid, verifyingContract
            )
        );

        bytes32 structHash = keccak256(abi.encode(QUOTE_TYPEHASH, epochId, notional, premium, expiry));

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(quoterPk, digest);

        return abi.encodePacked(r, s, v);
    }

    function _anvilSetNextBlockTimestamp(uint256 ts) internal {
        string memory rpc = vm.envString("RPC_URL");

        string[] memory cmd1 = new string[](6);
        cmd1[0] = "cast";
        cmd1[1] = "rpc";
        cmd1[2] = "evm_setNextBlockTimestamp";
        cmd1[3] = vm.toString(ts);
        cmd1[4] = "--rpc-url";
        cmd1[5] = rpc;
        vm.ffi(cmd1);

        // string[] memory cmd2 = new string[](5);
        // cmd2[0] = "cast";
        // cmd2[1] = "rpc";
        // cmd2[2] = "evm_mine";
        // cmd2[3] = "--rpc-url";
        // cmd2[4] = rpc;
        // vm.ffi(cmd2);
    }
}
