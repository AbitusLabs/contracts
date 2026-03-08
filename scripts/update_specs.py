#!/usr/bin/env python3
"""Update CONTRACT_SPECS.md sections 3.3--3.6, 4, 5, 6, 7 to match current implementation."""
import re

path = "CONTRACT_SPECS.md"

with open(path, "r", encoding="utf-8") as f:
    content = f.read()

# Section 3.3 LongGammaVault: replace from "### 3.3 LongGammaVault" to "### 3.4 LPVault" (exclusive)
old_33 = r"### 3\.3 LongGammaVault\n\n\*\*Responsibility\*\*.*?\n- `SettlementReceived\(uint256 amount\)`\.\n\n---\n\n### 3\.4 LPVault"
new_33 = """### 3.3 LongGammaVault

**Responsibility**  
ERC-4626 vault for long gamma strategy. Accept BTC.b deposits in pre-epoch window: with a signed quote from an authorized quoter (`depositWithQuote` / `mintWithQuote`), premium is sent to LPVault and net assets get shares; when `quoterRegistry` is not set, `deposit` / `mint` without quote are allowed (dev/emergency). At settlement receive PnL from controller (event only). Enforce per-epoch notional cap. Withdraw/redeem only after previous epoch settled.

**State**

- `IERC20 public immutable collateral` — BTC.b (same as ERC-4626 asset).
- `IEpochController public epochController`
- `IQuoterRegistry public quoterRegistry`
- `ILPVault public lpVault`
- `uint256 public totalDepositsCurrentEpoch` — gross notional in current epoch (for cap).
- `uint256 public cap` — max gross notional per epoch (0 = no cap).
- ERC-4626: single share token; `totalAssets()` is vault collateral balance.

**Key functions**

- `depositWithQuote(uint256 assets, address receiver, Quote quote, bytes signature)` — require deposit window (strike not set), cap not exceeded. Validate quote (epochId, notional == assets, premium <= assets, expiry). Recover signer from EIP-712, require `quoterRegistry.isQuoter(signer)`. Transfer assets from user; send premium to `lpVault.receivePremium(premium)`; mint shares for assets - premium. Update `totalDepositsCurrentEpoch += assets`. Emit `Deposit`, `QuoteDeposit`.
- `mintWithQuote(uint256 shares, address receiver, Quote quote, bytes signature)` — same; quote.notional = net assets for shares + premium.
- `deposit(assets, receiver)` / `mint(shares, receiver)` — only when `quoterRegistry` not set; otherwise revert. Same window and cap.
- `withdraw` / `redeem` — only when previous epoch settled; standard ERC-4626.
- `roll(uint256)` — no-op.
- `receiveSettlement(uint256 amount)` — EpochController only; emit `SettlementReceived(amount)` (controller already sent funds via LPVault).
- `onEpochStarted(uint256)` — EpochController only; reset `totalDepositsCurrentEpoch = 0`.

**Quote structure (EIP-712)**  
`Quote`: `epochId`, `notional`, `premium`, `expiry`. Domain: name `AbitusLongGammaQuote`, version `1`, chainId, verifyingContract = LongGammaVault.

**Authorizations**

- Owner: `setQuoterRegistry`, `setEpochController`, `setLPVault`, `setCap`.
- EpochController: `receiveSettlement`, `onEpochStarted`.
- Users: `depositWithQuote`, `mintWithQuote`, or `deposit`/`mint` when quoter not set; `withdraw`, `redeem`, `roll`.

**Events**

- `Deposit`, `QuoteDeposit`, `SettlementReceived`.

---

### 3.4 LPVault"""

content = re.sub(old_33, new_33, content, flags=re.DOTALL)

