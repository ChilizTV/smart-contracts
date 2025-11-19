# 🎯 ChilizTV System Flows - Sequence Diagrams

## Overview

This document provides detailed sequence diagrams for both ChilizTV systems:
1. **Betting System** (UUPS Pattern - BettingMatch)
2. **Streaming System** (Beacon Pattern - StreamWallet)

All diagrams use **Mermaid** syntax for easy rendering in GitHub, GitLab, and documentation tools.

---

## System 1: Betting System Flow (UUPS Pattern)

### Phase 1: Match Creation & Market Setup

```mermaid
sequenceDiagram
    participant Admin as Admin/Backend
    participant Factory as BettingMatchFactory
    participant Impl as BettingMatch<br/>(Implementation)
    participant Proxy as ERC1967Proxy<br/>(Match Instance)

    Note over Admin,Proxy: Create New Match

    Admin->>Factory: createMatch("Real Madrid vs Barcelona", owner)
    activate Factory
    
    Note right of Factory: Factory creates ERC1967 Proxy<br/>pointing to BettingMatch implementation
    
    Factory->>Proxy: Deploy ERC1967Proxy(implementation, initData)
    activate Proxy
    
    Factory->>Proxy: initialize("Real Madrid vs Barcelona", owner)
    
    Note right of Proxy: Initialize State:<br/>- matchName: "Real Madrid vs Barcelona"<br/>- owner: owner address<br/>- marketCount: 0<br/>- Grant ownership
    
    Proxy-->>Factory: emit MatchInitialized(name, owner)
    deactivate Proxy
    
    Factory-->>Admin: Return proxy address (0xABC...)
    Factory-->>Admin: emit BettingMatchCreated(0xABC..., owner)
    deactivate Factory
    
    Note over Admin,Proxy: Add Markets to Match
    
    Admin->>Proxy: addMarket(Winner, 150)
    activate Proxy
    Note right of Proxy: Market 0 created:<br/>- type: Winner<br/>- odds: 1.5x<br/>- state: Live
    Proxy-->>Admin: emit MarketAdded(0, Winner, 150)
    deactivate Proxy
    
    Admin->>Proxy: addMarket(GoalsCount, 200)
    activate Proxy
    Note right of Proxy: Market 1 created:<br/>- type: GoalsCount<br/>- odds: 2.0x<br/>- state: Live
    Proxy-->>Admin: emit MarketAdded(1, GoalsCount, 200)
    deactivate Proxy
```

---

### Phase 2: Users Place Bets

```mermaid
sequenceDiagram
    participant User1 as User1 (Bettor)
    participant User2 as User2 (Bettor)
    participant Match as BettingMatch<br/>(Proxy)

    Note over User1,Match: Place Bets on Market 0 (Winner)

    User1->>Match: placeBet{value: 10 CHZ}(marketId: 0, selection: 1)
    activate Match
    
    Note right of Match: Validate:<br/>✓ Market exists (marketId < marketCount)<br/>✓ Market is Live<br/>✓ msg.value > 0
    
    Note right of Match: Record Bet:<br/>bets[user1] = {<br/>  amount: 10 CHZ,<br/>  selection: 1,<br/>  claimed: false<br/>}<br/>bettors.push(user1)
    
    Match-->>User1: emit BetPlaced(0, user1, 10 CHZ, 1)
    Match-->>User1: Transaction Success ✓
    deactivate Match
    
    User2->>Match: placeBet{value: 5 CHZ}(marketId: 0, selection: 2)
    activate Match
    
    Note right of Match: Record Bet:<br/>bets[user2] = {<br/>  amount: 5 CHZ,<br/>  selection: 2,<br/>  claimed: false<br/>}<br/>bettors.push(user2)
    
    Match-->>User2: emit BetPlaced(0, user2, 5 CHZ, 2)
    deactivate Match
    
    Note over User1,Match: Contract Balance: 15 CHZ
```

**Multiple Users Betting Example:**

```
Market 0 (Winner):
  User1: 10 CHZ → selection: 1 (Home)
  User2: 5 CHZ  → selection: 2 (Away)
  User3: 8 CHZ  → selection: 1 (Home)

Total in Contract: 23 CHZ
```

---

### Phase 3: Owner Funds Liquidity & Resolves Market

