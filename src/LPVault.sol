// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/IEpochController.sol";
import "./interfaces/ILPVault.sol";

/// @notice ERC-4626 compliant LP vault.
///
/// - Deposits are only allowed during the pre-epoch deposit window.
/// - Withdrawals/redemptions are only allowed once the previous epoch has settled.
/// - Premiums received are "donations" (no shares minted), increasing share price.
contract LPVault is ILPVault, ERC4626, Ownable {
    using SafeERC20 for IERC20;

    /// @notice Underlying collateral token (same as `asset()` in ERC-4626).
    IERC20 public immutable collateral;

    IEpochController public epochController;
    address public longGammaVault;

    event PremiumReceived(uint256 amount);
    event SettlementPaid(uint256 amount);

    error OnlyEpochController();
    error OnlyPremiumCaller();
    error DepositWindowClosed();
    error WithdrawBeforeSettlement();
    error InsufficientBalance();
    error NoController();

    constructor(address initialOwner, address collateral_)
        ERC20("Abitus LP Shares", "abitusLP")
        ERC4626(IERC20(collateral_))
        Ownable(initialOwner)
    {
        collateral = IERC20(collateral_);
    }

    function setEpochController(address controller_) external onlyOwner {
        epochController = IEpochController(controller_);
    }

    function setLongGammaVault(address vault_) external onlyOwner {
        longGammaVault = vault_;
    }

    // ---------------------------------------------------------------------
    // ERC-4626 primary interface (gated by epoch windows)
    // ---------------------------------------------------------------------

    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        _requireDepositWindow();
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override returns (uint256 assets) {
        _requireDepositWindow();
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
        _requireWithdrawWindow();
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets) {
        _requireWithdrawWindow();
        return super.redeem(shares, receiver, owner);
    }

    function roll(uint256) external pure {}

    // ---------------------------------------------------------------------
    // Protocol hooks
    // ---------------------------------------------------------------------

    function receivePremium(uint256 amount) external override {
        if (msg.sender != longGammaVault && msg.sender != address(epochController)) revert OnlyPremiumCaller();
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        emit PremiumReceived(amount);
    }

    function paySettlement(uint256 amount) external override {
        if (msg.sender != address(epochController)) revert OnlyEpochController();
        if (longGammaVault == address(0)) revert InsufficientBalance();

        uint256 balance = IERC20(asset()).balanceOf(address(this));
        if (amount > balance) revert InsufficientBalance();

        IERC20(asset()).safeTransfer(longGammaVault, amount);
        emit SettlementPaid(amount);
    }

    // ---------------------------------------------------------------------
    // Internal window helpers
    // ---------------------------------------------------------------------

    function _requireDepositWindow() internal view {
        if (address(epochController) == address(0)) revert NoController();
        uint256 currentId = epochController.getCurrentEpochId();
        uint256 epochStart = epochController.getEpochStartTime(currentId);
        uint256 end = epochController.getEpochEndTime(currentId);

        if (block.timestamp < epochStart || block.timestamp >= end) revert DepositWindowClosed();
    }

    function _requireWithdrawWindow() internal view {
        if (address(epochController) == address(0)) revert NoController();
        uint256 currentEpoch = epochController.getCurrentEpochId();
        if (currentEpoch == 0) revert WithdrawBeforeSettlement();
        if (!epochController.epochSettled(currentEpoch - 1)) revert WithdrawBeforeSettlement();
    }
}