# Section 3.4 LPVault: replace full section
old_34 = r"### 3\.4 LPVault\n\n\*\*Responsibility\*\*.*?\n- `SettlementPaid\(uint256 amount\)`\.\n\n---\n\n### 3\.5 QuoterRegistry"
new_34 = """### 3.4 LPVault

**Responsibility**  
ERC-4626 LP vault. Accept BTC.b deposits: if current epoch is open (strike not set), mint shares immediately; else queue deposit for next epoch and mint shares when that epoch starts (user claims via `claimPendingShares`). Receive premium from LongGammaVault and OptionsMarket (and EpochController). At settlement pay PnL to LongGammaVault via `paySettlement(amount)`; pay options payout from reserved collateral via `paySettlementTo(receiver, amount, epochId)`. Reserve collateral per epoch when options are sold (`reserveCollateral`); release after settlement (`releaseReservedCollateral`). Withdraw/redeem only after previous epoch settled.

**State**

- `IERC20 public immutable collateral` — BTC.b.
- `IEpochController public epochController`
- `address public longGammaVault`, `address public optionsMarket`
- `uint256 public totalPendingAssets`, `uint256 public totalReservedCollateral`
- Pending deposit receipts per user (assets, epochId); claimable shares when epoch starts. `mapping(uint256 => uint256) public reservedCollateralByEpoch`.

**Key functions**

- `deposit(uint256 assets, address receiver)` — if current epoch open, mint shares immediately; else queue for next epoch (return 0 shares), user claims later via `claimPendingShares`.
- `mint(shares, receiver)` — only when current epoch open.
- `withdraw` / `redeem` — claim pending first if any; require previous epoch settled.
- `claimPendingShares(address receiver)` — claim queued deposit for msg.sender when epoch has started; transfer shares to receiver.
- `receivePremium(uint256 amount)` — callable by LongGammaVault, OptionsMarket, or EpochController; pull collateral from caller.
- `paySettlement(uint256 amount)` — EpochController only; transfer amount to longGammaVault.
- `paySettlementTo(address receiver, uint256 amount, uint256 epochId)` — EpochController only; debit reservedCollateralByEpoch[epochId], transfer to receiver (e.g. OptionsMarket).
- `reserveCollateral(uint256 epochId, uint256 amount)` — OptionsMarket only; increase reservedCollateralByEpoch, totalReservedCollateral.
- `releaseReservedCollateral(uint256 epochId)` — EpochController only; clear reservation for epoch.
- `onEpochStarted(uint256 epochId)` — EpochController only; activate pending deposits for that epoch (mint shares to vault, set claimable).

**Authorizations**

- Owner: `setEpochController`, `setLongGammaVault`, `setOptionsMarket`.
- LongGammaVault, OptionsMarket, EpochController: `receivePremium`.
- EpochController: `paySettlement`, `paySettlementTo`, `releaseReservedCollateral`, `onEpochStarted`.
- OptionsMarket: `reserveCollateral`.
- Users: `deposit`, `withdraw`, `redeem`, `claimPendingShares`, `roll`.

**Events**

- `Deposit`, `Withdraw`, `PremiumReceived`, `SettlementPaid`, `CollateralReserved`, `ReservedCollateralReleased`, `PendingDepositQueued`, `PendingDepositClaimed`.

---

### 3.5 QuoterRegistry"""

content = re.sub(old_34, new_34, content, flags=re.DOTALL)

# Section 3.5 QuoterRegistry: add sentence about OptionsMarket
content = content.replace(
    "Maintain set of addresses allowed to sign deposit quotes for LongGammaVault.",
    "Maintain set of addresses allowed to sign quotes for LongGammaVault (deposit quotes) and for OptionsMarket (option quotes)."
)