```mermaid
sequenceDiagram
    participant Owner as Match Owner
    participant Match as BettingMatch<br/>(Proxy)
    participant Oracle as Oracle/Backend

    Note over Owner,Match: Owner Adds Liquidity for Payouts

    Owner->>Match: send CHZ{value: 20 CHZ}
    activate Match
    Note right of Match: receive() function accepts CHZ<br/>Contract balance: 23 + 20 = 43 CHZ
    Match-->>Owner: Liquidity Added ✓
    deactivate Match
    
    Note over Owner,Oracle: Match Ends - Oracle Provides Result
    
    Oracle->>Owner: Real result: selection = 1 (Home wins)
    
    Owner->>Match: resolveMarket(marketId: 0, result: 1)
    activate Match
    
    Note right of Match: Validate:<br/>✓ Market exists<br/>✓ Market is Live<br/>✓ Only owner can resolve
    
    Note right of Match: Update Market:<br/>- result: 1<br/>- state: Ended
    
    Match-->>Owner: emit MarketResolved(0, 1)
    Match-->>Owner: Market Resolved ✓
    deactivate Match
```

---

### Phase 4: Winners Claim Payouts

```mermaid
sequenceDiagram
    participant User1 as User1 (Winner)
    participant User3 as User3 (Winner)
    participant User2 as User2 (Loser)
    participant Match as BettingMatch<br/>(Proxy)

    Note over User1,Match: Winners Claim Payouts

    User1->>Match: claim(marketId: 0)
    activate Match
    
    Note right of Match: Validate:<br/>✓ Market exists<br/>✓ Market is Ended<br/>✓ User has bet (10 CHZ)<br/>✓ Not claimed yet<br/>✓ User selection (1) == result (1) ✓
    
    Note right of Match: Calculate Payout:<br/>payout = (10 CHZ × 150) / 100<br/>payout = 15 CHZ<br/><br/>Check balance: 43 CHZ >= 15 CHZ ✓
    
    Note right of Match: Mark as claimed:<br/>bets[user1].claimed = true
    
    Match->>User1: Transfer 15 CHZ
    Match-->>User1: emit Payout(0, user1, 15 CHZ)
    Note right of Match: Contract balance: 43 - 15 = 28 CHZ
    deactivate Match
    
    User3->>Match: claim(marketId: 0)
    activate Match
    
    Note right of Match: Calculate Payout:<br/>payout = (8 CHZ × 150) / 100<br/>payout = 12 CHZ
    
    Match->>User3: Transfer 12 CHZ
    Match-->>User3: emit Payout(0, user3, 12 CHZ)
    Note right of Match: Contract balance: 28 - 12 = 16 CHZ
    deactivate Match
    
    Note over User2,Match: Loser Tries to Claim
    
    User2->>Match: claim(marketId: 0)
    activate Match
    
    Note right of Match: Validate:<br/>✓ Market exists<br/>✓ Market is Ended<br/>✓ User has bet (5 CHZ)<br/>✗ User selection (2) != result (1)
    
    Match-->>User2: ❌ Revert: Lost()
    deactivate Match
```

---

## System 2: Streaming System Flow (Beacon Pattern)

### Phase 1: System Deployment

```mermaid
sequenceDiagram
    participant Deployer as Deployer
    participant Safe as Gnosis Safe<br/>(Treasury)
    participant Registry as StreamBeaconRegistry
    participant Beacon as UpgradeableBeacon
    participant Impl as StreamWallet<br/>(Implementation)
    participant Factory as StreamWalletFactory

    Note over Deployer,Factory: Deploy Streaming System

    Deployer->>Impl: Deploy StreamWallet implementation
    activate Impl
    Impl-->>Deployer: Implementation address
    deactivate Impl
    
    Deployer->>Registry: new StreamBeaconRegistry(deployer)
    activate Registry
    Registry-->>Deployer: Registry created
    deactivate Registry
    
    Deployer->>Registry: setImplementation(implAddress)
    activate Registry
    
    Registry->>Beacon: Deploy UpgradeableBeacon(implAddress)
    activate Beacon
    Beacon-->>Registry: Beacon address
    deactivate Beacon
    
    Registry-->>Deployer: emit BeaconCreated(beacon, implAddress)
    deactivate Registry
    
    Deployer->>Factory: new StreamWalletFactory(deployer, registry, safe, 500)
    activate Factory
    Note right of Factory: Factory Config:<br/>- owner: deployer<br/>- registry: registry address<br/>- treasury: safe address<br/>- platformFeeBps: 500 (5%)
    Factory-->>Deployer: Factory created
    deactivate Factory
    
    Deployer->>Registry: transferOwnership(safe)
    activate Registry
    Registry-->>Safe: Ownership transferred
    Registry-->>Deployer: emit OwnershipTransferred(deployer, safe)
    deactivate Registry
```

---

### Phase 2: Create Streamer Wallet

