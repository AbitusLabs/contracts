// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ISettlementOracle
/// @notice Interface for settlement price source: current price (for strike) and per-epoch settlement price.
interface ISettlementOracle {
    /// @notice Returns the current price (used when starting an epoch to set strike).
    /// @return Current price from the underlying feed.
    function getCurrentPrice() external view returns (uint256);

    /// @notice Returns the settlement price for an epoch (reverts if not set).
    /// @param epochId Epoch identifier.
    /// @return Settlement price for the epoch.
    function getSettlementPrice(uint256 epochId) external view returns (uint256);

    /// @notice Storage getter for settlement price (0 if not set).
    /// @param epochId Epoch identifier.
    /// @return Stored settlement price or 0.
    function settlementPrice(uint256 epochId) external view returns (uint256);

    /// @notice Sets the settlement price for an epoch (keeper only; once per epoch).
    /// @param epochId Epoch identifier.
    /// @param price Settlement price to set.
    function setSettlementPrice(uint256 epochId, uint256 price) external;
}
