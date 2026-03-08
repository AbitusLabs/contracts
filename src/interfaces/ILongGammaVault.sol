// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ILongGammaVault
/// @notice Interface for Long Gamma vault: settlement receipt, epoch start, quote-gated deposit.
interface ILongGammaVault {
    /// @notice Quote structure for deposit/mint (signed by a registered quoter).
    struct Quote {
        uint256 epochId;
        uint256 notional;
        uint256 premium;
        uint256 expiry;
    }

    /// @notice Receives settlement from EpochController after epoch settlement.
    /// @param amount Amount of collateral received.
    function receiveSettlement(uint256 amount) external;

    /// @notice Hook when an epoch starts (e.g. reset per-epoch counters).
    /// @param epochId Epoch that just started.
    function onEpochStarted(uint256 epochId) external;

    /// @notice Deposits assets with a signed quote; premium is sent to LP vault, net gets shares.
    /// @param assets Gross amount of collateral (notional = assets, premium deducted to LP).
    /// @param receiver Recipient of vault shares.
    /// @param quote Signed quote (epochId, notional, premium, expiry).
    /// @param signature EIP-712 signature from a registered quoter.
    /// @return shares Amount of vault shares minted.
    function depositWithQuote(uint256 assets, address receiver, Quote calldata quote, bytes calldata signature)
        external
        returns (uint256 shares);
}
