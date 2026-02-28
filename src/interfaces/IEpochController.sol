// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IEpochController {
    function getCurrentEpochId() external view returns (uint256);

    function getEpochStartTime(uint256 epochId) external view returns (uint256);

    function getEpochEndTime(uint256 epochId) external view returns (uint256);

    function epochSettled(uint256 epochId) external view returns (bool);

    function longGammaVault() external view returns (address);
}
