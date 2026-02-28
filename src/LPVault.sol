// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IEpochController.sol";
import "./interfaces/ILongGammaVault.sol";
import "./interfaces/ILPVault.sol";

contract LPVault is ILPVault, ERC20, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable collateral;
    IEpochController public epochController;
    address public longGammaVault;

    event Deposit(address indexed user, uint256 amount, uint256 shares);
    event Withdraw(address indexed user, uint256 shares, uint256 amount);
    event PremiumReceived(uint256 amount);
    event SettlementPaid(uint256 amount);

    error OnlyEpochController();
    error OnlyPremiumCaller();
    error DepositWindowClosed();
    error WithdrawBeforeSettlement();
    error InsufficientBalance();

    constructor(
        address initialOwner,
        address _collateral
    ) ERC20("Abitus LP Shares", "abitusLP") Ownable(initialOwner) {
        collateral = IERC20(_collateral);
    }

    function setEpochController(address _controller) external onlyOwner {
        epochController = IEpochController(_controller);
    }

    function setLongGammaVault(address _vault) external onlyOwner {
        longGammaVault = _vault;
    }

    function deposit(uint256 amount) external {
        if (address(epochController) == address(0)) revert DepositWindowClosed();
        uint256 epochStart = epochController.getEpochStartTime(epochController.getCurrentEpochId());
        if (block.timestamp >= epochStart) revert DepositWindowClosed();

        collateral.safeTransferFrom(msg.sender, address(this), amount);
        uint256 shares = _sharesForAssets(amount);
        _mint(msg.sender, shares);
        emit Deposit(msg.sender, amount, shares);
    }

    function withdraw(uint256 shares) external {
        if (address(epochController) == address(0)) revert WithdrawBeforeSettlement();
        uint256 currentEpoch = epochController.getCurrentEpochId();
        if (currentEpoch == 0) revert WithdrawBeforeSettlement();
        if (!epochController.epochSettled(currentEpoch - 1)) revert WithdrawBeforeSettlement();

        uint256 amount = _assetsForShares(shares);
        _burn(msg.sender, shares);
        collateral.safeTransfer(msg.sender, amount);
        emit Withdraw(msg.sender, shares, amount);
    }

    function roll(uint256) external pure {}

    function receivePremium(uint256 amount) external override {
        if (msg.sender != longGammaVault && msg.sender != address(epochController)) revert OnlyPremiumCaller();
        collateral.safeTransferFrom(msg.sender, address(this), amount);
        emit PremiumReceived(amount);
    }

    function paySettlement(uint256 amount) external override {
        if (msg.sender != address(epochController)) revert OnlyEpochController();
        if (longGammaVault == address(0)) revert InsufficientBalance();
        uint256 balance = collateral.balanceOf(address(this));
        if (amount > balance) revert InsufficientBalance();

        collateral.safeTransfer(longGammaVault, amount);
        emit SettlementPaid(amount);
    }

    function _sharesForAssets(uint256 assets) internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return assets;
        uint256 total = collateral.balanceOf(address(this));
        return (assets * supply) / total;
    }

    function _assetsForShares(uint256 shares) internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        uint256 total = collateral.balanceOf(address(this));
        return (shares * total) / supply;
    }
}
