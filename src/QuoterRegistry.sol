// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IQuoterRegistry.sol";

contract QuoterRegistry is IQuoterRegistry, Ownable {
    mapping(address => bool) public override isQuoter;

    event QuoterAdded(address indexed quoter);
    event QuoterRemoved(address indexed quoter);

    constructor(address initialOwner) Ownable(initialOwner) {}

    function addQuoter(address quoter) external onlyOwner {
        require(!isQuoter[quoter], "QuoterRegistry: already quoter");
        isQuoter[quoter] = true;
        emit QuoterAdded(quoter);
    }

    function removeQuoter(address quoter) external onlyOwner {
        require(isQuoter[quoter], "QuoterRegistry: not quoter");
        isQuoter[quoter] = false;
        emit QuoterRemoved(quoter);
    }
}
