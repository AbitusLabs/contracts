// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./interfaces/IEpochController.sol";
import "./interfaces/IQuoterRegistry.sol";
import "./interfaces/ILongGammaVault.sol";
import "./interfaces/ILPVault.sol";

contract LongGammaVault is ILongGammaVault, ERC20, Ownable, EIP712 {
    using SafeERC20 for IERC20;

    struct Quote {
        uint256 epochId;
        uint256 notional;
        uint256 premium;
        uint256 expiry;
    }

    bytes32 public constant QUOTE_TYPEHASH =
        keccak256("Quote(uint256 epochId,uint256 notional,uint256 premium,uint256 expiry)");

    IERC20 public immutable collateral;
    IEpochController public epochController;
    IQuoterRegistry public quoterRegistry;
    ILPVault public lpVault;
    uint256 public totalDepositsCurrentEpoch;
    uint256 public cap;

    event Deposit(address indexed user, uint256 amount, uint256 premium, uint256 shares);
    event Withdraw(address indexed user, uint256 shares, uint256 amount);
    event SettlementReceived(uint256 amount);

    error OnlyEpochController();
    error DepositWindowClosed();
    error WithdrawBeforeSettlement();
    error InvalidQuote();
    error CapExceeded();

    constructor(
        address initialOwner,
        address _collateral
    ) ERC20("Abitus Long Gamma Shares", "abitusLG") Ownable(initialOwner) EIP712("AbitusLongGammaQuote", "1") {
        collateral = IERC20(_collateral);
    }

    function setEpochController(address _controller) external onlyOwner {
        epochController = IEpochController(_controller);
    }

    function setQuoterRegistry(address _registry) external onlyOwner {
        quoterRegistry = IQuoterRegistry(_registry);
    }

    function setLPVault(address _lpVault) external onlyOwner {
        lpVault = ILPVault(_lpVault);
    }

    function setCap(uint256 _cap) external onlyOwner {
        cap = _cap;
    }

    function deposit(uint256 amount, Quote calldata quote, bytes calldata signature) external {
        _requireDepositWindow();
        address signer = _recoverQuoteSigner(quote, signature);
        require(quoterRegistry.isQuoter(signer), "LongGammaVault: invalid quoter");
        _validateQuote(quote, amount);

        if (totalDepositsCurrentEpoch + amount > cap) revert CapExceeded();

        collateral.safeTransferFrom(msg.sender, address(this), amount);

        if (quote.premium > 0 && address(lpVault) != address(0)) {
            require(collateral.approve(address(lpVault), quote.premium), "LongGammaVault: approve failed");
            lpVault.receivePremium(quote.premium);
        }

        uint256 netAmount = amount - quote.premium;
        uint256 shares = _sharesForAssets(netAmount);
        _mint(msg.sender, shares);
        totalDepositsCurrentEpoch += amount;

        emit Deposit(msg.sender, amount, quote.premium, shares);
    }

    function withdraw(uint256 shares) external {
        _requireWithdrawWindow();
        uint256 amount = _assetsForShares(shares);
        _burn(msg.sender, shares);
        collateral.safeTransfer(msg.sender, amount);
        emit Withdraw(msg.sender, shares, amount);
    }

    function roll(uint256) external pure {}

    function receiveSettlement(uint256 amount) external override {
        if (msg.sender != address(epochController)) revert OnlyEpochController();
        emit SettlementReceived(amount);
    }

    function onEpochStarted(uint256) external {
        if (msg.sender != address(epochController)) revert OnlyEpochController();
        totalDepositsCurrentEpoch = 0;
    }

    function _requireDepositWindow() internal view {
        require(address(epochController) != address(0), "LongGammaVault: no controller");
        uint256 currentId = epochController.getCurrentEpochId();
        uint256 epochStart = epochController.getEpochStartTime(currentId);
        if (block.timestamp >= epochStart) revert DepositWindowClosed();
    }

    function _requireWithdrawWindow() internal view {
        require(address(epochController) != address(0), "LongGammaVault: no controller");
        uint256 currentEpoch = epochController.getCurrentEpochId();
        if (currentEpoch == 0) revert WithdrawBeforeSettlement();
        if (!epochController.epochSettled(currentEpoch - 1)) revert WithdrawBeforeSettlement();
    }

    function _validateQuote(Quote calldata quote, uint256 amount) internal view {
        uint256 currentId = epochController.getCurrentEpochId();
        if (quote.epochId != currentId) revert InvalidQuote();
        if (quote.notional != amount) revert InvalidQuote();
        if (quote.premium > amount) revert InvalidQuote();
        if (quote.expiry < block.timestamp) revert InvalidQuote();
    }

    function _recoverQuoteSigner(Quote calldata quote, bytes calldata signature) internal view returns (address) {
        bytes32 structHash = keccak256(abi.encode(QUOTE_TYPEHASH, quote.epochId, quote.notional, quote.premium, quote.expiry));
        bytes32 digest = _hashTypedDataV4(structHash);
        return ECDSA.recover(digest, signature);
    }

    function _sharesForAssets(uint256 assets) internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return assets;
        uint256 total = collateral.balanceOf(address(this));
        if (total == 0) return assets;
        return (assets * supply) / total;
    }

    function _assetsForShares(uint256 shares) internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        uint256 total = collateral.balanceOf(address(this));
        return (shares * total) / supply;
    }
}
