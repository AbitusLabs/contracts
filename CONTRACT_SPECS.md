# Abitus — Contract Specifications

Detailed specifications for the Abitus on-chain contracts. Target: **Foundry** project on Avalanche. Collateral and underlying: **BTC.b** only. Epoch: **24 hours**, fixed daily start (e.g. 00:00 UTC).

References: [8_architecture/ARCHITECTURE.md](../8_architecture/ARCHITECTURE.md), [8_architecture/MVP.md](../8_architecture/MVP.md).

---

## 1. Contract List and Roles

| # | Contract | Purpose |
|---|----------|---------|
| 1 | **SettlementOracle** | Price feed adapter; current price (strike) and settlement price per epoch; keeper sets settlement. |
| 2 | **EpochController** | Epoch lifecycle, strike storage, `startEpoch()`, `settleEpoch()`; orchestrates vaults, options market, and oracle. |
| 3 | **LongGammaVault** | Strategy vault: deposit with signed quote (or without quote when quoter registry not set), withdraw/roll, ERC20 shares; receives PnL from LP at settlement. |
| 4 | **LPVault** | LP vault: deposit (immediate or queued for next epoch), withdraw/roll, ERC20 shares; receives premium from Long Gamma and OptionsMarket; pays PnL and reserves/releases collateral for options. |
| 5 | **OptionsMarket** | Options market: buy call/put with signed quote (ERC-721 positions); premium to LP vault, collateral reserved in LP vault; settlement and claim after epoch end. |
| 6 | **QuoterRegistry** | Authorized quoter addresses for EIP-712 quote verification; used by LongGammaVault and OptionsMarket. |

**Total: 6 core contracts.** Fee recipient is a simple address on EpochController (no separate ProtocolTreasury contract).

---

## 2. Authorizations and Access Control

### 2.1 Summary Table

| Contract | Role / Function | Who |
|----------|-----------------|-----|
| **SettlementOracle** | `setSettlementPrice(epochId, price)` | KEEPER only |
| SettlementOracle | `setPriceFeed(address)` | OWNER only |
| SettlementOracle | `setKeeper(address)` | OWNER only |
| **EpochController** | `startEpoch()` | KEEPER only |
| EpochController | `settleEpoch(epochId)` | Permissionless (anyone once epoch ended) |
| EpochController | `setKeeper(address)`, `setFeeRecipient(address)`, `setFeeBps(uint16)` | OWNER only |
| EpochController | `setVaults(LongGammaVault, LPVault)` | OWNER only |
| EpochController | `setOptionsMarket(IOptionsMarket)` | OWNER only |
| **LongGammaVault** | `depositWithQuote(assets, receiver, quote, signature)` | Any user (quote from authorized quoter) |
| LongGammaVault | `mintWithQuote(shares, receiver, quote, signature)` | Any user (quote from authorized quoter) |
| LongGammaVault | `deposit(assets, receiver)` / `mint(shares, receiver)` | Any user (only when quoterRegistry not set) |
| LongGammaVault | `withdraw` / `redeem` / `roll` | Any user (own shares) |
| LongGammaVault | `setQuoterRegistry(addr)`, `setEpochController(addr)`, `setLPVault(addr)`, `setCap(uint256)` | OWNER only |
| **LPVault** | `deposit(assets, receiver)` | Any user (immediate if epoch open, else queued for next epoch) |
| LPVault | `withdraw` / `redeem` / `roll` | Any user (own shares) |
| LPVault | `claimPendingShares(receiver)` | Any user (claim queued deposit when epoch started) |
| LPVault | `setEpochController(addr)`, `setLongGammaVault(addr)`, `setOptionsMarket(addr)` | OWNER only |
| LPVault | `receivePremium(uint256)` | LongGammaVault, OptionsMarket, or EpochController |
| LPVault | `paySettlement(uint256)` | EpochController only |
| LPVault | `paySettlementTo(receiver, amount, epochId)` | EpochController only |
| LPVault | `reserveCollateral(epochId, amount)` | OptionsMarket only |
| LPVault | `releaseReservedCollateral(epochId)` | EpochController only |
| LPVault | `onEpochStarted(epochId)` | EpochController only |
| **OptionsMarket** | `buyOption(quote, signature)` | Any user (quote from authorized quoter) |
| OptionsMarket | `claim(positionId)` | Owner or approved (after epoch settled) |
| OptionsMarket | `setEpochController(addr)`, `setLPVault(addr)`, `setQuoterRegistry(addr)` | OWNER only |
| OptionsMarket | `settleEpoch(epochId, strike, settlementPrice, fundedAmount)` | EpochController only |
| OptionsMarket | `onEpochStarted(epochId)` | EpochController only |
| **QuoterRegistry** | `addQuoter(address)` / `removeQuoter(address)` | OWNER only |
| QuoterRegistry | `isQuoter(address)` (view) | Anyone |

