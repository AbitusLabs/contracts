// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IPriceFeed.sol";
import "./interfaces/ISettlementOracle.sol";

contract SettlementOracle is ISettlementOracle, Ownable {
    IPriceFeed public feed;
    mapping(uint256 => uint256) public override settlementPrice;
    address public keeper;

    event SettlementPriceSet(uint256 indexed epochId, uint256 price);
    event KeeperSet(address indexed keeper);
    event PriceFeedSet(address indexed feed);

    error OnlyKeeper();
    error PriceAlreadySet();
    error InvalidPrice();

    constructor(address initialOwner) Ownable(initialOwner) {}

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert OnlyKeeper();
        _;
    }

    function setPriceFeed(address _feed) external onlyOwner {
        feed = IPriceFeed(_feed);
        emit PriceFeedSet(_feed);
    }

    function setKeeper(address _keeper) external onlyOwner {
        keeper = _keeper;
        emit KeeperSet(_keeper);
    }

    function getCurrentPrice() external view override returns (uint256) {
        return _readFeedPrice();
    }

    function getSettlementPrice(uint256 epochId) external view override returns (uint256) {
        uint256 price = settlementPrice[epochId];
        require(price != 0, "SettlementOracle: price not set");
        return price;
    }

    function setSettlementPrice(uint256 epochId, uint256 price) external onlyKeeper {
        if (settlementPrice[epochId] != 0) revert PriceAlreadySet();
        if (price == 0) revert InvalidPrice();
        settlementPrice[epochId] = price;
        emit SettlementPriceSet(epochId, price);
    }

    function _readFeedPrice() internal view returns (uint256) {
        (, int256 answer,,,) = feed.latestRoundData();
        require(answer >= 0, "SettlementOracle: invalid feed");
        return uint256(int256(answer));
    }
}
