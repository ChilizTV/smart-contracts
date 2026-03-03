# Payout Architecture

## Overview

The ChilizTV betting system uses a **Pull-Claims with Pre-funded PayoutEscrow** architecture. Users claim their winnings on-chain from the BettingMatch contract. When that contract does not hold enough USDT to cover the payout, it automatically pulls the deficit from a shared `PayoutEscrow` contract funded by the Gnosis Safe treasury.

## Contracts

| Contract | Role | Deployed |
|----------|------|----------|
| `BettingMatch` (abstract) | Core betting logic, payout disbursement | Per-match UUPS proxy |
| `FootballMatch` / `BasketballMatch` | Sport-specific markets | Concrete implementations |
| `PayoutEscrow` | Shared USDT reserve funded by Safe | Once per network |
| `BettingMatchFactory` | Deploys match proxies | Once per network |

## Roles

| Role | Holder | Responsibility |
|------|--------|----------------|
| `ADMIN_ROLE` | Match owner | Create markets, set escrow, manage state |
| `RESOLVER_ROLE` | Oracle / admin | Resolve markets with results |
| `TREASURY_ROLE` | Safe / admin | Fund match contract directly |
| Escrow `owner` | Gnosis Safe | Fund escrow, authorize/revoke matches, pause |

## Payout Flow

### Happy Path

```mermaid
sequenceDiagram
    participant Safe as Gnosis Safe (Treasury)
    participant Escrow as PayoutEscrow
    participant Match as BettingMatch Proxy
    participant User as Winner

    Note over Safe,User: Phase 1: Escrow is pre-funded
    Safe->>Safe: USDT.approve(Escrow, amount)
    Safe->>Escrow: fund(amount)
    Escrow-->>Escrow: Holds USDT reserve
    
    Note over Safe,User: Phase 2: Betting lifecycle
    User->>Match: placeBetUSDT(marketId, selection, amount)
    Match-->>Match: USDT transferred from user to contract
    Note over Match: Admin/Oracle resolves the market
    Match->>Match: resolveMarket(marketId, result)

    Note over Safe,User: Phase 3: User claims
    User->>Match: claim(marketId, betIndex)
    Match->>Match: Calculate payout = bet × odds
    Match->>Match: Check contract USDT balance
    
    alt Contract has enough USDT
        Match->>User: USDT.safeTransfer(user, payout)
    else Contract underfunded
        Match->>Escrow: disburseTo(matchAddr, deficit)
        Escrow->>Match: USDT.safeTransfer(match, deficit)
        Match->>User: USDT.safeTransfer(user, payout)
    end
```

### Escrow Underfunded

```mermaid
sequenceDiagram
    participant Match as BettingMatch Proxy
    participant Escrow as PayoutEscrow
    participant User as Winner

    User->>Match: claim(marketId, betIndex)
    Match->>Match: contractBalance < payout
    Match->>Escrow: disburseTo(matchAddr, deficit)
    Escrow->>Escrow: balance < deficit
    Escrow-->>Match: REVERT: InsufficientEscrowBalance
    Match-->>User: REVERT (entire tx rolled back)
    Note over User: User retries after Safe tops up escrow
```

### Batch Claim (claimAll)

```mermaid
sequenceDiagram
    participant User as Winner
    participant Match as BettingMatch Proxy
    participant Escrow as PayoutEscrow

    User->>Match: claimAll(marketId)
    Match->>Match: Loop: accumulate totalPayout
    Match->>Match: Check contractBalance vs totalPayout
    alt Enough in contract
        Match->>User: USDT.safeTransfer(user, totalPayout)
    else Deficit
        Match->>Escrow: disburseTo(match, deficit)
        Escrow->>Match: USDT transfer
        Match->>User: USDT.safeTransfer(user, totalPayout)
    end
```

## Invariants

1. **Double-claim prevention**: Each bet has a `claimed` boolean. Once set to `true`, any further claim attempt reverts with `AlreadyClaimed`.

2. **Solvency at bet time**: When a new bet is placed, the contract verifies `totalUSDTLiabilities + potentialPayout <= usdtToken.balanceOf(contract)`. This uses only the contract's own balance (escrow is not counted), keeping the check conservative.

3. **Liability accounting**: `totalUSDTLiabilities` is decremented on every successful claim/refund by the exact payout amount. This tracks the contract's outstanding obligations.

4. **Escrow whitelist**: Only BettingMatch contracts authorized by the Safe owner can call `PayoutEscrow.disburseTo()`. Unauthorized callers revert with `UnauthorizedMatch`.

5. **Escrow pausability**: The Safe can pause the escrow in emergencies, blocking all disbursements across all matches on the network.

## Monitoring

| Query | How |
|-------|-----|
| Match funding deficit | `match.getFundingDeficit()` → USDT needed beyond contract balance |
| Escrow available balance | `escrow.availableBalance()` → USDT ready for payouts |
| Total liabilities per match | `match.totalUSDTLiabilities()` |
| Total disbursed from escrow | `escrow.totalDisbursed()` |
| Per-match escrow usage | `escrow.disbursedPerMatch(matchAddr)` |

**Operational rule**: `escrow.availableBalance() >= Σ match.getFundingDeficit()` across all active matches.

## Security Properties

- **Checks-Effects-Interactions**: All claim functions set `bet.claimed = true` and update liabilities before any external call.
- **ReentrancyGuard**: Present on `claim()`, `claimRefund()`, `claimAll()` (BettingMatch) and `disburseTo()`, `fund()`, `withdraw()` (PayoutEscrow).
- **SafeERC20**: All token transfers use OpenZeppelin's `SafeERC20` wrappers.
- **Pausable**: Both BettingMatch and PayoutEscrow are independently pausable.

## What Requires Safe Execution

| Action | Who | How |
|--------|-----|-----|
| Fund escrow | Safe signers | `USDT.approve(escrow, amount)` → `escrow.fund(amount)` |
| Authorize match | Safe (escrow owner) | `escrow.authorizeMatch(matchProxy)` |
| Revoke match | Safe (escrow owner) | `escrow.revokeMatch(matchProxy)` |
| Withdraw from escrow | Safe (escrow owner) | `escrow.withdraw(amount)` |
| Pause/unpause escrow | Safe (escrow owner) | `escrow.pause()` / `escrow.unpause()` |

Everything else (betting, claiming, resolving) is automated on-chain.