### 2.2 Role Definitions

- **OWNER**: Admin; sets oracles, keeper, fee recipient, quoters, vault links. Prefer multisig in production.
- **KEEPER**: Bot (Chainlink Automation, Gelato, or custom). Calls `setSettlementPrice` on oracle and `startEpoch()` / `settleEpoch()` on controller. Optionally `settleEpoch` can be permissionless.
- **Authorized quoter**: EOA or contract whose EIP-712 signature is accepted by LongGammaVault (deposit quotes) and by OptionsMarket (option quotes). Backend signer address must be registered in QuoterRegistry.

### 2.3 Deposit Windows and Withdrawals

- **LongGammaVault**: Deposits (with or without quote) allowed only when current epoch strike is not yet set (pre-epoch window). Withdrawals/redeem only after previous epoch is settled.
- **LPVault**: Deposits allowed anytime; if current epoch is open (strike not set), shares are minted immediately; otherwise the deposit is queued for the next epoch and shares are claimable after that epoch starts via `claimPendingShares`. Withdrawals/redeem only after previous epoch is settled.
- **OptionsMarket**: Options can be bought only when current epoch strike is not yet set. Claims only after epoch is settled.
- No early withdrawal: vault withdraw/roll only when epoch is settled; options claim only after settlement.

---

## 3. Contract Specifications

### 3.1 SettlementOracle

**Responsibility**  
Provide current BTC.b price (for strike at epoch start) and settlement price per epoch (for PnL at expiry). Abstract over price feed (Chainlink or equivalent).

**State**

- `IPriceFeed feed` — external price feed (e.g. Chainlink aggregator).
- `mapping(uint256 epochId => uint256) public settlementPrice` — settlement price for each epoch; 0 means not set.
- `address public keeper` — only keeper can call `setSettlementPrice`.
- `address public owner` — can set feed and keeper.

**Key functions**

- `getCurrentPrice() view returns (uint256)` — returns latest price from feed (scaled, e.g. 8 decimals). Used at epoch start to fix strike.
- `getSettlementPrice(uint256 epochId) view returns (uint256)` — returns stored settlement price for epoch; reverts if not set.
- `setSettlementPrice(uint256 epochId, uint256 price)` — sets settlement price for epoch. Requirements: caller is keeper; `epochId` corresponds to an expiry that is in the past; settlement price for that epoch not already set (idempotent once set). Optionally require that `epochId` is the expected “next” unsettled epoch to avoid out-of-order writes.

**Authorizations**

- Owner: `setPriceFeed(address)`, `setKeeper(address)`.
- Keeper: `setSettlementPrice(uint256, uint256)`.

**Events**

- `SettlementPriceSet(uint256 indexed epochId, uint256 price)`.
- `KeeperSet(address indexed keeper)`, `PriceFeedSet(address indexed feed)`.

---

### 3.2 EpochController

**Responsibility**  
Define epoch boundaries (e.g. 24h from 00:00 UTC), store strike per epoch, start epochs (fix strike from oracle), run settlement: pay Long Gamma straddle PnL, then pay options market (call/put payouts) from reserved collateral, release reserved collateral. Hold fee configuration. Options market is optional (can be set to zero).

**State**

