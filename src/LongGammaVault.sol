// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./interfaces/IEpochController.sol";
import "./interfaces/IQuoterRegistry.sol";
import "./interfaces/ILongGammaVault.sol";
import "./interfaces/ILPVault.sol";

/// @title LongGammaVault
/// @notice ERC-4626 compliant Long Gamma vault; deposits are quote-gated (signed premium), withdrawals after settlement.
/// @dev Uses ERC-4626 for accounting; deposit/mint without quote disabled when quoterRegistry is set. Use depositWithQuote / mintWithQuote.
contract LongGammaVault is ILongGammaVault, ERC4626, Ownable, EIP712 {
    using SafeERC20 for IERC20;

    /// @notice Underlying collateral token (same as asset()).
    IERC20 public immutable collateral;

    /// @notice EIP-712 typehash for Quote.
    bytes32 public constant QUOTE_TYPEHASH =
        keccak256("Quote(uint256 epochId,uint256 notional,uint256 premium,uint256 expiry)");

    /// @notice Epoch controller (deposit/withdraw windows).
    IEpochController public epochController;
    /// @notice Registry of allowed quote signers.
    IQuoterRegistry public quoterRegistry;
    /// @notice LP vault (receives premium from quote deposits).
    ILPVault public lpVault;

    /// @notice Gross notional deposited in the current epoch (for cap).
    uint256 public totalDepositsCurrentEpoch;
    /// @notice Cap on gross notional per epoch (0 = no cap).
    uint256 public cap;

    /// @notice Emitted on quote-gated deposit/mint (includes premium sent to LP).
    event QuoteDeposit(
        address indexed caller, address indexed receiver, uint256 notional, uint256 premium, uint256 shares
    );
    /// @notice Emitted when settlement is received from EpochController.
    event SettlementReceived(uint256 amount);

    error OnlyEpochController();
    error DepositWindowClosed();
    error WithdrawBeforeSettlement();
    error InvalidQuote();
    error CapExceeded();
    error DepositRequiresQuote();
    error MintRequiresQuote();

    /// @param initialOwner Owner (sets controller, quoter registry, LP vault, cap).
    /// @param collateral_ Collateral token address.
    constructor(address initialOwner, address collateral_)
        ERC20("Abitus Long Gamma Shares", "abitusLG")
        ERC4626(IERC20(collateral_))
        Ownable(initialOwner)
        EIP712("AbitusLongGammaQuote", "1")
    {
        collateral = IERC20(collateral_);
    }

    // ---------------------------------------------------------------------
    // Admin wiring
    // ---------------------------------------------------------------------

    /// @notice Sets the epoch controller (owner only).
    /// @param controller_ IEpochController address.
    function setEpochController(address controller_) external onlyOwner {
        epochController = IEpochController(controller_);
    }

    /// @notice Sets the quoter registry (owner only).
    /// @param registry_ IQuoterRegistry address.
    function setQuoterRegistry(address registry_) external onlyOwner {
        quoterRegistry = IQuoterRegistry(registry_);
    }

    /// @notice Sets the LP vault (owner only).
    /// @param lpVault_ ILPVault address.
    function setLPVault(address lpVault_) external onlyOwner {
        lpVault = ILPVault(lpVault_);
    }

    /// @notice Sets the per-epoch notional cap (owner only); 0 = no cap.
    /// @param cap_ Cap in collateral units.
    function setCap(uint256 cap_) external onlyOwner {
        cap = cap_;
    }

    // ---------------------------------------------------------------------
    // ERC-4626 primary interface (withdraws are gated; deposits require quotes)
    // ---------------------------------------------------------------------

    /// @notice Deposit without quote (only when quoterRegistry is not set).
    /// @param assets Amount of collateral.
    /// @param receiver Share recipient.
    /// @return shares Shares minted.
    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        if (address(quoterRegistry) != address(0)) revert DepositRequiresQuote();
        _requireDepositWindow();
        _requireCap(assets);
        // No premium path (for dev / emergency).
        shares = super.deposit(assets, receiver);
        totalDepositsCurrentEpoch += assets;
    }

    /// @notice Mint without quote (only when quoterRegistry is not set).
    /// @param shares Shares to mint.
    /// @param receiver Share recipient.
    /// @return assets Assets consumed.
    function mint(uint256 shares, address receiver) public override returns (uint256 assets) {
        if (address(quoterRegistry) != address(0)) revert MintRequiresQuote();
        _requireDepositWindow();
        assets = previewMint(shares);
        _requireCap(assets);
        assets = super.mint(shares, receiver);
        totalDepositsCurrentEpoch += assets;
    }

    /// @notice Withdraw assets to receiver from owner; requires previous epoch settled.
    /// @param assets Amount of assets to withdraw.
    /// @param receiver Recipient of assets.
    /// @param owner Owner of shares.
    /// @return shares Shares burned.
    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
        _requireWithdrawWindow();
        return super.withdraw(assets, receiver, owner);
    }

    /// @notice Redeem shares for assets to receiver from owner; requires previous epoch settled.
    /// @param shares Shares to redeem.
    /// @param receiver Recipient of assets.
    /// @param owner Owner of shares.
    /// @return assets Assets sent to receiver.
    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets) {
        _requireWithdrawWindow();
        return super.redeem(shares, receiver, owner);
    }

    // ---------------------------------------------------------------------
    // Quote-gated deposit/mint (production path)
    // ---------------------------------------------------------------------

    /// @notice Deposit with signed quote; premium sent to LP vault, net assets get shares.
    /// @param assets Gross notional (collateral to transfer).
    /// @param receiver Share recipient.
    /// @param quote Signed quote (epochId, notional, premium, expiry).
    /// @param signature EIP-712 signature from a registered quoter.
    /// @return shares Shares minted for (assets - premium).
    function depositWithQuote(uint256 assets, address receiver, Quote calldata quote, bytes calldata signature)
        external
        returns (uint256 shares)
    {
        _requireDepositWindow();
        _requireCap(assets);

        _validateQuote(quote, assets);
        address signer = _recoverQuoteSigner(quote, signature);
        if (!quoterRegistry.isQuoter(signer)) revert InvalidQuote();

        uint256 premium = quote.premium;
        uint256 netAssets = assets - premium;
        shares = _previewDepositNet(netAssets);

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);

        if (premium > 0) {
            if (address(lpVault) == address(0)) revert InvalidQuote();
            IERC20(asset()).safeIncreaseAllowance(address(lpVault), premium);
            lpVault.receivePremium(premium);
        }

        _mint(receiver, shares);
        totalDepositsCurrentEpoch += assets;

        emit Deposit(msg.sender, receiver, assets, shares); // ERC-4626 event (gross assets, shares after fee)
        emit QuoteDeposit(msg.sender, receiver, assets, premium, shares);
    }

    /// @notice Mint shares with signed quote; quote.notional must equal netAssets + premium.
    /// @param shares Shares to mint.
    /// @param receiver Share recipient.
    /// @param quote Signed quote (notional = assets, premium deducted to LP).
    /// @param signature EIP-712 signature from a registered quoter.
    /// @return assets Gross assets pulled from caller.
    function mintWithQuote(uint256 shares, address receiver, Quote calldata quote, bytes calldata signature)
        external
        returns (uint256 assets)
    {
        _requireDepositWindow();

        uint256 netAssets = previewMint(shares);
        assets = netAssets + quote.premium;

        _requireCap(assets);
        _validateQuote(quote, assets);
        address signer = _recoverQuoteSigner(quote, signature);
        if (!quoterRegistry.isQuoter(signer)) revert InvalidQuote();

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);

        if (quote.premium > 0) {
            if (address(lpVault) == address(0)) revert InvalidQuote();
            IERC20(asset()).safeIncreaseAllowance(address(lpVault), quote.premium);
            lpVault.receivePremium(quote.premium);
        }

        _mint(receiver, shares);
        totalDepositsCurrentEpoch += assets;

        emit Deposit(msg.sender, receiver, assets, shares);
        emit QuoteDeposit(msg.sender, receiver, assets, quote.premium, shares);
    }

    /// @notice No-op for ERC-4626 compatibility.
    function roll(uint256) external pure {}

    // ---------------------------------------------------------------------
    // Protocol hooks
    // ---------------------------------------------------------------------

    /// @notice Receives settlement from EpochController (emits event; no transfer).
    /// @param amount Amount received.
    function receiveSettlement(uint256 amount) external override {
        if (msg.sender != address(epochController)) revert OnlyEpochController();
        emit SettlementReceived(amount);
    }

    /// @notice Hook when epoch starts; resets totalDepositsCurrentEpoch (EpochController only).
    function onEpochStarted(uint256) external override {
        if (msg.sender != address(epochController)) revert OnlyEpochController();
        totalDepositsCurrentEpoch = 0;
    }

    // ---------------------------------------------------------------------
    // ERC-4626 limits (window gating)
    // ---------------------------------------------------------------------

    /// @notice Max deposit for receiver (respects deposit window and cap).
    /// @param receiver Unused; deposit window and cap are global.
    /// @return Max assets that can be deposited now.
    function maxDeposit(address receiver) public view override returns (uint256) {
        _requireDepositWindow();
        if (cap == 0) return type(uint256).max;
        if (totalDepositsCurrentEpoch >= cap) return 0;
        return cap - totalDepositsCurrentEpoch;
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    function _requireDepositWindow() internal view {
        require(address(epochController) != address(0), "LongGammaVault: no controller");
        uint256 currentId = epochController.getCurrentEpochId();
        if (epochController.strikeForEpoch(currentId) != 0) revert DepositWindowClosed();
    }

    function _requireWithdrawWindow() internal view {
        require(address(epochController) != address(0), "LongGammaVault: no controller");
        uint256 currentEpoch = epochController.getCurrentEpochId();
        if (currentEpoch == 0) revert WithdrawBeforeSettlement();
        if (!epochController.epochSettled(currentEpoch - 1)) revert WithdrawBeforeSettlement();
    }

    function _requireCap(uint256 assets) internal view {
        if (cap == 0) return;
        if (totalDepositsCurrentEpoch + assets > cap) revert CapExceeded();
    }

    function _validateQuote(Quote calldata quote, uint256 assets) internal view {
        if (address(epochController) == address(0)) revert InvalidQuote();
        uint256 currentId = epochController.getCurrentEpochId();
        if (quote.epochId != currentId) revert InvalidQuote();
        if (quote.notional != assets) revert InvalidQuote();
        if (quote.premium > assets) revert InvalidQuote();
        if (quote.expiry < block.timestamp) revert InvalidQuote();
    }

    function _recoverQuoteSigner(Quote calldata quote, bytes calldata signature) internal view returns (address) {
        bytes32 structHash =
            keccak256(abi.encode(QUOTE_TYPEHASH, quote.epochId, quote.notional, quote.premium, quote.expiry));
        bytes32 digest = _hashTypedDataV4(structHash);
        return ECDSA.recover(digest, signature);
    }

    function _previewDepositNet(uint256 netAssets) internal view returns (uint256 shares) {
        uint256 supply = totalSupply();
        if (supply == 0) return netAssets;

        uint256 total = totalAssets();
        if (total == 0) return netAssets;

        return Math.mulDiv(netAssets, supply, total, Math.Rounding.Floor);
    }
}
