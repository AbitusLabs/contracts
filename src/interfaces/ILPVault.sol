// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ILPVault
/// @notice Interface for LP vault protocol hooks: premium, settlement, collateral reserve/release, epoch start.
interface ILPVault {
    /// @notice Receives premium from Long Gamma vault or options market; increases share value (donation).
    /// @param amount Amount of collateral to receive.
    function receivePremium(uint256 amount) external;

    /// @notice Pays settlement to the Long Gamma vault (called by EpochController).
    /// @param amount Amount to transfer to Long Gamma vault.
    function paySettlement(uint256 amount) external;

    /// @notice Pays settlement to a specific receiver from reserved collateral for an epoch (e.g. options market).
    /// @param receiver Recipient address.
    /// @param amount Amount to transfer.
    /// @param epochId Epoch whose reserved collateral is debited.
    function paySettlementTo(address receiver, uint256 amount, uint256 epochId) external;

    /// @notice Reserves collateral for an epoch (e.g. when options are sold); called by options market.
    /// @param epochId Epoch to reserve for.
    /// @param amount Amount to reserve.
    function reserveCollateral(uint256 epochId, uint256 amount) external;

    /// @notice Releases all reserved collateral for an epoch (after settlement); called by EpochController.
    /// @param epochId Epoch whose reservation to release.
    /// @return released Amount that was reserved and is now released.
    function releaseReservedCollateral(uint256 epochId) external returns (uint256 released);

    /// @notice Hook when an epoch starts; activates pending deposits for that epoch.
    /// @param epochId Epoch that just started.
    function onEpochStarted(uint256 epochId) external;
}
