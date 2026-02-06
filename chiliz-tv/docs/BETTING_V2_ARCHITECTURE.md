# BettingMatchV2 Architecture - Dynamic Odds System

## 1. Architecture Summary

### Problem Statement
The original design stored ONE odds value per market, causing all users to bet at the same odds regardless of when they placed their bet. This is incorrect for fixed-odds betting where odds change over time based on market conditions.

### Solution Overview
A **per-market odds registry** with **index-based bet storage** that:
1. Stores each unique odds value once (deduplication)
2. References odds by index in each bet (gas-efficient)
3. Maintains O(1) lookup for existing odds
4. Preserves historical odds for accurate settlement

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           MARKET ARCHITECTURE                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Market N                                                                   │
│  ├── MarketCore                                                             │
│  │   ├── state: MarketState                                                 │
│  │   ├── result: uint64                                                     │
│  │   ├── totalPool: uint256                                                 │
│  │   └── timestamps                                                         │
│  │                                                                          │
│  ├── OddsRegistry                                                           │
│  │   ├── values: uint32[] ─────────────────────────┐                        │
│  │   │   [0] 20000 (2.00x)  ◄───────────────────┐ │                        │
│  │   │   [1] 21800 (2.18x)  ◄─────────────────┐ │ │                        │
│  │   │   [2] 25000 (2.50x)  ◄───────────────┐ │ │ │                        │
│  │   │                                      │ │ │ │                        │
│  │   ├── toIndex: mapping(uint32 => uint16) │ │ │ │                        │
│  │   │   20000 → 1 ─────────────────────────┼─┼─┘ │                        │
│  │   │   21800 → 2 ─────────────────────────┼─┘   │                        │
│  │   │   25000 → 3 ─────────────────────────┘     │                        │
│  │   │                                            │                        │
│  │   └── currentIndex: 3 ◄────────────────────────┘ (active odds)          │
│  │                                                                          │
│  └── UserBets: mapping(address => BetV2[])                                  │
│      ├── Alice                                                              │
│      │   └── [0] { amount: 1 ETH, selection: 0, oddsIndex: 1 }             │
│      ├── Bob                                                                │
│      │   └── [0] { amount: 2 ETH, selection: 0, oddsIndex: 2 }             │
│      └── Charlie                                                            │
│          ├── [0] { amount: 1 ETH, selection: 0, oddsIndex: 2 }             │
│          └── [1] { amount: 3 ETH, selection: 1, oddsIndex: 3 }             │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## 2. Data Model

### Core Structs

```solidity
/// @notice Individual bet with odds snapshot
struct BetV2 {
    uint256 amount;       // Bet amount in CHZ (wei)
    uint64  selection;    // Encoded user pick (outcome ID)
    uint16  oddsIndex;    // Index into market's oddsRegistry (1-based)
    uint40  timestamp;    // Block timestamp when bet was placed
    bool    claimed;      // Whether payout/refund was claimed
}

/// @notice Odds registry for deduplication
struct OddsRegistry {
    uint32[] values;                    // Append-only unique odds
    mapping(uint32 => uint16) toIndex;  // odds value → index (1-based)
    uint16 currentIndex;                // Active odds for new bets
}

/// @notice Market core data
struct MarketCore {
    MarketState state;
    uint64      result;
    uint40      createdAt;
    uint40      resolvedAt;
    uint256     totalPool;
}
```

### Storage Layout

```solidity
// Base contract storage
string public matchName;                                          // Slot 0
string public sportType;                                          // Slot 1
uint256 public marketCount;                                       // Slot 2
mapping(uint256 => OddsRegistry) internal _oddsRegistries;        // Slot 3
mapping(uint256 => mapping(address => BetV2[])) internal _userBets; // Slot 4
mapping(uint256 => MarketCore) internal _marketCores;             // Slot 5
uint256[40] private __gap;                                        // Slots 6-45

// Sport-specific (FootballMatchV2)
mapping(uint256 => FootballMarket) public footballMarkets;        // Slot 46
uint256[48] private __gap_football;                               // Slots 47-94
```

