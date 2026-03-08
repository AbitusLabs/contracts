# Abitus — Contract Specifications

Detailed specifications for the Abitus on-chain contracts. Target: **Foundry** project on Avalanche. Collateral and underlying: **BTC.b** only. Epoch: **24 hours**, fixed daily start (e.g. 00:00 UTC).

References: [8_architecture/ARCHITECTURE.md](../8_architecture/ARCHITECTURE.md), [8_architecture/MVP.md](../8_architecture/MVP.md).

---

## 1. Contract List and Roles

| # | Contract | Purpose |
|---|----------|---------|
| 1 | **SettlementOracle** | Price feed adapter; current price (strike) and settlement price per epoch; keeper sets settlement. |
| 2 | **EpochController** | Epoch lifecycle, strike storage, `startEpoch()`, `settleEpoch()`; orchestrates vaults and oracle. |
| 3 | **LongGammaVault** | Strategy vault: deposit with signed quote, withdraw/roll, ERC20 shares; receives PnL from LP at settlement. |
| 4 | **LPVault** | LP vault: deposit, withdraw/roll, ERC20 shares; receives premium from Long Gamma; pays PnL at settlement. |
| 5 | **QuoterRegistry** | Authorized quoter addresses for EIP-712 quote verification; used by LongGammaVault. |

**Total: 5 core contracts.** Optional: separate **ProtocolTreasury** or fee recipient as a simple address (can be stored on EpochController or vaults).

---

## 2. Authorizations and Access Control

### 2.1 Summary Table

| Contract | Role / Function | Who |
|----------|-----------------|-----|
| **SettlementOracle** | `setSettlementPrice(epochId, price)` | KEEPER only |
| SettlementOracle | `setPriceFeed(address)` | OWNER only |
| SettlementOracle | `setKeeper(address)` | OWNER only |
| **EpochController** | `startEpoch()` | KEEPER or permissionless (recommend KEEPER) |
| EpochController | `settleEpoch(epochId)` | KEEPER or permissionless (recommend permissionless so anyone can settle if keeper fails) |
| EpochController | `setKeeper(address)`, `setFeeRecipient(address)`, `setFeeBps(uint16)` | OWNER only |
| EpochController | `setVaults(LongGammaVault, LPVault)` | OWNER only (at init or once) |
| **LongGammaVault** | `deposit(amount, quote, signature)` | Any user (quote must be valid and from authorized quoter) |
| LongGammaVault | `withdraw` / `roll` | Any user (own shares) |
| LongGammaVault | `setQuoterRegistry(addr)` | OWNER only |
| LongGammaVault | `setEpochController(addr)` | OWNER only |
| LongGammaVault | `setCap(uint256)` (optional) | OWNER only |
| **LPVault** | `deposit(amount)` | Any user |
| LPVault | `withdraw` / `roll` | Any user (own shares) |
| LPVault | `setEpochController(addr)` | OWNER only |
| LPVault | `receivePremium(uint256)` (or equivalent) | EPOCH_CONTROLLER only (or LongGammaVault) |
| LPVault | `paySettlement(uint256)` (or pull by controller) | EPOCH_CONTROLLER only |
| **QuoterRegistry** | `addQuoter(address)` / `removeQuoter(address)` | OWNER only |
| QuoterRegistry | `isQuoter(address)` (view) | Anyone |

### 2.2 Role Definitions

- **OWNER**: Admin; sets oracles, keeper, fee recipient, quoters, vault links. Prefer multisig in production.
- **KEEPER**: Bot (Chainlink Automation, Gelato, or custom). Calls `setSettlementPrice` on oracle and `startEpoch()` / `settleEpoch()` on controller. Optionally `settleEpoch` can be permissionless.
- **Authorized quoter**: EOA or contract whose EIP-712 signature is accepted by LongGammaVault for deposit quotes. Backend signer address must be registered in QuoterRegistry.

### 2.3 No Mid-Epoch Deposits / No Early Withdrawal

- Deposits (both vaults) allowed only when `block.timestamp < currentEpochStartTime`. Enforced in vaults by reading epoch state from EpochController.
- Withdrawals and roll only after epoch is settled (or in the window after settlement). No early withdrawal during epoch; enforce in vault logic.

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
Define epoch boundaries (e.g. 24h from 00:00 UTC), store strike per epoch, start epochs (fix strike from oracle), run settlement (compute straddle PnL, pull from LPVault, push to LongGammaVault). Hold fee configuration.

