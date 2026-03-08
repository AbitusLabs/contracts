// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/ISettlementOracle.sol";
import "./interfaces/IEpochController.sol";
import "./interfaces/ILongGammaVault.sol";
import "./interfaces/ILPVault.sol";
import "./interfaces/IOptionsMarket.sol";

/// @title EpochController
/// @notice Orchestrates epoch lifecycle: start (set strike from oracle), settle (pay Long Gamma and options).
/// @dev Keeper calls startEpoch() at epoch start and anyone can call settleEpoch() after epoch end.
contract EpochController is IEpochController, Ownable {
    /// @notice Duration of one epoch in seconds.
    uint256 public constant EPOCH_DURATION = 1 days;

    /// @notice Oracle for current price (strike) and per-epoch settlement price.
    ISettlementOracle public oracle;
    /// @notice Long Gamma vault (receives settlement).
    ILongGammaVault private _longGammaVault;
    /// @notice Options market (optional; receives settlement and triggers release of reserved collateral).
    IOptionsMarket private _optionsMarket;
    /// @notice LP vault (pays settlement, receives premium, holds reserved collateral).
    ILPVault public lpVault;
    /// @notice Timestamp of epoch 0 start (anchor).
    uint256 public immutable EPOCH_ANCHOR;

    /// @notice Strike price per epoch (set on start).
    mapping(uint256 => uint256) public strikeForEpoch;
    /// @notice Whether each epoch has been settled.
    mapping(uint256 => bool) public override epochSettled;

    /// @notice Address allowed to call startEpoch.
    address public keeper;
    /// @notice Recipient of protocol fees (basis points deducted from payouts).
    address public feeRecipient;
    /// @notice Fee in basis points (e.g. 100 = 1%).
    uint16 public feeBps;

    /// @notice Emitted when an epoch is started (strike set).
    event EpochStarted(uint256 indexed epochId, uint256 strike);
    /// @notice Emitted when an epoch is settled (payouts sent).
    event EpochSettled(uint256 indexed epochId, uint256 settlementPrice, uint256 payout);

    error OnlyKeeper();
    error EpochNotStarted();
    error EpochNotEnded();
    error SettlementAlreadySet();
    error EpochAlreadySettled();
    error InvalidVaults();

    /// @param initialOwner Owner (sets keeper, oracle, vaults, fee).
    /// @param epochAnchor Unix timestamp of epoch 0 start.
    constructor(address initialOwner, uint256 epochAnchor) Ownable(initialOwner) {
        EPOCH_ANCHOR = epochAnchor;
    }

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert OnlyKeeper();
        _;
    }

    /// @notice Current epoch id from anchor and duration.
    /// @return Epoch identifier (0 before anchor).
    function getCurrentEpochId() public view override returns (uint256) {
        if (block.timestamp < EPOCH_ANCHOR) return 0;
        return (block.timestamp - EPOCH_ANCHOR) / EPOCH_DURATION;
    }

    /// @notice Long Gamma vault address.
    /// @return Address of the Long Gamma vault.
    function longGammaVault() external view override returns (address) {
        return address(_longGammaVault);
    }

    /// @notice Options market address.
    /// @return Address of the options market or zero.
    function optionsMarket() external view override returns (address) {
        return address(_optionsMarket);
    }

    /// @notice Start timestamp of an epoch.
    /// @param epochId Epoch identifier.
    /// @return Unix timestamp.
    function getEpochStartTime(uint256 epochId) external view override returns (uint256) {
        return EPOCH_ANCHOR + epochId * EPOCH_DURATION;
    }

    /// @notice End timestamp of an epoch.
    /// @param epochId Epoch identifier.
    /// @return Unix timestamp.
    function getEpochEndTime(uint256 epochId) external view override returns (uint256) {
        return EPOCH_ANCHOR + (epochId + 1) * EPOCH_DURATION;
    }

    /// @notice Sets the keeper (owner only).
    /// @param _keeper Keeper address.
    function setKeeper(address _keeper) external onlyOwner {
        keeper = _keeper;
    }

    /// @notice Sets the fee recipient (owner only).
    /// @param _recipient Fee recipient address.
    function setFeeRecipient(address _recipient) external onlyOwner {
        feeRecipient = _recipient;
    }

    /// @notice Sets the fee in basis points (owner only).
    /// @param _bps Fee in basis points (e.g. 100 = 1%).
    function setFeeBps(uint16 _bps) external onlyOwner {
        feeBps = _bps;
    }

    /// @notice Sets Long Gamma vault and LP vault (owner only).
    /// @param newLongGammaVault Long Gamma vault.
    /// @param newLpVault LP vault.
    function setVaults(ILongGammaVault newLongGammaVault, ILPVault newLpVault) external onlyOwner {
        if (address(newLongGammaVault) == address(0) || address(newLpVault) == address(0)) revert InvalidVaults();
        _longGammaVault = newLongGammaVault;
        lpVault = newLpVault;
    }

    /// @notice Sets the options market (owner only).
    /// @param newOptionsMarket Options market (can be zero to disable).
    function setOptionsMarket(IOptionsMarket newOptionsMarket) external onlyOwner {
        _optionsMarket = newOptionsMarket;
    }

    /// @notice Sets the settlement oracle (owner only).
    /// @param _oracle Settlement oracle.
    function setOracle(ISettlementOracle _oracle) external onlyOwner {
        oracle = _oracle;
    }

    /// @notice Starts the current epoch: sets strike from oracle, notifies vaults and options market (keeper only).
    function startEpoch() external onlyKeeper {
        uint256 epochId = getCurrentEpochId();
        if (strikeForEpoch[epochId] != 0) revert SettlementAlreadySet();

        uint256 epochStart = EPOCH_ANCHOR + epochId * EPOCH_DURATION;
        if (block.timestamp < epochStart) revert EpochNotStarted();

        uint256 strike = oracle.getCurrentPrice();
        strikeForEpoch[epochId] = strike;
        lpVault.onEpochStarted(epochId);
        _longGammaVault.onEpochStarted(epochId);
        if (address(_optionsMarket) != address(0)) {
            _optionsMarket.onEpochStarted(epochId);
        }
        emit EpochStarted(epochId, strike);
    }

    /// @notice Settles an epoch after end time: pays Long Gamma and options, releases reserved collateral.
    /// @param epochId Epoch to settle.
    function settleEpoch(uint256 epochId) external {
        uint256 endTime = EPOCH_ANCHOR + (epochId + 1) * EPOCH_DURATION;
        if (block.timestamp < endTime) revert EpochNotEnded();
        if (epochSettled[epochId]) revert EpochAlreadySettled();

        uint256 settlementPrice = oracle.getSettlementPrice(epochId);
        uint256 strike = strikeForEpoch[epochId];
        require(strike != 0, "EpochController: strike not set");

        uint256 longGammaPayout = _payoff(strike, settlementPrice);
        uint256 longGammaAfterFee = _deductFee(longGammaPayout);

        lpVault.paySettlement(longGammaAfterFee);
        _longGammaVault.receiveSettlement(longGammaAfterFee);

        uint256 optionsAfterFee = 0;
        if (address(_optionsMarket) != address(0)) {
            uint256 optionsPayout = _optionsMarket.previewEpochPayout(epochId, strike, settlementPrice);
            optionsAfterFee = _deductFee(optionsPayout);
            if (optionsAfterFee != 0) {
                lpVault.paySettlementTo(address(_optionsMarket), optionsAfterFee, epochId);
            }
            _optionsMarket.settleEpoch(epochId, strike, settlementPrice, optionsAfterFee);
            lpVault.releaseReservedCollateral(epochId);
        }

        epochSettled[epochId] = true;
        emit EpochSettled(epochId, settlementPrice, longGammaAfterFee + optionsAfterFee);
    }

    /// @dev Long Gamma payoff: |strike - settlement|.
    function _payoff(uint256 strike, uint256 settlement) internal pure returns (uint256) {
        return strike >= settlement ? strike - settlement : settlement - strike;
    }

    /// @dev Deducts fee (feeBps) to feeRecipient if set.
    function _deductFee(uint256 amount) internal view returns (uint256) {
        if (feeBps == 0 || feeRecipient == address(0)) return amount;
        return (amount * (10000 - feeBps)) / 10000;
    }
}
