// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../../src/interfaces/ILongGammaVault.sol";

contract MockLongGammaVault is ILongGammaVault {
    function receiveSettlement(uint256) external override {}

    function onEpochStarted(uint256) external override {}

    function depositWithQuote(uint256 assets, address receiver, Quote calldata quote, bytes calldata signature)
        external
        returns (uint256)
    {}
}
