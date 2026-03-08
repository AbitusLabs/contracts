// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IPriceFeed
/// @notice Chainlink-style price feed interface for reading latest round data.
interface IPriceFeed {
    /// @notice Returns the latest round data (Chainlink-compatible).
    /// @return roundId Round identifier.
    /// @return answer Price (signed; must be non-negative for settlement).
    /// @return startedAt Round start timestamp.
    /// @return updatedAt Round update timestamp.
    /// @return answeredInRound Round in which answer was computed.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
