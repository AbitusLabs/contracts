// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IEpochController
/// @notice Interface for epoch lifecycle: start (strike set), settle (payout to Long Gamma and options).
interface IEpochController {
    /// @notice Returns the current epoch id (0 before anchor, then (timestamp - anchor) / duration).
    /// @return Current epoch identifier.
    function getCurrentEpochId() external view returns (uint256);

    /// @notice Returns the start timestamp of an epoch.
    /// @param epochId Epoch identifier.
    /// @return Unix timestamp when the epoch starts.
    function getEpochStartTime(uint256 epochId) external view returns (uint256);

    /// @notice Returns the end timestamp of an epoch.
    /// @param epochId Epoch identifier.
    /// @return Unix timestamp when the epoch ends.
    function getEpochEndTime(uint256 epochId) external view returns (uint256);

    /// @notice Strike price set for an epoch (0 if not yet started).
    /// @param epochId Epoch identifier.
    /// @return Strike price or 0.
    function strikeForEpoch(uint256 epochId) external view returns (uint256);

    /// @notice Whether the epoch has been settled (payouts sent).
    /// @param epochId Epoch identifier.
    /// @return True if settled.
    function epochSettled(uint256 epochId) external view returns (bool);

    /// @notice Address of the Long Gamma vault.
    /// @return Long Gamma vault contract address.
    function longGammaVault() external view returns (address);

    /// @notice Address of the options market (optional).
    /// @return Options market contract address or zero.
    function optionsMarket() external view returns (address);

    /// @notice Starts the current epoch: fetches strike from oracle, notifies vaults and options market.
    function startEpoch() external;

    /// @notice Settles an epoch after end time: computes payouts, pays Long Gamma and options, releases collateral.
    /// @param epochId Epoch to settle.
    function settleEpoch(uint256 epochId) external;
}
