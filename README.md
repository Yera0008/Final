# Prediction Market Protocol

On-chain binary prediction market with CPMM AMM, Chainlink oracle resolution, ERC-1155 outcome tokens, ERC-4626 fee vault, and DAO governance.

## Deployed Contracts (Arbitrum Sepolia)

| Contract | Address |
| PredictionMarket (Proxy) | [0x8bE287Cddb210165a7F47Fc84a04Ccc26E9a335A](https://sepolia.arbiscan.io/address/0x8bE287Cddb210165a7F47Fc84a04Ccc26E9a335A) |
| PredictionMarket (Impl) | [0x95D6bD9CBB1D204427957F12A38204a194956058](https://sepolia.arbiscan.io/address/0x95D6bD9CBB1D204427957F12A38204a194956058) |
| GovernanceToken (Proxy) | [0x2d041dec8fD1f50741B3B08721be1077680e15AB](https://sepolia.arbiscan.io/address/0x2d041dec8fD1f50741B3B08721be1077680e15AB) |
| GovernanceToken (Impl) | [0xf6d913C3568a6B95be1f4E346E43bA0aFfcce688](https://sepolia.arbiscan.io/address/0xf6d913C3568a6B95be1f4E346E43bA0aFfcce688) |
| OutcomeToken (ERC-1155) | [0x286bB5A85Baa67A17A7F5379d09C0562425DF462](https://sepolia.arbiscan.io/address/0x286bB5A85Baa67A17A7F5379d09C0562425DF462) |
| FeeVault (ERC-4626) | [0x2213868317b468b0c058D3Ef70c078B88eC6e7D8](https://sepolia.arbiscan.io/address/0x2213868317b468b0c058D3Ef70c078B88eC6e7D8) |
| OracleAdapter | [0x46F89e2315f0095bB7A19DE06774aD42372aB23C](https://sepolia.arbiscan.io/address/0x46F89e2315f0095bB7A19DE06774aD42372aB23C) |
| PredictionGovernor | [0x6d221157AE69fA5e7516fcfd513d3e37cE335cAe](https://sepolia.arbiscan.io/address/0x6d221157AE69fA5e7516fcfd513d3e37cE335cAe) |
| MarketTimelock | [0x2482f087466d97D0a70b87153888AD6760e417f2](https://sepolia.arbiscan.io/address/0x2482f087466d97D0a70b87153888AD6760e417f2) |
| MarketFactory | [0xeAd8FD78471c703cfbcb645D3c9bc5Cf41C6E6b5](https://sepolia.arbiscan.io/address/0xeAd8FD78471c703cfbcb645D3c9bc5Cf41C6E6b5) |
| MockUSDC | [0xb29e8CdF93058d65ecD784753BD23a9B7C3F9a74](https://sepolia.arbiscan.io/address/0xb29e8CdF93058d65ecD784753BD23a9B7C3F9a74) |

## Subgraph

Endpoint: https://api.studio.thegraph.com/query/1753417/final/v0.0.1

## Architecture

- **CPMM AMM**: x*y=k with 0.3% fee, Yul-optimized swap calculation
- **ERC-1155 Outcome Tokens**: YES/NO shares per market (tokenId = marketId*2 / marketId*2+1)
- **ERC-4626 Fee Vault**: LP fee accumulation with yield sharing
- **Chainlink Oracle**: Price feed with staleness check (1 hour max age)
- **UUPS Upgradeable**: PredictionMarket and GovernanceToken with V1→V2 upgrade path
- **DAO Governance**: Governor + TimelockController (2-day delay), 4% quorum, 1-week voting

## Quick Start

```bash

forge install

forge build

forge test

forge coverage

source .env
forge script deploy/Deploy.s.sol --rpc-url $ARBITRUM_SEPOLIA_RPC --private-key $PRIVATE_KEY --broadcast
```

## Test Results

| Suite | Tests | Status |
|-------|-------|--------|
| Unit (PredictionMarket) | 37 | Done |
| Unit (Tokens + Factory) | 41 | Done |
| Unit (Governance) | 22 | Done |
| Fuzz | 10 | Done |
| Invariant | 5 | Done |
| Fork | 3 | Done |
| **Total** | **118** | **Done** |

## Design Patterns Used

1. **UUPS Proxy** — PredictionMarket, GovernanceToken
2. **Factory (CREATE + CREATE2)** — MarketFactory
3. **Checks-Effects-Interactions** — all state-changing functions
4. **Access Control / Role-based** — MARKET_CREATOR_ROLE, RESOLVER_ROLE, PAUSER_ROLE
5. **State Machine** — MarketState: Open → PendingResolution → Resolved
6. **Oracle Adapter** — OracleAdapter abstracts Chainlink interface
7. **Timelock** — 2-day delay on governance actions
8. **Reentrancy Guard** — buyOutcome, redeem, addLiquidity, removeLiquidity
9. **Pausable / Circuit Breaker** — PredictionMarket, OutcomeToken
10. **Pull-over-push** — users redeem winnings themselves
