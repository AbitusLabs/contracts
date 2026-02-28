// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ILongGammaVault {
    function receiveSettlement(uint256 amount) external;

    function onEpochStarted(uint256 epochId) external;
}