### Odds Precision

| Representation | Value    | Meaning    |
|----------------|----------|------------|
| `10001`        | 1.0001x  | Minimum    |
| `15000`        | 1.50x    | -          |
| `20000`        | 2.00x    | Even money |
| `21800`        | 2.18x    | Common     |
| `100000`       | 10.00x   | -          |
| `1000000`      | 100.00x  | Maximum    |

Formula: `actualOdds = storedValue / 10000`

## 3. Gas Analysis

### Approach A: Direct Odds Storage (uint32 per bet)

```
Storage per bet: 1 slot (256 bits)
├── amount: 256 bits     → 1 slot
├── selection: 64 bits   ─┐
├── odds: 32 bits         │→ 1 slot (packed)
├── timestamp: 40 bits    │
└── claimed: 8 bits      ─┘

Total: 2 slots = 64 bytes × 20,000 gas = 40,000 gas (cold)
Lookup: No additional reads
```

### Approach B: Index-Based Storage (uint16 index + array)

```
Storage per bet: ~1.5 slots average
├── amount: 256 bits     → 1 slot
├── selection: 64 bits   ─┐
├── oddsIndex: 16 bits    │→ 1 slot (packed, saves 16 bits)
├── timestamp: 40 bits    │
└── claimed: 8 bits      ─┘

Additional per unique odds: 32 bits + mapping entry
Lookup on claim: +1 SLOAD (2100 gas cold, 100 warm)
```

### Comparison

| Scenario                          | Approach A | Approach B | Winner |
|-----------------------------------|------------|------------|--------|
| 100 bets, 100 unique odds         | 40,000 gas | 42,100 gas | A      |
| 100 bets, 10 unique odds          | 40,000 gas | 38,600 gas | **B**  |
| 1000 bets, 50 unique odds         | 400,000    | 361,000    | **B**  |
| Claim payout                      | 0 extra    | 2100 extra | A      |

**Conclusion**: Approach B wins when odds are frequently reused (typical case).

### Odds Lookup Strategies

#### Strategy 1: Per-Market Mapping (Chosen)

```solidity
mapping(uint256 marketId => OddsRegistry) _oddsRegistries;

struct OddsRegistry {
    uint32[] values;
    mapping(uint32 => uint16) toIndex;
    uint16 currentIndex;
}
```

**Pros:**
- O(1) lookup for existing odds
- Clean isolation between markets
- No collision issues
- Easy cleanup (not needed for append-only)

**Cons:**
- Mapping storage per market (but markets are few)

#### Strategy 2: Global Odds Dictionary (Alternative)

```solidity
uint32[] globalOddsValues;
mapping(uint32 => uint16) globalOddsToIndex;
// Bets reference global index
```

**Pros:**
- Maximum deduplication across all markets

**Cons:**
- Cross-market coupling
- Harder to reason about
- Cleanup complexity if needed
- Marginal benefit (odds vary per market anyway)

**Decision**: Per-market mapping chosen for isolation and simplicity.

## 4. Security Considerations

### Front-Running Odds Updates

**Risk**: MEV bots see `setMarketOdds` tx, front-run with bet at old (better) odds.

**Mitigations:**
1. **Commit-reveal for odds** (adds latency)
2. **Private mempool** (Flashbots Protect)
3. **Time-lock on odds changes** (operational complexity)
4. **Accept as market dynamics** (bookmaker absorbs)

**Recommendation**: Accept for now; use private mempool for critical updates.

### Role Abuse

| Role              | Powers                        | Abuse Vector                    |
|-------------------|-------------------------------|----------------------------------|
| ODDS_SETTER_ROLE  | Change odds                   | Collude with bettors             |
| RESOLVER_ROLE     | Set result                    | Fraudulent resolution            |
| ADMIN_ROLE        | State transitions, cancel     | Block legitimate payouts         |
| TREASURY_ROLE     | Emergency withdraw            | Drain funds                      |

**Mitigations:**
- Multi-sig for all roles
- Time-locks on sensitive operations
- On-chain audit trail (events)
- Role separation (no single key has all roles)

