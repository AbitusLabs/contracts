// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ISettlementOracle {
    function getCurrentPrice() external view returns (uint256);

    function getSettlementPrice(uint256 epochId) external view returns (uint256);

    function settlementPrice(uint256 epochId) external view returns (uint256);

    function setSettlementPrice(uint256 epochId, uint256 price) external;
}
