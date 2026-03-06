// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ILongGammaVault {
    struct Quote {
        uint256 epochId;
        uint256 notional;
        uint256 premium;
        uint256 expiry;
    }

    function receiveSettlement(uint256 amount) external;

    function onEpochStarted(uint256 epochId) external;

    function depositWithQuote(
        uint256 assets,
        address receiver,
        Quote calldata quote,
        bytes calldata signature
    ) external returns (uint256);
}