- `ISettlementOracle public oracle`
- `ILongGammaVault private _longGammaVault`
- `IOptionsMarket private _optionsMarket` (optional; can be zero)
- `ILPVault public lpVault`
- `uint256 public constant EPOCH_DURATION = 1 days`
- `uint256 public immutable EPOCH_ANCHOR` — e.g. 00:00 UTC in unix (configurable at deploy).
- `mapping(uint256 epochId => uint256) public strikeForEpoch` — strike (price, 8 decimals) at epoch start.
- `mapping(uint256 epochId => bool) public override epochSettled` — true once settled.
- `address public keeper`
- `address public owner`
- `address public feeRecipient`
- `uint16 public feeBps` — protocol fee in basis points (e.g. 50 = 0.5%), deducted from payouts.

**Epoch ID**  
`epochId = (block.timestamp - EPOCH_ANCHOR) / EPOCH_DURATION` (0 before anchor). Epoch start time = `EPOCH_ANCHOR + epochId * EPOCH_DURATION`, end time = start + EPOCH_DURATION.

**Key functions**

- `getCurrentEpochId() view returns (uint256)` — current epoch based on `block.timestamp`.
- `getEpochStartTime(uint256 epochId) view returns (uint256)` — start timestamp for epoch.
- `getEpochEndTime(uint256 epochId) view returns (uint256)` — end timestamp for epoch.
- `startEpoch()` — KEEPER only. Require current epoch started and strike not yet set. Read `oracle.getCurrentPrice()`, store in `strikeForEpoch[currentEpochId]`. Call `lpVault.onEpochStarted(epochId)`, `longGammaVault.onEpochStarted(epochId)`, and if options market set, `optionsMarket.onEpochStarted(epochId)`. Emit `EpochStarted(epochId, strike)`.
- `settleEpoch(uint256 epochId)` — permissionless. Require epoch ended, not yet settled, oracle settlement price and strike set. (1) Long Gamma: payoff = |strike - settlementPrice|; deduct fee; `lpVault.paySettlement(longGammaAfterFee)`, `longGammaVault.receiveSettlement(longGammaAfterFee)`. (2) If options market set: options payout from `optionsMarket.previewEpochPayout`; deduct fee; `lpVault.paySettlementTo(optionsMarket, optionsAfterFee, epochId)`; `optionsMarket.settleEpoch(...)`; `lpVault.releaseReservedCollateral(epochId)`. Set `epochSettled[epochId] = true`, emit `EpochSettled`.

**Authorizations**

- Owner: `setKeeper`, `setFeeRecipient`, `setFeeBps`, `setVaults`, `setOptionsMarket`, `setOracle`.
- Keeper: `startEpoch()`.
- Anyone: `settleEpoch(epochId)` once epoch has ended.

**Events**

- `EpochStarted(uint256 indexed epochId, uint256 strike)`.
- `EpochSettled(uint256 indexed epochId, uint256 settlementPrice, uint256 payout)`.

---

### 3.3 LongGammaVault

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

### 3.4 LPVault

**Responsibility**  
Accept BTC.b deposits in pre-epoch window; mint shares; receive premium from LongGammaVault when Long Gamma users deposit; at settlement pay PnL to LongGammaVault (up to available balance); enforce max 50% utilization per epoch so that at most 50% of LP capital is at risk. Allow withdraw/roll after settlement.

**State**

- `IERC20 public collateral` — BTC.b.
- `IEpochController public epochController`
- Total supply of LP shares; total collateral balance. Per-epoch: deployed amount (notional sold to Long Gamma) ≤ 50% of total LP balance at epoch start. So: at epoch start, `maxDeployable = totalBalance * 50 / 100`; Long Gamma cap (on EpochController or LongGammaVault) must be ≤ this.

**Key functions**

- `deposit(uint256 amount)` — require in deposit window. Transfer BTC.b from user, mint shares. Emit `Deposit(sender, amount, shares)`.
- `withdraw(uint256 shares)` — after epoch settled. Burn shares, transfer proportional collateral.
- `roll(uint256 shares)` — same as LongGammaVault concept.
- `receivePremium(uint256 amount)` — callable only by EpochController or LongGammaVault; transfer BTC.b from caller (LongGammaVault) to this vault. Increases vault balance (premium income).
- `transferToLongGamma(uint256 amount)` or `paySettlement(uint256 amount)` — callable only by EpochController; transfer `amount` BTC.b to LongGammaVault. Require `amount <= balance` and that utilization rules are satisfied (settlement payout is already bounded by design).

