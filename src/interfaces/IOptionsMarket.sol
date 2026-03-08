// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IOptionsMarket
/// @notice Interface for buying and settling options (call/put) per epoch with signed quotes.
interface IOptionsMarket {
    /// @notice Quote structure for purchasing an option (signed by a registered quoter).
    struct Quote {
        address buyer;
        uint256 epochId;
        bool isCall;
        uint256 notional;
        uint256 premium;
        uint256 expiry;
    }

    /// @notice Purchases an option using a signed quote; reserves collateral in LP vault and mints NFT position.
    /// @param quote Signed quote (buyer, epoch, call/put, notional, premium, expiry).
    /// @param signature EIP-712 signature from a registered quoter.
    /// @return positionId ERC-721 token id representing the option position.
    function buyOption(Quote calldata quote, bytes calldata signature) external returns (uint256 positionId);

    /// @notice Previews total payout for an epoch given strike and settlement price (all positions).
    /// @param epochId Epoch identifier.
    /// @param strike Strike price for the epoch.
    /// @param settlementPrice Settlement price for the epoch.
    /// @return Total payout (call + put) for the epoch.
    function previewEpochPayout(uint256 epochId, uint256 strike, uint256 settlementPrice)
        external
        view
        returns (uint256);

    /// @notice Called by EpochController after settlement; records strike/price and funded amount for claims.
    /// @param epochId Epoch identifier.
    /// @param strike Strike price for the epoch.
    /// @param settlementPrice Settlement price for the epoch.
    /// @param fundedAmount Amount actually funded from LP vault for this epoch.
    function settleEpoch(uint256 epochId, uint256 strike, uint256 settlementPrice, uint256 fundedAmount) external;

    /// @notice Hook called by EpochController when a new epoch starts (e.g. to reset state).
    /// @param epochId The epoch that just started.
    function onEpochStarted(uint256 epochId) external;
}
