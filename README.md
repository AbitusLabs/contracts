# Abitus Contracts

Smart contracts for the Abitus volatility protocol on Avalanche, built with Foundry.

This repository contains the protocol contracts, deployment scripts, tests, and generated documentation for the on-chain system that powers epoch-based volatility products around BTC.b collateral.

## Documentation

Public documentation is available here:

- [https://abituslabs.github.io/contracts/](https://abituslabs.github.io/contracts/)

Protocol-level specifications live in:

- `CONTRACT_SPECS.md`

The published docs site is generated from the codebase with Foundry and deployed through GitHub Pages.

## What This Repository Contains

Core contracts:

- `EpochController`: manages epoch boundaries, strike initialization, and settlement orchestration
- `SettlementOracle`: exposes current price data and stores settlement prices
- `LPVault`: LP-side vault that receives premium and funds payouts
- `LongGammaVault`: quote-based strategy vault for long gamma positions
- `OptionsMarket`: ERC-721 options positions bought from signed quotes
- `QuoterRegistry`: registry of authorized quote signers

Supporting areas:

- `src/interfaces/`: protocol interfaces
- `script/`: deployment and operational scripts
- `test/`: unit and integration tests
- `deployments/`: generated deployment outputs by chain ID
- `.github/workflows/`: CI and docs publishing workflows

## Architecture Overview

At a high level, the protocol is split into focused contracts with clear responsibilities:

- `SettlementOracle` is responsible for price input and per-epoch settlement values
- `EpochController` coordinates the lifecycle of epochs and settlement flows
- `LPVault` and `LongGammaVault` isolate LP-side and strategy-side accounting
- `OptionsMarket` handles options purchases and claims
- `QuoterRegistry` controls who is allowed to sign quotes accepted by the protocol

This separation keeps business responsibilities isolated and makes testing and operational deployment simpler.

## How It Works

The system follows an epoch-based lifecycle:

1. The protocol starts a new epoch and stores the strike derived from the oracle.
2. Users interact with vaults or buy options during the allowed window.
3. At epoch end, a settlement price is recorded.
4. The controller settles the epoch and coordinates fund flows across contracts.

The exact business rules, permissions, and edge cases are documented in `CONTRACT_SPECS.md`.

## Tooling

The project uses Foundry:

- `forge` for build, test, scripts, and documentation
- `cast` for chain interaction and debugging
- `anvil` for local EVM development
- `chisel` for Solidity experimentation

## Requirements

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Git with submodule support

## Setup

Clone the repository with submodules:

```shell
git clone --recurse-submodules https://github.com/AbitusLabs/contracts.git
cd contracts
```

If the repository was cloned without submodules, initialize them manually:

```shell
git submodule update --init --recursive
```

Install or update Foundry:

```shell
foundryup
```

## Development Workflow

### Build

```shell
forge build
```

### Run the full test suite

```shell
forge test -vvv
```

### Run a single test file

```shell
forge test --match-path test/integration/EpochFlow.t.sol -vvv
```

### Format the codebase

```shell
forge fmt
```

### Check formatting

```shell
forge fmt --check
```

### Generate documentation locally

```shell
forge doc --build
```

Generated static documentation is written to:

- `docs/book`

### Start a local development chain

```shell
anvil
```

## Testing Strategy

The repository includes both unit tests and integration tests.

Examples:

- unit tests for individual contracts in `test/*.t.sol`
- integration flow coverage in `test/integration/EpochFlow.t.sol`
- reusable mocks in `test/mocks/`

Useful commands:

```shell
forge test
forge test -vvv
forge test --match-test testName -vvv
forge test --match-path test/OptionsMarket.t.sol -vvv
```

## Deployment

Deployment scripts live in `script/`.

The production-oriented deployment flow is:

- `script/DeployAvalancheMainnet.s.sol`

This script:

- deploys all core contracts
- wires registry, oracle, controller, vaults, and market together
- configures owner, keeper, quoter, fee recipient, and limits
- writes the deployment output to `deployments/43114.json`

Mainnet environment template:

- `.env.mainnet.example`

Expected variables:

- `DEPLOYER_PK`
- `AVALANCHE_MAINNET_RPC_URL`
- `QUOTER_ADDRESS`
- optional overrides such as `OWNER_ADDRESS`, `KEEPER_ADDRESS`, `FEE_RECIPIENT_ADDRESS`
- optional configuration such as `EPOCH_ANCHOR`, `FEE_BPS`, `LONG_GAMMA_CAP`

Typical flow:

```shell
cp .env.mainnet.example .env.mainnet
set -a && source .env.mainnet && set +a
forge script script/DeployAvalancheMainnet.s.sol:DeployAvalancheMainnet --rpc-url "${AVALANCHE_MAINNET_RPC_URL}" --broadcast
```

## Deployment Artifacts

Each deployment writes a JSON file under `deployments/` named after the chain ID.

Example:

- `deployments/43114.json`

These artifacts are useful for:

- backend contract registry updates
- frontend address wiring
- operational follow-up and verification

## Verification

Foundry verification is configured through `foundry.toml`.

The project currently uses Etherscan V2-compatible verification settings for Avalanche.

Before running verified deployments, make sure your environment provides the API key expected by your current verifier configuration.

## Documentation Pipeline

The docs site is built automatically from GitHub Actions through `.github/workflows/docs.yml`.

The workflow:

- checks out the repository with recursive submodules
- installs Foundry
- runs `forge doc --build`
- publishes `docs/book` to GitHub Pages

Recursive submodules are required because the project depends on:

- `lib/forge-std`
- `lib/openzeppelin-contracts`

## CI

The main CI workflow lives in `.github/workflows/test.yml`.

It runs:

- `forge fmt --check`
- `forge build --sizes`
- `forge test -vvv`

## Repository Layout

```text
.
├── src/
├── script/
├── test/
├── deployments/
├── docs/
├── .github/workflows/
├── foundry.toml
├── book.toml
└── CONTRACT_SPECS.md
```

## Common Commands

```shell
forge build
forge test -vvv
forge fmt --check
forge doc --build
forge snapshot
anvil
cast --help
```

## Notes

- Always initialize submodules before building, testing, or generating docs.
- Keep deployment artifacts under `deployments/` in sync with the target environment.
- Prefer reading `CONTRACT_SPECS.md` before changing protocol behavior.