**Utilization**  
At epoch start, “deployed” = total notional sold (Long Gamma deposits for that epoch). Require `deployed <= totalBalance * 50 / 100`. This is enforced by capping Long Gamma deposits (via `cap` on LongGammaVault set from LP capacity).

**Authorizations**

- Owner: `setEpochController(address)`.
- EpochController (or LongGammaVault): `receivePremium(uint256)`.
- EpochController: `transferToLongGamma(uint256)` / `paySettlement(uint256)`.
- Users: `deposit`, `withdraw`, `roll`.

**Events**

- `Deposit(address indexed user, uint256 amount, uint256 shares)`.
- `Withdraw(address indexed user, uint256 shares, uint256 amount)`.
- `PremiumReceived(uint256 amount)`, `SettlementPaid(uint256 amount)`.

---

### 3.5 QuoterRegistry

**Responsibility**  
Maintain set of addresses allowed to sign quotes for LongGammaVault (deposit quotes) and for OptionsMarket (option quotes).

**State**

- `mapping(address => bool) public isQuoter`
- `address public owner`

**Key functions**

- `addQuoter(address quoter)` — owner only; set `isQuoter[quoter] = true`. Emit `QuoterAdded(quoter)`.
- `removeQuoter(address quoter)` — owner only; set `isQuoter[quoter] = false`. Emit `QuoterRemoved(quoter)`.

**Authorizations**

- Owner: `addQuoter`, `removeQuoter`.

---

### 3.6 OptionsMarket

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

## 4. Interfaces and Dependencies

```
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

Deploy order: SettlementOracle, QuoterRegistry, LPVault, LongGammaVault, OptionsMarket, EpochController. Then: set vaults and options market on EpochController, set EpochController and QuoterRegistry and LPVault on LongGammaVault, set EpochController and LongGammaVault and OptionsMarket on LPVault, set EpochController and LPVault and QuoterRegistry on OptionsMarket, set keeper on SettlementOracle and EpochController, add quoter address to QuoterRegistry.

---

## 5. Invariants (On-Chain Guarantees)

- Long Gamma max loss ≤ deposited capital (premium paid; no leverage).
- LP vault: total settlement paid ≤ vault balance; reserved collateral ≤ available balance; pending + reserved ≤ balance.
- Options: payout per epoch limited by fundedAmount (pro-rata if underfunded); reserved collateral released after settlement.
- No leverage: no borrowing; all positions fully backed by collateral.
- No early withdrawal: vault withdraw/redeem only when previous epoch settled; options claim only after epoch settled.
- Settlement price set only once per epoch; strike set only at epoch start.
- Quote signer must be in QuoterRegistry; quote expiry and epoch must be valid; quote digest not already used (options).

---

## 6. Foundry Project Layout (Target)

```
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
```

---

## 7. EIP-712 Quote Types

**LongGammaVault (deposit quote)**  
Type name: `Quote`. Fields: `epochId` (uint256), `notional` (uint256), `premium` (uint256), `expiry` (uint256). Domain: name `AbitusLongGammaQuote`, version `1`, chainId, verifyingContract = LongGammaVault address. Backend signs this; LongGammaVault recovers signer and checks QuoterRegistry.

**OptionsMarket (option quote)**  
Type name: `Quote`. Fields: `buyer` (address), `epochId` (uint256), `isCall` (bool), `notional` (uint256), `premium` (uint256), `expiry` (uint256). Domain: name `AbitusOptionsQuote`, version `1`, chainId, verifyingContract = OptionsMarket address. Backend signs this; OptionsMarket recovers signer and checks QuoterRegistry.

---

This document is the single source of truth for the Abitus Foundry contracts. Implementations must adhere to these specs and the invariants in [MVP](../8_architecture/MVP.md).
