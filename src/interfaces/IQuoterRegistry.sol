// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IQuoterRegistry {
    function isQuoter(address account) external view returns (bool);
}
