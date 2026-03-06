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

/// @notice ERC-4626 compliant Long Gamma vault (shares represent claim on vault assets).
///
/// Deposits are quote-gated (premium depends on the signed quote). ERC-4626 is still used
/// for accounting + withdrawals/redemptions. To deposit with a quote use `depositWithQuote`.
contract LongGammaVault is ILongGammaVault, ERC4626, Ownable, EIP712 {
    using SafeERC20 for IERC20;

    /// @notice Underlying collateral token (same as `asset()` in ERC-4626).
    IERC20 public immutable collateral;

    bytes32 public constant QUOTE_TYPEHASH =
        keccak256("Quote(uint256 epochId,uint256 notional,uint256 premium,uint256 expiry)");

    IEpochController public epochController;
    IQuoterRegistry public quoterRegistry;
    ILPVault public lpVault;

    uint256 public totalDepositsCurrentEpoch; // gross notional deposited this epoch
    uint256 public cap; // gross notional cap per epoch

    event QuoteDeposit(
        address indexed caller, address indexed receiver, uint256 notional, uint256 premium, uint256 shares
    );
    event SettlementReceived(uint256 amount);

    error OnlyEpochController();
    error DepositWindowClosed();
    error WithdrawBeforeSettlement();
    error InvalidQuote();
    error CapExceeded();
    error DepositRequiresQuote();
    error MintRequiresQuote();

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

    function setEpochController(address controller_) external onlyOwner {
        epochController = IEpochController(controller_);
    }

    function setQuoterRegistry(address registry_) external onlyOwner {
        quoterRegistry = IQuoterRegistry(registry_);
    }

    function setLPVault(address lpVault_) external onlyOwner {
        lpVault = ILPVault(lpVault_);
    }

    function setCap(uint256 cap_) external onlyOwner {
        cap = cap_;
    }

    // ---------------------------------------------------------------------
    // ERC-4626 primary interface (withdraws are gated; deposits require quotes)
    // ---------------------------------------------------------------------

    /// @dev Standard ERC-4626 `deposit` is disabled when a quoterRegistry is configured.
    ///      Use `depositWithQuote`.
    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        if (address(quoterRegistry) != address(0)) revert DepositRequiresQuote();
        _requireDepositWindow();
        _requireCap(assets);
        // No premium path (for dev / emergency).
        shares = super.deposit(assets, receiver);
        totalDepositsCurrentEpoch += assets;
    }

    /// @dev Standard ERC-4626 `mint` is disabled when a quoterRegistry is configured.
    ///      Use `mintWithQuote`.
    function mint(uint256 shares, address receiver) public override returns (uint256 assets) {
        if (address(quoterRegistry) != address(0)) revert MintRequiresQuote();
        _requireDepositWindow();
        assets = previewMint(shares);
        _requireCap(assets);
        assets = super.mint(shares, receiver);
        totalDepositsCurrentEpoch += assets;
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
        _requireWithdrawWindow();
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets) {
        _requireWithdrawWindow();
        return super.redeem(shares, receiver, owner);
    }

    // ---------------------------------------------------------------------
    // Quote-gated deposit/mint (production path)
    // ---------------------------------------------------------------------

    /// @notice Deposit gross `assets` with a signed quote; mints shares for `assets - premium`.
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

    /// @notice Mint `shares` with a signed quote; quote.notional must equal (netAssets + premium).
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

    function roll(uint256) external pure {}

    // ---------------------------------------------------------------------
    // Protocol hooks
    // ---------------------------------------------------------------------

    function receiveSettlement(uint256 amount) external override {
        if (msg.sender != address(epochController)) revert OnlyEpochController();
        emit SettlementReceived(amount);
    }

    function onEpochStarted(uint256) external override {
        if (msg.sender != address(epochController)) revert OnlyEpochController();
        totalDepositsCurrentEpoch = 0;
    }

    // ---------------------------------------------------------------------
    // ERC-4626 limits (window gating)
    // ---------------------------------------------------------------------

    function maxDeposit(address) public view override returns (uint256) {
        if (!_depositWindowOpen()) return 0;
        if (cap == 0) return type(uint256).max;
        if (totalDepositsCurrentEpoch >= cap) return 0;
        return cap - totalDepositsCurrentEpoch;
    }

    function maxMint(address) public view override returns (uint256) {
        return _depositWindowOpen() ? type(uint256).max : 0;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return _withdrawWindowOpen() ? super.maxWithdraw(owner) : 0;
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return _withdrawWindowOpen() ? super.maxRedeem(owner) : 0;
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    function _depositEpochId() internal view returns (uint256) {
        uint256 current = epochController.getCurrentEpochId();

        // If we're still before current epoch start, deposits target current epoch.
        uint256 currentStart = epochController.getEpochStartTime(current);
        if (block.timestamp < currentStart) {
            return current;
        }

        // Otherwise, deposits target the next epoch.
        return current + 1;
    }

    function _depositWindowOpen() internal view returns (bool) {
        if (address(epochController) == address(0)) return false;

        uint256 depositEpoch = _depositEpochId();
        uint256 depositEpochStart = epochController.getEpochStartTime(depositEpoch);

        return block.timestamp < depositEpochStart;
    }

    function _withdrawWindowOpen() internal view returns (bool) {
        if (address(epochController) == address(0)) return false;
        uint256 currentEpoch = epochController.getCurrentEpochId();
        if (currentEpoch == 0) return false;
        return epochController.epochSettled(currentEpoch - 1);
    }

    function _requireDepositWindow() internal view {
        if (!_depositWindowOpen()) revert DepositWindowClosed();
    }

    function _requireWithdrawWindow() internal view {
        if (!_withdrawWindowOpen()) revert WithdrawBeforeSettlement();
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