```mermaid
sequenceDiagram
    participant Viewer as Viewer (Fan)
    participant Factory as StreamWalletFactory
    participant Registry as StreamBeaconRegistry
    participant Beacon as UpgradeableBeacon
    participant Wallet as BeaconProxy<br/>(StreamWallet)
    participant Impl as StreamWallet<br/>(Implementation)

    Note over Viewer,Impl: First Subscription Creates Wallet

    Viewer->>Factory: subscribeToStream{value: 100 CHZ}(streamer, 30 days)
    activate Factory
    
    Note right of Factory: Check if wallet exists:<br/>hasWallet(streamer) = false<br/>→ Need to create wallet
    
    Factory->>Registry: getBeacon()
    activate Registry
    Registry-->>Factory: Beacon address
    deactivate Registry
    
    Factory->>Wallet: Deploy BeaconProxy(beacon, initData)
    activate Wallet
    
    Wallet->>Beacon: Query implementation()
    activate Beacon
    Beacon-->>Wallet: StreamWallet implementation address
    deactivate Beacon
    
    Factory->>Wallet: initialize(streamer, treasury, 500)
    Note right of Wallet: Wallet initialized:<br/>- streamer: streamer address<br/>- treasury: safe address<br/>- platformFeeBps: 500 (5%)<br/>- factory: factory address
    
    Wallet-->>Factory: Initialization complete
    deactivate Wallet
    
    Factory-->>Factory: Store wallet mapping:<br/>streamerWallet[streamer] = wallet
    
    Note right of Factory: Now process subscription
    
    Factory->>Wallet: recordSubscription(viewer, 100 CHZ, 30 days)
    
    Note over Factory,Impl: Continue to Phase 3...
    
    deactivate Factory
```

---

### Phase 3: Subscription with Fee Split

```mermaid
sequenceDiagram
    participant Viewer as Viewer
    participant Factory as StreamWalletFactory
    participant Wallet as StreamWallet<br/>(BeaconProxy)
    participant Treasury as Safe Treasury
    participant Streamer as Streamer

    Note over Viewer,Streamer: Process Subscription Payment

    Factory->>Wallet: recordSubscription{value: 100 CHZ}(viewer, 100 CHZ, 30 days)
    activate Wallet
    
    Note right of Wallet: Validate:<br/>✓ Only factory can call<br/>✓ amount > 0<br/>✓ duration > 0
    
    Note right of Wallet: Calculate Split:<br/>platformFee = (100 CHZ × 500) / 10,000<br/>platformFee = 5 CHZ<br/>streamerAmount = 100 - 5 = 95 CHZ
    
    Note right of Wallet: Update Subscription:<br/>subscriptions[viewer] = {<br/>  amount: 100 CHZ,<br/>  startTime: now,<br/>  expiryTime: now + 30 days,<br/>  active: true<br/>}<br/>totalSubscribers++<br/>totalRevenue += 100 CHZ
    
    Wallet->>Treasury: Transfer 5 CHZ (platform fee)
    activate Treasury
    Treasury-->>Wallet: Fee received ✓
    deactivate Treasury
    
    Wallet-->>Wallet: emit PlatformFeeCollected(5 CHZ, treasury)
    
    Wallet->>Streamer: Transfer 95 CHZ (net amount)
    activate Streamer
    Streamer-->>Wallet: Payment received ✓
    deactivate Streamer
    
    Wallet-->>Factory: emit SubscriptionRecorded(viewer, 100 CHZ, 30 days, expiryTime)
    Wallet-->>Viewer: Subscription Success ✓
    deactivate Wallet
    
    Factory-->>Viewer: emit SubscriptionProcessed(streamer, viewer, 100 CHZ)
```

**Subscription Flow Summary:**

```
Viewer pays:        100 CHZ
Platform fee (5%):   -5 CHZ → Treasury
Streamer receives:   95 CHZ → Streamer wallet
```

---

### Phase 4: Donation Flow

