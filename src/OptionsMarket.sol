// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./interfaces/IEpochController.sol";
import "./interfaces/ILPVault.sol";
import "./interfaces/IOptionsMarket.sol";
import "./interfaces/IQuoterRegistry.sol";

/// @title OptionsMarket
/// @notice Market for buying call/put options per epoch with signed quotes; positions are ERC-721 NFTs.
/// @dev Premium goes to LP vault; collateral is reserved in LP vault and released on settle; payout is pro-rata if underfunded.
contract OptionsMarket is IOptionsMarket, ERC721, Ownable, EIP712 {
    using SafeERC20 for IERC20;

    /// @notice Collateral token (same as LP vault asset).
    IERC20 public immutable collateral;

    /// @notice EIP-712 typehash for Quote.
    bytes32 public constant QUOTE_TYPEHASH =
        keccak256("Quote(address buyer,uint256 epochId,bool isCall,uint256 notional,uint256 premium,uint256 expiry)");

    /// @notice Option position (one per NFT).
    struct Position {
        uint256 epochId;
        uint256 notional;
        uint256 premium;
        uint256 claimable;
        bool isCall;
        bool claimed;
    }

    /// @notice Epoch controller (current epoch, strike, settle hook).
    IEpochController public epochController;
    /// @notice LP vault (receive premium, reserve/release collateral, receive settlement).
    ILPVault public lpVault;
    /// @notice Registry of allowed quote signers.
    IQuoterRegistry public quoterRegistry;

    /// @notice Next position id (ERC-721 token id).
    uint256 public nextPositionId;

    mapping(uint256 => Position) public positions;
    mapping(bytes32 => bool) public usedQuotes;
    mapping(uint256 => uint256) public totalCallNotionalByEpoch;
    mapping(uint256 => uint256) public totalPutNotionalByEpoch;
    mapping(uint256 => uint256) public settledStrikeByEpoch;
    mapping(uint256 => uint256) public settlementPriceByEpoch;
    mapping(uint256 => uint256) public totalFundedPayoutByEpoch;
    mapping(uint256 => uint256) public totalExpectedPayoutByEpoch;
    mapping(uint256 => bool) public epochSettlementRecorded;

    /// @notice Emitted when an option is purchased.
    event OptionPurchased(
        uint256 indexed positionId,
        address indexed buyer,
        uint256 indexed epochId,
        bool isCall,
        uint256 notional,
        uint256 premium
    );
    /// @notice Emitted when EpochController records settlement for an epoch.
    event EpochSettlementRecorded(
        uint256 indexed epochId, uint256 strike, uint256 settlementPrice, uint256 expectedPayout, uint256 fundedAmount
    );
    /// @notice Emitted when a position is claimed.
    event OptionClaimed(uint256 indexed positionId, address indexed owner, uint256 amount);

    error OnlyEpochController();
    error InvalidQuote();
    error EpochNotSettled();
    error EpochAlreadySettled();
    error PositionAlreadyClaimed();

    /// @param initialOwner Owner (sets controller, LP vault, quoter registry).
    /// @param collateral_ Collateral token address.
    constructor(address initialOwner, address collateral_)
        ERC721("Abitus Options Position", "ABOP")
        Ownable(initialOwner)
        EIP712("AbitusOptionsQuote", "1")
    {
        collateral = IERC20(collateral_);
    }

    /// @notice Sets the epoch controller (owner only).
    /// @param controller_ IEpochController address.
    function setEpochController(address controller_) external onlyOwner {
        epochController = IEpochController(controller_);
    }

    /// @notice Sets the LP vault (owner only).
    /// @param lpVault_ ILPVault address.
    function setLPVault(address lpVault_) external onlyOwner {
        lpVault = ILPVault(lpVault_);
    }

    /// @notice Sets the quoter registry (owner only).
    /// @param registry_ IQuoterRegistry address.
    function setQuoterRegistry(address registry_) external onlyOwner {
        quoterRegistry = IQuoterRegistry(registry_);
    }

    /// @notice Buys an option with a signed quote; mints NFT position and reserves collateral in LP vault.
    /// @param quote Quote (buyer, epochId, isCall, notional, premium, expiry).
    /// @param signature EIP-712 signature from a registered quoter.
    /// @return positionId ERC-721 token id of the position.
    function buyOption(Quote calldata quote, bytes calldata signature) external override returns (uint256 positionId) {
        _validateQuote(quote);

        bytes32 digest = _quoteDigest(quote);
        if (usedQuotes[digest]) revert InvalidQuote();

        address signer = ECDSA.recover(digest, signature);
        if (!quoterRegistry.isQuoter(signer)) revert InvalidQuote();

        usedQuotes[digest] = true;

        collateral.safeTransferFrom(msg.sender, address(this), quote.premium);
        collateral.safeIncreaseAllowance(address(lpVault), quote.premium);
        lpVault.receivePremium(quote.premium);
        lpVault.reserveCollateral(quote.epochId, quote.notional);

        positionId = nextPositionId++;
        positions[positionId] = Position({
            epochId: quote.epochId,
            notional: quote.notional,
            premium: quote.premium,
            claimable: 0,
            isCall: quote.isCall,
            claimed: false
        });

        if (quote.isCall) {
            totalCallNotionalByEpoch[quote.epochId] += quote.notional;
        } else {
            totalPutNotionalByEpoch[quote.epochId] += quote.notional;
        }

        _safeMint(quote.buyer, positionId);

        emit OptionPurchased(positionId, quote.buyer, quote.epochId, quote.isCall, quote.notional, quote.premium);
    }

    /// @notice Previews total payout for an epoch (call + put) given strike and settlement price.
    /// @param epochId Epoch identifier.
    /// @param strike Strike price.
    /// @param settlementPrice Settlement price.
    /// @return Total payout for the epoch.
    function previewEpochPayout(uint256 epochId, uint256 strike, uint256 settlementPrice)
        public
        view
        override
        returns (uint256)
    {
        uint256 callPayout = _previewCallPayout(totalCallNotionalByEpoch[epochId], strike, settlementPrice);
        uint256 putPayout = _previewPutPayout(totalPutNotionalByEpoch[epochId], strike, settlementPrice);
        return callPayout + putPayout;
    }

    /// @notice Records epoch settlement (EpochController only); stores strike, price, expected and funded payout.
    /// @param epochId Epoch identifier.
    /// @param strike Strike for the epoch.
    /// @param settlementPrice Settlement price.
    /// @param fundedAmount Amount funded from LP vault for this epoch.
    function settleEpoch(uint256 epochId, uint256 strike, uint256 settlementPrice, uint256 fundedAmount)
        external
        override
    {
        if (msg.sender != address(epochController)) revert OnlyEpochController();
        if (epochSettlementRecorded[epochId]) revert EpochAlreadySettled();

        uint256 expectedPayout = previewEpochPayout(epochId, strike, settlementPrice);

        settledStrikeByEpoch[epochId] = strike;
        settlementPriceByEpoch[epochId] = settlementPrice;
        totalExpectedPayoutByEpoch[epochId] = expectedPayout;
        totalFundedPayoutByEpoch[epochId] = fundedAmount;
        epochSettlementRecorded[epochId] = true;

        emit EpochSettlementRecorded(epochId, strike, settlementPrice, expectedPayout, fundedAmount);
    }

    /// @notice No-op hook when epoch starts (EpochController only).
    function onEpochStarted(uint256) external override {
        if (msg.sender != address(epochController)) revert OnlyEpochController();
    }

    /// @notice Claims payout for a position (owner or approved); sends collateral to owner.
    /// @param positionId ERC-721 token id of the position.
    /// @return amount Collateral amount sent to owner (pro-rata if epoch underfunded).
    function claim(uint256 positionId) external returns (uint256 amount) {
        address owner = ownerOf(positionId);
        if (!_isAuthorized(owner, _msgSender(), positionId)) {
            revert ERC721InsufficientApproval(_msgSender(), positionId);
        }

        Position storage position = positions[positionId];
        if (position.claimed) revert PositionAlreadyClaimed();
        if (!epochSettlementRecorded[position.epochId]) revert EpochNotSettled();

        amount =
            _positionPayout(position, settledStrikeByEpoch[position.epochId], settlementPriceByEpoch[position.epochId]);

        uint256 expectedPayout = totalExpectedPayoutByEpoch[position.epochId];
        if (amount != 0 && expectedPayout != 0) {
            amount =
                Math.mulDiv(amount, totalFundedPayoutByEpoch[position.epochId], expectedPayout, Math.Rounding.Floor);
        }

        position.claimed = true;
        position.claimable = amount;

        if (amount != 0) {
            collateral.safeTransfer(owner, amount);
        }

        emit OptionClaimed(positionId, owner, amount);
    }

    function _validateQuote(Quote calldata quote) internal view {
        if (
            address(epochController) == address(0) || address(lpVault) == address(0)
                || address(quoterRegistry) == address(0)
        ) {
            revert InvalidQuote();
        }
        if (quote.buyer != msg.sender) revert InvalidQuote();
        if (quote.notional == 0 || quote.premium == 0 || quote.premium > quote.notional) revert InvalidQuote();
        if (quote.expiry < block.timestamp) revert InvalidQuote();
        uint256 currentId = epochController.getCurrentEpochId();
        if (quote.epochId != currentId) revert InvalidQuote();
        if (epochController.strikeForEpoch(currentId) != 0) revert InvalidQuote();
    }

    function _quoteDigest(Quote calldata quote) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                QUOTE_TYPEHASH, quote.buyer, quote.epochId, quote.isCall, quote.notional, quote.premium, quote.expiry
            )
        );
        return _hashTypedDataV4(structHash);
    }

    function _positionPayout(Position storage position, uint256 strike, uint256 settlementPrice)
        internal
        view
        returns (uint256)
    {
        if (position.isCall) {
            return _previewCallPayout(position.notional, strike, settlementPrice);
        }

        return _previewPutPayout(position.notional, strike, settlementPrice);
    }

    function _previewCallPayout(uint256 notional, uint256 strike, uint256 settlementPrice)
        internal
        pure
        returns (uint256)
    {
        if (settlementPrice <= strike || settlementPrice == 0) {
            return 0;
        }

        return Math.mulDiv(notional, settlementPrice - strike, settlementPrice, Math.Rounding.Floor);
    }

    function _previewPutPayout(uint256 notional, uint256 strike, uint256 settlementPrice)
        internal
        pure
        returns (uint256)
    {
        if (strike <= settlementPrice || strike == 0) {
            return 0;
        }

        return Math.mulDiv(notional, strike - settlementPrice, strike, Math.Rounding.Floor);
    }
}
