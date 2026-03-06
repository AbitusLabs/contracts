// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/ISettlementOracle.sol";
import "./interfaces/IEpochController.sol";
import "./interfaces/ILongGammaVault.sol";
import "./interfaces/ILPVault.sol";

contract EpochController is IEpochController, Ownable {
    uint256 public constant EPOCH_DURATION = 5 minutes;

    ISettlementOracle public oracle;
    ILongGammaVault private _longGammaVault;
    ILPVault public lpVault;
    uint256 public immutable EPOCH_ANCHOR;

    mapping(uint256 => uint256) public strikeForEpoch;
    mapping(uint256 => bool) public override epochSettled;

    address public keeper;
    address public feeRecipient;
    uint16 public feeBps;

    event EpochStarted(uint256 indexed epochId, uint256 strike);
    event EpochSettled(uint256 indexed epochId, uint256 settlementPrice, uint256 payout);

    error OnlyKeeper();
    error EpochNotStarted();
    error EpochNotEnded();
    error SettlementAlreadySet();
    error EpochAlreadySettled();
    error InvalidVaults();

    constructor(address initialOwner, uint256 epochAnchor) Ownable(initialOwner) {
        EPOCH_ANCHOR = epochAnchor;
    }

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert OnlyKeeper();
        _;
    }

    function getCurrentEpochId() public view override returns (uint256) {
        if (block.timestamp < EPOCH_ANCHOR) return 0;
        return (block.timestamp - EPOCH_ANCHOR) / EPOCH_DURATION;
    }

    function longGammaVault() external view override returns (address) {
        return address(_longGammaVault);
    }

    function getEpochStartTime(uint256 epochId) external view override returns (uint256) {
        return EPOCH_ANCHOR + epochId * EPOCH_DURATION;
    }

    function getEpochEndTime(uint256 epochId) external view override returns (uint256) {
        return EPOCH_ANCHOR + (epochId + 1) * EPOCH_DURATION;
    }

    function setKeeper(address _keeper) external onlyOwner {
        keeper = _keeper;
    }

    function setFeeRecipient(address _recipient) external onlyOwner {
        feeRecipient = _recipient;
    }

    function setFeeBps(uint16 _bps) external onlyOwner {
        feeBps = _bps;
    }

    function setVaults(ILongGammaVault newLongGammaVault, ILPVault newLpVault) external onlyOwner {
        if (address(newLongGammaVault) == address(0) || address(newLpVault) == address(0)) revert InvalidVaults();
        _longGammaVault = newLongGammaVault;
        lpVault = newLpVault;
    }

    function setOracle(ISettlementOracle _oracle) external onlyOwner {
        oracle = _oracle;
    }

    function startEpoch() external onlyKeeper {
        uint256 epochId = getCurrentEpochId();
        if (strikeForEpoch[epochId] != 0) revert SettlementAlreadySet();

        uint256 epochStart = EPOCH_ANCHOR + epochId * EPOCH_DURATION;
        if (block.timestamp < epochStart) revert EpochNotStarted();

        uint256 strike = oracle.getCurrentPrice();
        strikeForEpoch[epochId] = strike;
        _longGammaVault.onEpochStarted(epochId);
        emit EpochStarted(epochId, strike);
    }

    function settleEpoch(uint256 epochId) external {
        uint256 endTime = EPOCH_ANCHOR + (epochId + 1) * EPOCH_DURATION;
        if (block.timestamp < endTime) revert EpochNotEnded();
        if (epochSettled[epochId]) revert EpochAlreadySettled();

        uint256 settlementPrice = oracle.getSettlementPrice(epochId);
        uint256 strike = strikeForEpoch[epochId];
        require(strike != 0, "EpochController: strike not set");

        uint256 payout = _payoff(strike, settlementPrice);
        uint256 payoutAfterFee = _deductFee(payout);

        lpVault.paySettlement(payoutAfterFee);
        _longGammaVault.receiveSettlement(payoutAfterFee);

        epochSettled[epochId] = true;
        emit EpochSettled(epochId, settlementPrice, payoutAfterFee);
    }

    function _payoff(uint256 strike, uint256 settlement) internal pure returns (uint256) {
        return strike >= settlement ? strike - settlement : settlement - strike;
    }

    function _deductFee(uint256 amount) internal view returns (uint256) {
        if (feeBps == 0 || feeRecipient == address(0)) return amount;
        return (amount * (10000 - feeBps)) / 10000;
    }
}
