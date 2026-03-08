// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./interfaces/IEpochController.sol";
import "./interfaces/ILPVault.sol";

/// @title LPVault
/// @notice ERC-4626 compliant LP vault with epoch-gated deposits and withdrawals.
/// @dev Deposits are only allowed during the pre-epoch deposit window (strike not yet set).
///      Withdrawals/redemptions are only allowed once the previous epoch has settled.
///      Premiums received are "donations" (no shares minted), increasing share price.
contract LPVault is ILPVault, ERC4626, Ownable {
    using SafeERC20 for IERC20;

    /// @notice Underlying collateral token (ERC-4626 asset).
    IERC20 public immutable collateral;

    /// @notice Controller that defines epoch boundaries and triggers start/settle.
    IEpochController public epochController;
    /// @notice Long Gamma vault address (receives settlement and may send premium).
    address public longGammaVault;
    /// @notice Options market address (reserves collateral, may send premium).
    address public optionsMarket;
    /// @notice Total assets held in pending deposits (not yet activated).
    uint256 public totalPendingAssets;
    /// @notice Total collateral reserved for options settlements.
    uint256 public totalReservedCollateral;

    /// @notice Receipt for a deposit queued for the next epoch.
    struct PendingDepositReceipt {
        uint256 assets;
        uint256 epochId;
    }

    mapping(address => PendingDepositReceipt) private pendingDeposits;
    mapping(uint256 => uint256) private pendingAssetsByEpoch;
    mapping(uint256 => uint256) private claimableAssetsByEpoch;
    mapping(uint256 => uint256) private claimableSharesByEpoch;
    /// @notice Reserved collateral per epoch (released on settle).
    mapping(uint256 => uint256) public reservedCollateralByEpoch;

    /// @notice Emitted when premium is received (from Long Gamma or options market).
    event PremiumReceived(uint256 amount);
    /// @notice Emitted when settlement is paid (to Long Gamma or options).
    event SettlementPaid(uint256 amount);
    /// @notice Emitted when collateral is reserved for an epoch.
    event CollateralReserved(uint256 indexed epochId, uint256 amount);
    /// @notice Emitted when reserved collateral is released after settlement.
    event ReservedCollateralReleased(uint256 indexed epochId, uint256 amount);
    /// @notice Emitted when a deposit is queued for the next epoch.
    event PendingDepositQueued(
        address indexed owner, address indexed receiver, uint256 indexed epochId, uint256 assets
    );
    /// @notice Emitted when pending deposit shares are claimed.
    event PendingDepositClaimed(
        address indexed owner, address indexed receiver, uint256 indexed epochId, uint256 assets, uint256 shares
    );

    error OnlyEpochController();
    error OnlyPremiumCaller();
    error OnlyOptionsMarket();
    error WithdrawBeforeSettlement();
    error InsufficientBalance();
    error NoController();

    /// @param initialOwner Owner of the contract (can set controller, vaults, market).
    /// @param collateral_ ERC-20 collateral token address.
    constructor(address initialOwner, address collateral_)
        ERC20("Abitus LP Shares", "abitusLP")
        ERC4626(IERC20(collateral_))
        Ownable(initialOwner)
    {
        collateral = IERC20(collateral_);
    }

    /// @notice Sets the epoch controller (owner only).
    /// @param controller_ IEpochController address.
    function setEpochController(address controller_) external onlyOwner {
        epochController = IEpochController(controller_);
    }

    /// @notice Sets the Long Gamma vault (owner only).
    /// @param vault_ Long Gamma vault address.
    function setLongGammaVault(address vault_) external onlyOwner {
        longGammaVault = vault_;
    }

    /// @notice Sets the options market (owner only).
    /// @param market_ Options market address.
    function setOptionsMarket(address market_) external onlyOwner {
        optionsMarket = market_;
    }

    /// @notice Deposits assets for receiver; immediate if epoch open, else queued for next epoch.
    /// @param assets Amount of collateral to deposit.
    /// @param receiver Recipient of shares (or pending receipt).
    /// @return shares Shares minted (0 if queued).
    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        _requireController();

        if (_isCurrentEpochOpen()) {
            return super.deposit(assets, receiver);
        }

        _claimPendingShares(receiver, receiver);
        _queuePendingDeposit(_msgSender(), receiver, assets);
        return 0;
    }

    /// @notice Mints shares for receiver; only when current epoch is open.
    /// @param shares Shares to mint.
    /// @param receiver Recipient of shares.
    /// @return assets Assets consumed.
    function mint(uint256 shares, address receiver) public override returns (uint256 assets) {
        _requireController();
        if (!_isCurrentEpochOpen()) revert ERC4626ExceededMaxMint(receiver, shares, 0);
        return super.mint(shares, receiver);
    }

    /// @notice Withdraws assets to receiver from owner; requires previous epoch settled.
    /// @param assets Amount of assets to withdraw.
    /// @param receiver Recipient of assets.
    /// @param owner Owner of shares.
    /// @return shares Shares burned.
    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
        _claimPendingShares(owner, owner);
        _requireWithdrawWindow();
        return super.withdraw(assets, receiver, owner);
    }

    /// @notice Redeems shares for assets to receiver from owner; requires previous epoch settled.
    /// @param shares Shares to redeem.
    /// @param receiver Recipient of assets.
    /// @param owner Owner of shares.
    /// @return assets Assets sent to receiver.
    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets) {
        _claimPendingShares(owner, owner);
        _requireWithdrawWindow();
        return super.redeem(shares, receiver, owner);
    }

    /// @notice No-op for ERC-4626 compatibility (roll not used).
    function roll(uint256) external pure {}

    /// @notice Receives premium from Long Gamma vault, options market, or EpochController.
    /// @param amount Amount of collateral to pull from caller.
    function receivePremium(uint256 amount) external override {
        if (msg.sender != longGammaVault && msg.sender != optionsMarket && msg.sender != address(epochController)) {
            revert OnlyPremiumCaller();
        }
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        emit PremiumReceived(amount);
    }

    /// @notice Pays settlement to Long Gamma vault (EpochController only).
    /// @param amount Amount to transfer to Long Gamma vault.
    function paySettlement(uint256 amount) external override {
        if (msg.sender != address(epochController)) revert OnlyEpochController();
        if (longGammaVault == address(0)) revert InsufficientBalance();

        if (amount > IERC20(asset()).balanceOf(address(this))) revert InsufficientBalance();

        IERC20(asset()).safeTransfer(longGammaVault, amount);
        emit SettlementPaid(amount);
    }

    /// @notice Pays settlement to a receiver from reserved collateral for an epoch (EpochController only).
    /// @param receiver Recipient address.
    /// @param amount Amount to transfer.
    /// @param epochId Epoch whose reserved collateral is debited.
    function paySettlementTo(address receiver, uint256 amount, uint256 epochId) external override {
        if (msg.sender != address(epochController)) revert OnlyEpochController();
        if (receiver == address(0)) revert InsufficientBalance();
        if (amount > reservedCollateralByEpoch[epochId]) revert InsufficientBalance();
        if (amount > IERC20(asset()).balanceOf(address(this))) revert InsufficientBalance();

        reservedCollateralByEpoch[epochId] -= amount;
        totalReservedCollateral -= amount;

        IERC20(asset()).safeTransfer(receiver, amount);
        emit SettlementPaid(amount);
    }

    /// @notice Reserves collateral for an epoch (options market only).
    /// @param epochId Epoch to reserve for.
    /// @param amount Amount to reserve.
    function reserveCollateral(uint256 epochId, uint256 amount) external override {
        if (msg.sender != optionsMarket) revert OnlyOptionsMarket();
        if (amount > _availableCollateralForReserve()) revert InsufficientBalance();

        reservedCollateralByEpoch[epochId] += amount;
        totalReservedCollateral += amount;

        emit CollateralReserved(epochId, amount);
    }

    /// @notice Releases all reserved collateral for an epoch (EpochController only).
    /// @param epochId Epoch whose reservation to release.
    /// @return released Amount released.
    function releaseReservedCollateral(uint256 epochId) external override returns (uint256 released) {
        if (msg.sender != address(epochController)) revert OnlyEpochController();

        released = reservedCollateralByEpoch[epochId];
        if (released == 0) {
            return 0;
        }

        reservedCollateralByEpoch[epochId] = 0;
        totalReservedCollateral -= released;

        emit ReservedCollateralReleased(epochId, released);
    }

    /// @notice Activates pending deposits for the given epoch (EpochController only).
    /// @param epochId Epoch that just started.
    function onEpochStarted(uint256 epochId) external override {
        if (msg.sender != address(epochController)) revert OnlyEpochController();
        _activatePendingDeposits(epochId);
    }

    /// @notice Claims pending shares for msg.sender to receiver (if receipt is claimable).
    /// @param receiver Recipient of shares.
    /// @return shares Shares claimed (0 if none or not yet claimable).
    function claimPendingShares(address receiver) external returns (uint256 shares) {
        return _claimPendingShares(_msgSender(), receiver);
    }

    /// @notice Returns the pending deposit receipt for an owner.
    /// @param owner Account to query.
    /// @return assets Queued assets.
    /// @return epochId Epoch for which deposit is queued.
    function pendingDepositOf(address owner) external view returns (uint256 assets, uint256 epochId) {
        PendingDepositReceipt memory receipt = pendingDeposits[owner];
        return (receipt.assets, receipt.epochId);
    }

    /// @notice Previews how many shares would be claimed for owner's pending deposit.
    /// @param owner Account with pending deposit.
    /// @return Shares that would be received on claim (0 if not claimable).
    function previewPendingShares(address owner) external view returns (uint256) {
        PendingDepositReceipt memory receipt = pendingDeposits[owner];

        if (!_isClaimableReceipt(receipt)) {
            return 0;
        }

        return _previewClaimedShares(receipt.epochId, receipt.assets);
    }

    /// @notice Total assets backing shares (balance minus pending and reserved).
    /// @return Amount of collateral considered as vault assets for share pricing.
    function totalAssets() public view override returns (uint256) {
        uint256 balance = IERC20(asset()).balanceOf(address(this));
        uint256 lockedAssets = totalPendingAssets + totalReservedCollateral;

        if (balance <= lockedAssets) {
            return 0;
        }

        return balance - lockedAssets;
    }

    function _requireDepositWindow() internal view {
        _requireController();
        if (!_isCurrentEpochOpen()) revert ERC4626ExceededMaxDeposit(_msgSender(), 0, 0);
    }

    function _requireWithdrawWindow() internal view {
        _requireController();
        uint256 currentEpoch = epochController.getCurrentEpochId();
        if (currentEpoch == 0) revert WithdrawBeforeSettlement();
        if (!epochController.epochSettled(currentEpoch - 1)) revert WithdrawBeforeSettlement();
    }

    function _requireController() internal view {
        if (address(epochController) == address(0)) revert NoController();
    }

    function _isCurrentEpochOpen() internal view returns (bool) {
        uint256 currentId = epochController.getCurrentEpochId();
        return epochController.strikeForEpoch(currentId) == 0;
    }

    function _queuePendingDeposit(address payer, address receiver, uint256 assets) internal {
        uint256 targetEpoch = epochController.getCurrentEpochId() + 1;
        PendingDepositReceipt memory receipt = pendingDeposits[receiver];

        if (receipt.assets != 0) {
            require(receipt.epochId == targetEpoch, "LPVault: pending epoch mismatch");
        }

        IERC20(asset()).safeTransferFrom(payer, address(this), assets);

        pendingDeposits[receiver] = PendingDepositReceipt({assets: receipt.assets + assets, epochId: targetEpoch});
        pendingAssetsByEpoch[targetEpoch] += assets;
        totalPendingAssets += assets;

        emit PendingDepositQueued(receiver, receiver, targetEpoch, assets);
    }

    function _activatePendingDeposits(uint256 epochId) internal {
        uint256 assets = pendingAssetsByEpoch[epochId];

        if (assets == 0) {
            return;
        }

        uint256 activeAssets = totalAssets();
        uint256 shares = _previewActivatedShares(assets, activeAssets);

        totalPendingAssets -= assets;
        pendingAssetsByEpoch[epochId] = 0;
        claimableAssetsByEpoch[epochId] = assets;
        claimableSharesByEpoch[epochId] = shares;

        _mint(address(this), shares);
    }

    function _previewActivatedShares(uint256 assets, uint256 activeAssets) internal view returns (uint256) {
        uint256 supply = totalSupply();

        if (supply == 0 || activeAssets == 0) {
            return assets;
        }

        return Math.mulDiv(assets, supply, activeAssets, Math.Rounding.Floor);
    }

    function _claimPendingShares(address owner, address receiver) internal returns (uint256 shares) {
        PendingDepositReceipt memory receipt = pendingDeposits[owner];

        if (!_isClaimableReceipt(receipt)) {
            return 0;
        }

        shares = _previewClaimedShares(receipt.epochId, receipt.assets);

        claimableAssetsByEpoch[receipt.epochId] -= receipt.assets;
        claimableSharesByEpoch[receipt.epochId] -= shares;
        delete pendingDeposits[owner];

        _transfer(address(this), receiver, shares);

        emit PendingDepositClaimed(owner, receiver, receipt.epochId, receipt.assets, shares);
    }

    function _isClaimableReceipt(PendingDepositReceipt memory receipt) internal view returns (bool) {
        return receipt.assets != 0 && claimableAssetsByEpoch[receipt.epochId] != 0;
    }

    function _previewClaimedShares(uint256 epochId, uint256 assets) internal view returns (uint256) {
        uint256 remainingAssets = claimableAssetsByEpoch[epochId];
        uint256 remainingShares = claimableSharesByEpoch[epochId];

        if (remainingAssets == 0 || remainingShares == 0) {
            return 0;
        }

        if (assets == remainingAssets) {
            return remainingShares;
        }

        return Math.mulDiv(assets, remainingShares, remainingAssets, Math.Rounding.Floor);
    }

    function _availableCollateralForReserve() internal view returns (uint256) {
        uint256 balance = IERC20(asset()).balanceOf(address(this));
        uint256 lockedAssets = totalPendingAssets + totalReservedCollateral;

        if (balance <= lockedAssets) {
            return 0;
        }

        return balance - lockedAssets;
    }
}
