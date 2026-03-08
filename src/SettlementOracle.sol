// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IPriceFeed.sol";
import "./interfaces/ISettlementOracle.sol";

/// @title SettlementOracle
/// @notice Provides current price (for strike) and per-epoch settlement price; keeper sets settlement after epoch end.
/// @dev Current price from Chainlink-style feed; settlement price set once per epoch by keeper.
contract SettlementOracle is ISettlementOracle, Ownable {
    /// @notice Price feed for current price (used when starting epoch).
    IPriceFeed public feed;
    /// @notice Settlement price per epoch (set by keeper, 0 until set).
    mapping(uint256 => uint256) public override settlementPrice;
    /// @notice Address allowed to set settlement prices.
    address public keeper;

    /// @notice Emitted when settlement price is set for an epoch.
    event SettlementPriceSet(uint256 indexed epochId, uint256 price);
    /// @notice Emitted when keeper is updated.
    event KeeperSet(address indexed keeper);
    /// @notice Emitted when price feed is updated.
    event PriceFeedSet(address indexed feed);

    error OnlyKeeper();
    error PriceAlreadySet();
    error InvalidPrice();

    /// @param initialOwner Owner (sets feed and keeper).
    constructor(address initialOwner) Ownable(initialOwner) {}

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert OnlyKeeper();
        _;
    }

    /// @notice Sets the price feed (owner only).
    /// @param _feed IPriceFeed address (Chainlink-style).
    function setPriceFeed(address _feed) external onlyOwner {
        feed = IPriceFeed(_feed);
        emit PriceFeedSet(_feed);
    }

    /// @notice Sets the keeper (owner only).
    /// @param _keeper Keeper address.
    function setKeeper(address _keeper) external onlyOwner {
        keeper = _keeper;
        emit KeeperSet(_keeper);
    }

    /// @notice Returns current price from feed (for setting strike at epoch start).
    /// @return Current price from latest round.
    function getCurrentPrice() external view override returns (uint256) {
        return _readFeedPrice();
    }

    /// @notice Returns settlement price for an epoch; reverts if not set.
    /// @param epochId Epoch identifier.
    /// @return Settlement price.
    function getSettlementPrice(uint256 epochId) external view override returns (uint256) {
        uint256 price = settlementPrice[epochId];
        require(price != 0, "SettlementOracle: price not set");
        return price;
    }

    /// @notice Sets settlement price for an epoch (keeper only; once per epoch).
    /// @param epochId Epoch identifier.
    /// @param price Settlement price.
    function setSettlementPrice(uint256 epochId, uint256 price) external onlyKeeper {
        if (settlementPrice[epochId] != 0) revert PriceAlreadySet();
        if (price == 0) revert InvalidPrice();
        settlementPrice[epochId] = price;
        emit SettlementPriceSet(epochId, price);
    }

    /// @dev Reads latest price from feed; reverts if answer is negative.
    function _readFeedPrice() internal view returns (uint256) {
        (, int256 answer,,,) = feed.latestRoundData();
        require(answer >= 0, "SettlementOracle: invalid feed");
        return uint256(int256(answer));
    }
}
