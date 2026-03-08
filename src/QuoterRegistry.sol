// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IQuoterRegistry.sol";

/// @title QuoterRegistry
/// @notice Registry of addresses allowed to sign quotes (Long Gamma deposits, options purchases).
/// @dev Owner adds/removes quoters; market and vaults check isQuoter(signer) before accepting quotes.
contract QuoterRegistry is IQuoterRegistry, Ownable {
    /// @notice Whether an address is an authorized quoter.
    mapping(address => bool) public override isQuoter;

    /// @notice Emitted when a quoter is added.
    event QuoterAdded(address indexed quoter);
    /// @notice Emitted when a quoter is removed.
    event QuoterRemoved(address indexed quoter);

    /// @param initialOwner Owner (adds/removes quoters).
    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Adds a quoter (owner only).
    /// @param quoter Address to authorize.
    function addQuoter(address quoter) external onlyOwner {
        require(!isQuoter[quoter], "QuoterRegistry: already quoter");
        isQuoter[quoter] = true;
        emit QuoterAdded(quoter);
    }

    /// @notice Removes a quoter (owner only).
    /// @param quoter Address to revoke.
    function removeQuoter(address quoter) external onlyOwner {
        require(isQuoter[quoter], "QuoterRegistry: not quoter");
        isQuoter[quoter] = false;
        emit QuoterRemoved(quoter);
    }
}
