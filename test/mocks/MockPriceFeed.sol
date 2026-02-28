// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../../src/interfaces/IPriceFeed.sol";

contract MockPriceFeed is IPriceFeed {
    int256 private _answer;
    uint80 private _roundId;
    uint256 private _updatedAt;

    function setPrice(int256 price) external {
        _answer = price;
        _roundId++;
        _updatedAt = block.timestamp;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _answer, _updatedAt, _updatedAt, _roundId);
    }
}