**State**

- `ISettlementOracle public oracle`
- `ILongGammaVault public longGammaVault`
- `ILPVault public lpVault`
- `uint256 public constant EPOCH_DURATION = 24 hours`
- `uint256 public constant EPOCH_ANCHOR` — e.g. 00:00 UTC in unix (configurable at deploy).
- `mapping(uint256 epochId => uint256) public strikeForEpoch` — strike (price, 8 decimals) at epoch start.
- `mapping(uint256 epochId => bool) public epochSettled` — true once settled.
- `address public keeper`
- `address public owner`
- `address public feeRecipient`
- `uint16 public feeBps` — protocol fee in basis points of premium (MVP: small percentage).

**Epoch ID**  
Derive from time: e.g. `epochId = (block.timestamp - EPOCH_ANCHOR) / EPOCH_DURATION`. Epoch start time = `EPOCH_ANCHOR + epochId * EPOCH_DURATION`, end time = start + EPOCH_DURATION.

**Key functions**

- `getCurrentEpochId() view returns (uint256)` — current epoch based on `block.timestamp`.
- `getEpochStartTime(uint256 epochId) view returns (uint256)` — start timestamp for epoch.
- `getEpochEndTime(uint256 epochId) view returns (uint256)` — end timestamp for epoch.
- `startEpoch()` — callable when `block.timestamp >= getEpochStartTime(currentEpochId)` and strike not yet set for current epoch. Reads `oracle.getCurrentPrice()`, stores in `strikeForEpoch[currentEpochId]`. Emits `EpochStarted(epochId, strike)`.
- `settleEpoch(uint256 epochId)` — require `block.timestamp >= getEpochEndTime(epochId)`, require `oracle.getSettlementPrice(epochId)` is set, require `!epochSettled[epochId]`. Compute straddle intrinsic value: `settlementPrice = oracle.getSettlementPrice(epochId)`, `strike = strikeForEpoch[epochId]`. Call payoff = max(0, settlement - strike) + max(0, strike - settlement) = abs(settlement - strike) in same units. PnL to Long Gamma = payoff (in collateral units, scaled). Deduct protocol fee if any (from premium side or from payoff; MVP says “small % of premium” — can apply to payoff or keep fee on premium at deposit time). Transfer: pull from LPVault the payout amount (or vault exposes `transferToLongGamma(amount)` callable by controller), push to LongGammaVault. Mark `epochSettled[epochId] = true`. Emit `EpochSettled(epochId, settlementPrice, payout)`.

**Invariants**  
Settlement must not overdraw LPVault (LP is fully collateralized; total exposure ≤ deployed LP capital). Controller must use vault interfaces that enforce caps (e.g. LPVault only allows transfer up to available balance and within utilization rules).

**Authorizations**

- Owner: `setKeeper(address)`, `setFeeRecipient(address)`, `setFeeBps(uint16)`, `setVaults(ILongGammaVault, ILPVault)` (if allowed to change).
- Keeper: `startEpoch()` (recommended). Optional: restrict `settleEpoch` to keeper or leave permissionless for resilience.

**Events**

- `EpochStarted(uint256 indexed epochId, uint256 strike)`.
- `EpochSettled(uint256 indexed epochId, uint256 settlementPrice, uint256 payout)`.

---

### 3.3 LongGammaVault

**Responsibility**  
Accept BTC.b deposits only in pre-epoch window and only with a valid signed quote from an authorized quoter; mint shares; at settlement receive PnL from LP vault; allow withdraw/roll after settlement. Enforce cap (total notional ≤ LP capacity). Deduct premium from user and send to LP vault (or to fee recipient for protocol cut); user’s remaining balance is “at risk” (max loss = premium paid).

**State**

- `IERC20 public collateral` — BTC.b.
- `IEpochController public epochController`
- `IQuoterRegistry public quoterRegistry`
- `uint256 public totalDepositsCurrentEpoch` — total notional deposited for current epoch (for cap check).
- `uint256 public cap` — max total notional (derived from LP capacity or set by owner).
- Per-epoch accounting: total premium collected, total notional, share supply per epoch (or use a single share token and track NAV per epoch for withdraw/roll). Standard approach: ERC20 shares, vault holds collateral; at deposit user sends `amount` BTC.b, part is premium (sent to LPVault), rest stays in vault; shares minted based on net amount or notional after premium.
- Deposit receipt or share logic: either (a) shares are fungible across epochs and NAV is updated at settlement, or (b) round/epoch-specific accounting (like Ribbon). For MVP, (a) is simpler: one share token, `totalAssets()` increases when PnL received at settlement, decreases when premium sent out at deposit.