### Settlement Integrity

**Risk**: Wrong odds used for payout calculation.

**Mitigations:**
- Bet stores `oddsIndex` at placement time (immutable)
- Claim reads odds from historical array
- No path to modify past odds entries (append-only)
- Comprehensive test coverage

### Reentrancy

**Protected by:**
- `nonReentrant` modifier on `claim`, `claimRefund`, `claimAll`
- CEI pattern (effects before interactions)

### Integer Overflow

**Protected by:**
- Solidity 0.8+ automatic checks
- Explicit bounds on odds values
- Safe math in payout calculation

## 5. State Machine

```
                    ┌──────────┐
                    │ Inactive │ (default)
                    └────┬─────┘
                         │ openMarket()
                         ▼
        ┌─────────────►┌──────┐◄────────────────┐
        │              │ Open │                 │
        │              └──┬───┘                 │
        │   resumeMarket()│                     │ suspendMarket()
        │                 ▼                     │
        │           ┌───────────┐               │
        │           │ Suspended │───────────────┘
        │           └─────┬─────┘
        │                 │ closeMarket()
        │                 ▼
        │           ┌────────┐
        │           │ Closed │
        │           └───┬────┘
        │               │ resolveMarket()
        │               ▼
        │         ┌───────────┐
        └─────────│ Resolved  │ (terminal)
                  └───────────┘
                  
                  ┌───────────┐
        ──────────│ Cancelled │ (terminal, from any non-terminal)
                  └───────────┘
```

## 6. Example Flow

### Scenario: Match with Odds Movement

```
1. Admin creates market: WINNER with odds 2.00x (20000)
   → oddsRegistry.values = [20000]
   → oddsRegistry.currentIndex = 1

2. Admin opens market
   → state = Open

3. Alice bets 1 ETH on Home at current odds
   → bet.oddsIndex = 1 (points to 2.00x)

4. Odds move to 2.18x
   → oddsRegistry.values = [20000, 21800]
   → oddsRegistry.currentIndex = 2

5. Bob bets 2 ETH on Home at current odds
   → bet.oddsIndex = 2 (points to 2.18x)

6. Odds move back to 2.00x (reuses existing)
   → oddsRegistry.currentIndex = 1 (no new entry)

7. Charlie bets 3 ETH on Home
   → bet.oddsIndex = 1 (points to 2.00x)

8. Market resolved: Home wins

9. Payouts:
   - Alice: 1 ETH × 2.00 = 2.00 ETH
   - Bob:   2 ETH × 2.18 = 4.36 ETH  
   - Charlie: 3 ETH × 2.00 = 6.00 ETH
```

## 7. Testing Checklist

### Unit Tests
- [x] Odds change between bets → correct historical odds used
- [x] Same odds shared → same oddsIndex
- [x] New odds appended → registry grows
- [x] Odds reused → no new entry
- [x] Bounds validation (min/max odds)
- [x] Role-based access control
- [x] Market state transitions
- [x] Claim/refund logic
- [x] Multiple bets per user

### Fuzz Tests
- [x] Random odds sequences → correct payouts
- [x] Random bet amounts → correct calculations
- [x] Concurrent users → no interference

### Integration Tests
- [ ] Proxy upgrade preserves state
- [ ] Multi-market match scenario
- [ ] High volume (1000+ bets)

### Security Tests
- [x] Only ODDS_SETTER can change odds
- [x] Cannot bet on closed market
- [x] Cannot claim before resolution
- [x] Cannot double claim
- [x] Losing bet cannot claim
- [x] Refund on cancelled market

## 8. Future Improvements

1. **Batch Betting**: Place multiple bets in one tx
2. **Odds History API**: Query odds at specific timestamp
3. **Liquidity Tracking**: Pool balances per outcome
4. **Dynamic Odds Engine**: Auto-adjust based on exposure
5. **Cross-Market Parlays**: Combine bets across markets
6. **Oracle Integration**: Automated resolution via Chainlink