```mermaid
sequenceDiagram
    participant Donor as Donor (Fan)
    participant Wallet as StreamWallet<br/>(BeaconProxy)
    participant Treasury as Safe Treasury
    participant Streamer as Streamer

    Note over Donor,Streamer: Donate to Streamer

    Donor->>Wallet: donate{value: 50 CHZ}(50 CHZ, "Great stream!")
    activate Wallet
    
    Note right of Wallet: Validate:<br/>✓ amount > 0<br/>✓ nonReentrant
    
    Note right of Wallet: Calculate Split:<br/>platformFee = (50 CHZ × 500) / 10,000<br/>platformFee = 2.5 CHZ<br/>streamerAmount = 50 - 2.5 = 47.5 CHZ
    
    Note right of Wallet: Update Metrics:<br/>lifetimeDonations[donor] += 50 CHZ<br/>totalRevenue += 50 CHZ
    
    Wallet->>Treasury: Transfer 2.5 CHZ
    activate Treasury
    Treasury-->>Wallet: Fee received ✓
    deactivate Treasury
    
    Wallet-->>Wallet: emit PlatformFeeCollected(2.5 CHZ, treasury)
    
    Wallet->>Streamer: Transfer 47.5 CHZ
    activate Streamer
    Streamer-->>Wallet: Payment received ✓
    deactivate Streamer
    
    Wallet-->>Donor: emit DonationReceived(donor, 50 CHZ, "Great stream!", 2.5, 47.5)
    Wallet-->>Donor: Donation Success ✓
    deactivate Wallet
```

---

### Phase 5: Upgrade All Streamer Wallets (Atomic Upgrade)

```mermaid
sequenceDiagram
    participant Safe as Gnosis Safe
    participant Registry as StreamBeaconRegistry
    participant Beacon as UpgradeableBeacon
    participant NewImpl as StreamWallet V2<br/>(New Implementation)
    participant Wallet1 as Wallet 1
    participant Wallet2 as Wallet 2
    participant WalletN as Wallet N

    Note over Safe,WalletN: Upgrade All StreamWallets Atomically

    Safe->>NewImpl: Deploy new StreamWallet V2
    activate NewImpl
    NewImpl-->>Safe: New implementation address
    deactivate NewImpl
    
    Safe->>Registry: setImplementation(newImplAddress)
    activate Registry
    
    Note right of Registry: Beacon already exists,<br/>so upgrade it
    
    Registry->>Beacon: upgradeTo(newImplAddress)
    activate Beacon
    
    Note right of Beacon: Update implementation pointer<br/>to StreamWallet V2
    
    Beacon-->>Registry: Upgrade complete
    deactivate Beacon
    
    Registry-->>Safe: emit BeaconUpgraded(newImplAddress)
    deactivate Registry
    
    Note over Wallet1,WalletN: All wallets now delegate to V2

    Wallet1->>Beacon: Query implementation()
    activate Beacon
    Beacon-->>Wallet1: StreamWallet V2 address
    deactivate Beacon
    
    Wallet2->>Beacon: Query implementation()
    activate Beacon
    Beacon-->>Wallet2: StreamWallet V2 address
    deactivate Beacon
    
    WalletN->>Beacon: Query implementation()
    activate Beacon
    Beacon-->>WalletN: StreamWallet V2 address
    deactivate Beacon
    
    Note over Wallet1,WalletN: ✅ All streamers upgraded in 1 transaction!
```

---

## Key Differences Between Systems

### Betting System (UUPS)
- ✅ **Individual Upgrades**: Each match upgradeable by its owner
- ✅ **Simple Pattern**: ERC1967 proxy → implementation
- ✅ **Owner Control**: Match owner has full control
- ✅ **Independent**: Matches don't affect each other
- ⚠️ **No Atomic Upgrades**: Must upgrade each match separately

### Streaming System (Beacon)
- ✅ **Atomic Upgrades**: All streamers upgrade together
- ✅ **Safe Control**: Multisig controls all upgrades
- ✅ **Platform Updates**: Fix bugs for everyone at once
- ✅ **Consistent**: All streamers on same version
- ⚠️ **Less Individual Control**: Streamers can't upgrade independently

---

## State Diagrams

### Betting Match Lifecycle

```mermaid
stateDiagram-v2
    [*] --> Created: Factory creates match
    Created --> MarketsAdded: Owner adds markets
    MarketsAdded --> BettingOpen: Markets Live
    BettingOpen --> BettingOpen: Users place bets
    BettingOpen --> MatchEnded: Owner resolves markets
    MatchEnded --> PayoutsProcessing: Winners claim
    PayoutsProcessing --> PayoutsProcessing: More claims
    PayoutsProcessing --> Completed: All claims processed
    Completed --> [*]
```

### Streamer Wallet Lifecycle

```mermaid
stateDiagram-v2
    [*] --> NotCreated: Streamer has no wallet
    NotCreated --> Created: First subscription/donation
    Created --> Active: Receiving payments
    Active --> Active: Subscriptions/Donations
    Active --> Upgraded: Beacon upgraded
    Upgraded --> Active: Continue operations
    Active --> [*]: (Wallet never destroyed)
```

---

**Last Updated**: 2025-11-19