# Insert 3.6 OptionsMarket before "## 4. Interfaces"
old_4_intro = "## 4. Interfaces and Dependencies"
new_36_plus_4 = """### 3.6 OptionsMarket

**Responsibility**  
Market for buying call/put options per epoch with signed quotes. Each position is an ERC-721 NFT. Buyer sends premium to contract, which forwards it to LPVault via `receivePremium`; notional is reserved in LPVault via `reserveCollateral(epochId, notional)`. At settlement EpochController calls `previewEpochPayout(epochId, strike, settlementPrice)`, deducts fee, pays OptionsMarket via `lpVault.paySettlementTo(optionsMarket, optionsAfterFee, epochId)`, then `settleEpoch(epochId, strike, settlementPrice, optionsAfterFee)` and `lpVault.releaseReservedCollateral(epochId)`. Position owners claim payout via `claim(positionId)`; if epoch is underfunded, payout is pro-rata (fundedAmount / expectedPayout per position).

**State**

- `IERC20 public immutable collateral` — same as LPVault asset.
- `IEpochController public epochController`, `ILPVault public lpVault`, `IQuoterRegistry public quoterRegistry`
- `uint256 public nextPositionId`; `mapping(uint256 => Position) public positions` (epochId, notional, premium, claimable, isCall, claimed)
- Per-epoch: totalCallNotionalByEpoch, totalPutNotionalByEpoch, settledStrikeByEpoch, settlementPriceByEpoch, totalExpectedPayoutByEpoch, totalFundedPayoutByEpoch, epochSettlementRecorded
- `mapping(bytes32 => bool) public usedQuotes` — prevent replay

**Key functions**

- `buyOption(Quote quote, bytes signature)` — validate quote (buyer == msg.sender, epochId == current, strike not set, notional/premium/expiry). Recover signer, require quoterRegistry.isQuoter(signer). Mark digest used. Transfer premium from buyer to this, then lpVault.receivePremium(premium), lpVault.reserveCollateral(epochId, notional). Mint NFT to quote.buyer, store Position. Update totalCallNotionalByEpoch or totalPutNotionalByEpoch.
- `previewEpochPayout(epochId, strike, settlementPrice)` — view; sum of call payouts + put payouts for epoch (call: notional * (settlement - strike) / settlement when settlement > strike; put: notional * (strike - settlement) / strike when strike > settlement).
- `settleEpoch(epochId, strike, settlementPrice, fundedAmount)` — EpochController only; store strike, price, expectedPayout, fundedAmount; set epochSettlementRecorded[epochId] = true.
- `onEpochStarted(epochId)` — EpochController only; no-op.
- `claim(uint256 positionId)` — owner or approved; require epoch settled, not already claimed. Compute position payout (call or put formula); apply pro-rata if expectedPayout > 0: amount = amount * fundedPayout / expectedPayout. Transfer collateral to owner, mark claimed.

**Quote structure (EIP-712)**  
`Quote`: `buyer`, `epochId`, `isCall`, `notional`, `premium`, `expiry`. Domain: name `AbitusOptionsQuote`, version `1`, chainId, verifyingContract = OptionsMarket.

**Authorizations**

- Owner: `setEpochController`, `setLPVault`, `setQuoterRegistry`.
- EpochController: `settleEpoch`, `onEpochStarted`.
- Users: `buyOption`, `claim` (owner or approved).

**Events**

- `OptionPurchased`, `EpochSettlementRecorded`, `OptionClaimed`.

---

## 4. Interfaces and Dependencies"""

content = content.replace(old_4_intro, new_36_plus_4)

# Section 4: update dependency tree and deploy order
old_deps = """```
SettlementOracle
  - no dependency on other Abitus contracts

EpochController
  - depends on: SettlementOracle, LongGammaVault, LPVault

LongGammaVault
  - depends on: EpochController, QuoterRegistry, LPVault (to send premium), Collateral (BTC.b)

LPVault
  - depends on: EpochController, LongGammaVault (to send settlement), Collateral (BTC.b)

QuoterRegistry
  - no dependency on other Abitus contracts
```

Deploy order: SettlementOracle, QuoterRegistry, LPVault, LongGammaVault, EpochController. Then: set vaults on EpochController, set EpochController and QuoterRegistry on LongGammaVault, set EpochController on LPVault, set keeper on SettlementOracle and EpochController, add quoter address to QuoterRegistry."""
new_deps = """```
SettlementOracle
  - no dependency on other Abitus contracts

QuoterRegistry
  - no dependency on other Abitus contracts

EpochController
  - depends on: SettlementOracle, LongGammaVault, LPVault, IOptionsMarket (optional)

LongGammaVault
  - depends on: EpochController, QuoterRegistry, LPVault (to send premium), Collateral (BTC.b)

LPVault
  - depends on: EpochController, LongGammaVault (settlement), OptionsMarket (premium, reserve/release), Collateral (BTC.b)

OptionsMarket
  - depends on: EpochController, LPVault, QuoterRegistry, Collateral (BTC.b)
```

Deploy order: SettlementOracle, QuoterRegistry, LPVault, LongGammaVault, OptionsMarket, EpochController. Then: set vaults and options market on EpochController, set EpochController and QuoterRegistry and LPVault on LongGammaVault, set EpochController and LongGammaVault and OptionsMarket on LPVault, set EpochController and LPVault and QuoterRegistry on OptionsMarket, set keeper on SettlementOracle and EpochController, add quoter address to QuoterRegistry."""
content = content.replace(old_deps, new_deps)