**Key functions**

- `deposit(uint256 amount, Quote quote, bytes signature)` — require `block.timestamp < epochController.getEpochStartTime(epochController.getCurrentEpochId())` (deposit window). Recover signer from EIP-712 `quote` + `signature`; require `quoterRegistry.isQuoter(signer)`. Validate quote: `quote.epochId == currentEpochId`, `quote.notional == amount` (or amount in quote), `quote.premium <= amount`, `quote.expiry >= block.timestamp`. Require `totalDepositsCurrentEpoch + amount <= cap`. Transfer `amount` BTC.b from user. Send `quote.premium` to LPVault (e.g. `lpVault.receivePremium(quote.premium)` or transfer to LP vault address). Mint shares to user for `amount - quote.premium` (or proportional to notional minus premium). Update `totalDepositsCurrentEpoch += amount`. Emit `Deposit(sender, amount, premium, shares)`.
- `withdraw(uint256 shares)` — only when current epoch is settled (or in withdraw window). Burn shares, transfer proportional collateral to user.
- `roll(uint256 shares)` — keep position into next epoch (no burn/transfer; just mark or use same shares with next epoch’s accounting if applicable). Exact semantics depend on share model.
- `receiveSettlement(uint256 amount)` — callable only by EpochController; increase vault’s collateral balance (or internal accounting) by `amount` (PnL from LP). Update NAV so share value reflects gain.

**Quote structure (EIP-712)**  
`Quote`: `epochId`, `notional` (or `amount`), `premium`, `expiry` (timestamp), `nonce` (optional). Domain: contract name, version, chainId, verifyingContract.

**Authorizations**

- Owner: `setQuoterRegistry(address)`, `setEpochController(address)`, `setCap(uint256)`.
- EpochController: `receiveSettlement(uint256)`.
- Users: `deposit` (with valid quote), `withdraw`, `roll`.

**Events**

- `Deposit(address indexed user, uint256 amount, uint256 premium, uint256 shares)`.
- `Withdraw(address indexed user, uint256 shares, uint256 amount)`.
- `SettlementReceived(uint256 amount)`.

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
Maintain set of addresses allowed to sign deposit quotes for LongGammaVault.

**State**

- `mapping(address => bool) public isQuoter`
- `address public owner`

**Key functions**

- `addQuoter(address quoter)` — owner only; set `isQuoter[quoter] = true`. Emit `QuoterAdded(quoter)`.
- `removeQuoter(address quoter)` — owner only; set `isQuoter[quoter] = false`. Emit `QuoterRemoved(quoter)`.

**Authorizations**

- Owner: `addQuoter`, `removeQuoter`.

---

## 4. Interfaces and Dependencies

```
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

Deploy order: SettlementOracle, QuoterRegistry, LPVault, LongGammaVault, EpochController. Then: set vaults on EpochController, set EpochController and QuoterRegistry on LongGammaVault, set EpochController on LPVault, set keeper on SettlementOracle and EpochController, add quoter address to QuoterRegistry.

---

## 5. Invariants (On-Chain Guarantees)

- Long Gamma max loss ≤ deposited capital (premium paid; no leverage).
- LP vault always fully collateralized: total settlement paid ≤ vault balance; max 50% utilization per epoch.
- Total exposure (Long Gamma notional) ≤ deployed LP capital (enforced by cap and utilization).
- No leverage: no borrowing; all positions fully backed by collateral.
- No early withdrawal: withdraw/roll only when epoch is settled (or in designated window).
- Settlement price set only for past expiry and once per epoch.
- Quote signer must be in QuoterRegistry; quote expiry and epoch must be valid.

---

## 6. Foundry Project Layout (Target)

```
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
```

---

## 7. EIP-712 Quote Type

Suggested type name: `Quote`. Fields: `epochId` (uint256), `notional` (uint256), `premium` (uint256), `expiry` (uint256). Domain: name `AbitusLongGammaQuote`, version `1`, chainId, verifyingContract = LongGammaVault address. Backend signs this; LongGammaVault recovers signer and checks QuoterRegistry.

---

This document is the single source of truth for the Abitus Foundry contracts. Implementations must adhere to these specs and the invariants in [MVP](../8_architecture/MVP.md).
