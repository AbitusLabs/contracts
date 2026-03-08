// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IQuoterRegistry
/// @notice Registry of addresses allowed to sign quotes (Long Gamma deposits, options purchases).
interface IQuoterRegistry {
    /// @notice Returns whether an account is an authorized quoter.
    /// @param account Address to check.
    /// @return True if the account may sign quotes.
    function isQuoter(address account) external view returns (bool);
}