# Section 5: update invariants
old_inv = """## 5. Invariants (On-Chain Guarantees)

- Long Gamma max loss ≤ deposited capital (premium paid; no leverage).
- LP vault always fully collateralized: total settlement paid ≤ vault balance; max 50% utilization per epoch.
- Total exposure (Long Gamma notional) ≤ deployed LP capital (enforced by cap and utilization).
- No leverage: no borrowing; all positions fully backed by collateral.
- No early withdrawal: withdraw/roll only when epoch is settled (or in designated window).
- Settlement price set only for past expiry and once per epoch.
- Quote signer must be in QuoterRegistry; quote expiry and epoch must be valid."""
new_inv = """## 5. Invariants (On-Chain Guarantees)

- Long Gamma max loss ≤ deposited capital (premium paid; no leverage).
- LP vault: total settlement paid ≤ vault balance; reserved collateral ≤ available balance; pending + reserved ≤ balance.
- Options: payout per epoch limited by fundedAmount (pro-rata if underfunded); reserved collateral released after settlement.
- No leverage: no borrowing; all positions fully backed by collateral.
- No early withdrawal: vault withdraw/redeem only when previous epoch settled; options claim only after epoch settled.
- Settlement price set only once per epoch; strike set only at epoch start.
- Quote signer must be in QuoterRegistry; quote expiry and epoch must be valid; quote digest not already used (options)."""
content = content.replace(old_inv, new_inv)

# Section 6: add OptionsMarket and IOptionsMarket
old_layout = """```
2_contracts/
  src/
    SettlementOracle.sol
    EpochController.sol
    LongGammaVault.sol
    LPVault.sol
    QuoterRegistry.sol
    interfaces/
      ISettlementOracle.sol
      IEpochController.sol
      ILongGammaVault.sol
      ILPVault.sol
      IQuoterRegistry.sol
  test/
    SettlementOracle.t.sol
    EpochController.t.sol
    LongGammaVault.t.sol
    LPVault.t.sol
    integration/
      EpochFlow.t.sol
  script/
    DeployDemo.s.sol
  foundry.toml
  README.md
```"""
new_layout = """```
2_contracts/
  src/
    SettlementOracle.sol
    EpochController.sol
    LongGammaVault.sol
    LPVault.sol
    OptionsMarket.sol
    QuoterRegistry.sol
    interfaces/
      ISettlementOracle.sol
      IEpochController.sol
      ILongGammaVault.sol
      ILPVault.sol
      IOptionsMarket.sol
      IQuoterRegistry.sol
  test/
    SettlementOracle.t.sol
    EpochController.t.sol
    LongGammaVault.t.sol
    LPVault.t.sol
    OptionsMarket.t.sol
    integration/
      EpochFlow.t.sol
  script/
    DeployDemo.s.sol
    DeployAvalancheMainnet.s.sol
  foundry.toml
  README.md
```"""
content = content.replace(old_layout, new_layout)

# Section 7: add OptionsMarket quote type
old_eip = """## 7. EIP-712 Quote Type

Suggested type name: `Quote`. Fields: `epochId` (uint256), `notional` (uint256), `premium` (uint256), `expiry` (uint256). Domain: name `AbitusLongGammaQuote`, version `1`, chainId, verifyingContract = LongGammaVault address. Backend signs this; LongGammaVault recovers signer and checks QuoterRegistry."""
new_eip = """## 7. EIP-712 Quote Types

**LongGammaVault (deposit quote)**  
Type name: `Quote`. Fields: `epochId` (uint256), `notional` (uint256), `premium` (uint256), `expiry` (uint256). Domain: name `AbitusLongGammaQuote`, version `1`, chainId, verifyingContract = LongGammaVault address. Backend signs this; LongGammaVault recovers signer and checks QuoterRegistry.

**OptionsMarket (option quote)**  
Type name: `Quote`. Fields: `buyer` (address), `epochId` (uint256), `isCall` (bool), `notional` (uint256), `premium` (uint256), `expiry` (uint256). Domain: name `AbitusOptionsQuote`, version `1`, chainId, verifyingContract = OptionsMarket address. Backend signs this; OptionsMarket recovers signer and checks QuoterRegistry."""
content = content.replace(old_eip, new_eip)

with open(path, "w", encoding="utf-8") as f:
    f.write(content)

print("CONTRACT_SPECS.md updated.")
