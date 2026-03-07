// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ILPVault {
    function receivePremium(uint256 amount) external;
    function paySettlement(uint256 amount) external;
}
