# Odds-Based Betting System Architecture Proposal

## Executive Summary

This document proposes migrating from a **parimutuel betting system** (winners split losers' money) to a **fixed-odds bookmaker system** (house provides liquidity at fixed odds).

---

## Current vs Proposed Architecture

### Current System (Parimutuel)
```
User bets 100 CHZ on Home @ unknown odds
↓
Betting closes
↓
Final odds calculated: Home 2.5x, Draw 3.0x, Away 2.0x
↓
Home wins → User gets (100 / totalHomePool) * (totalPool - fees)
```

**Pros:**
- No liquidity risk for house
- Guaranteed solvency
- Simple to implement

**Cons:**
- Users don't know potential winnings until betting closes
- Poor UX (odds change constantly)
- Less competitive vs traditional bookmakers

### Proposed System (Fixed Odds)
```
Match initialized with odds: Home 2.5x, Draw 3.0x, Away 2.0x
↓
User bets 100 CHZ on Home @ 2.5x → Locks in 250 CHZ potential payout
↓
Betting closes (odds may have shifted to 2.3x for later bets)
↓
Home wins → User gets 250 CHZ (100 stake + 150 profit)
```

**Pros:**
- Users know exact potential payout when betting
- Better UX, industry-standard model
- Competitive with traditional sportsbooks

**Cons:**
- Requires liquidity reserves
- House takes on risk
- More complex accounting

---

## Technical Implementation

### Phase 1: Add Odds Storage & Initialization

#### New State Variables
```solidity
// Odds stored as multipliers in 4 decimals (e.g., 25000 = 2.5x odds)
mapping(uint8 => uint256) public odds;          // outcomeId => odds (4 decimals)
mapping(address => OddsBet[]) public userBets;  // Track each bet with its locked odds

struct OddsBet {
    uint8 outcome;      // Which outcome was bet on
    uint256 amount;     // CHZ staked
    uint256 odds;       // Locked odds at bet time (4 decimals)
    bool claimed;       // Claimed flag
}

// Liquidity management
uint256 public maxLiability;  // Maximum risk house will take
uint256 public currentLiability; // Current potential payouts if worst outcome occurs
```

#### Modified Initialization
```solidity
function initialize(
    address owner_,
    address priceFeed_,
    bytes32 matchId_,
    uint64 cutoffTs_,
    uint16 feeBps_,
    address treasury_,
    uint256 minBetUsd_,
    uint256[3] memory initialOdds_  // e.g., [25000, 30000, 20000] = [2.5x, 3.0x, 2.0x]
) external initializer {
    // ... existing initialization ...
    
    // Set initial odds
    for (uint8 i = 0; i < 3; i++) {
        require(initialOdds_[i] >= 10000, "Odds must be >= 1.0x");
        odds[i] = initialOdds_[i];
    }
    
    // Set max liability (e.g., 10,000 CHZ worth of payouts)
    maxLiability = 10_000 ether;
}
```

### Phase 2: Modified Betting Logic

```solidity
function placeBet(uint8 outcome) internal {
    if (outcome >= outcomesCount) revert InvalidOutcome();
    if (msg.value == 0) revert ZeroBet();
    
    // Validate minimum bet
    uint256 usdValue = PriceOracle.chzToUsd(msg.value, priceFeed);
    if (usdValue < minBetUsd) revert BetBelowMinimum();
    
    // Calculate potential payout
    uint256 currentOdds = odds[outcome];
    uint256 potentialPayout = (msg.value * currentOdds) / 10_000;
    uint256 potentialProfit = potentialPayout - msg.value;
    
    // Check if house can cover this liability
    if (currentLiability + potentialProfit > maxLiability) revert InsufficientLiquidity();
    
    // Update liability
    currentLiability += potentialProfit;
    
    // Record bet with locked odds
    userBets[msg.sender].push(OddsBet({
        outcome: outcome,
        amount: msg.value,
        odds: currentOdds,
        claimed: false
    }));
    
    // Update pool for tracking
    pool[outcome] += msg.value;
    
    // Optional: Update odds based on bet volume (like real bookmakers)
    _updateOdds(outcome, msg.value);
    
    emit BetPlaced(msg.sender, outcome, msg.value, usdValue, currentOdds);
}
```

### Phase 3: Treasury Liquidity Model

#### Settlement Flow
```solidity
function settle(uint8 winning) external onlyRole(SETTLER_ROLE) {
    if (settled) revert AlreadySettled();
    if (winning >= outcomesCount) revert InvalidOutcome();
    
    settled = true;
    winningOutcome = winning;
    
    uint256 totalStaked = totalPoolAmount();
    uint256 totalLiability = calculateTotalLiability(winning);
    
    // House profit/loss calculation
    int256 housePnL = int256(totalStaked) - int256(totalLiability);
    
    // If house has profit, send excess to treasury
    if (housePnL > 0) {
        // Keep payouts in contract, send profit to treasury
        uint256 profit = uint256(housePnL);
        (bool success, ) = treasury.call{value: profit}("");
        require(success, "Treasury transfer failed");
    } else {
        // House has loss, need to fund from treasury
        uint256 loss = uint256(-housePnL);
        
        // Contract should have been pre-funded by treasury
        // Or treasury sends funds now
        require(address(this).balance >= totalLiability, "Insufficient contract balance");
    }
    
    emit Settled(winning, totalStaked, totalLiability);
}

function calculateTotalLiability(uint8 outcome) public view returns (uint256) {
    uint256 total = 0;
    // Would need to iterate through all bets on winning outcome
    // More efficient: track in mapping during betting
    return total;
}
```

#### Claim Flow
```solidity
function claim() external nonReentrant {
    if (!settled) revert NotSettled();
    
    uint256 totalPayout = 0;
    
    // Iterate through user's bets
    OddsBet[] storage bets = userBets[msg.sender];
    for (uint256 i = 0; i < bets.length; i++) {
        if (bets[i].outcome == winningOutcome && !bets[i].claimed) {
            // Calculate payout with locked odds
            uint256 payout = (bets[i].amount * bets[i].odds) / 10_000;
            totalPayout += payout;
            bets[i].claimed = true;
        }
    }
    
    if (totalPayout == 0) revert NothingToClaim();
    
    emit Claimed(msg.sender, totalPayout);
    
    (bool success, ) = msg.sender.call{value: totalPayout}("");
    if (!success) revert TransferFailed();
}
```

### Phase 4: Dynamic Odds Updates (Optional)

```solidity
function _updateOdds(uint8 outcome, uint256 betAmount) internal {
    // Reduce odds when more money comes in (like real bookmakers)
    // Simple model: reduce by 1% per X CHZ bet
    
    uint256 totalOnOutcome = pool[outcome];
    uint256 oddsReduction = (totalOnOutcome * 100) / 100_000 ether; // 1% per 1000 CHZ
    
    uint256 newOdds = odds[outcome] - oddsReduction;
    if (newOdds < 10000) newOdds = 10000; // Minimum 1.0x
    
    odds[outcome] = newOdds;
    
    emit OddsUpdated(outcome, newOdds);
}

function setOdds(uint8 outcome, uint256 newOdds) external onlyRole(ADMIN_ROLE) {
    require(!settled, "Cannot change odds after settlement");
    require(newOdds >= 10000, "Odds must be >= 1.0x");
    odds[outcome] = newOdds;
    emit OddsUpdated(outcome, newOdds);
}
```

---

## Liquidity Management Strategy

### Level 1: Initial Launch (Conservative)
```
Treasury Reserve: 50,000 CHZ
Max Liability per Match: 5,000 CHZ
Max Single Bet: 500 CHZ
Expected Volume: 1,000-5,000 CHZ per match
```

**Risk:** Low (10:1 reserve ratio)
**Profit Potential:** 5-10% per match (if 2-5% edge maintained)

### Level 2: Growth Phase (Moderate)
```
Treasury Reserve: 500,000 CHZ
Max Liability per Match: 50,000 CHZ
Max Single Bet: 5,000 CHZ
Expected Volume: 10,000-50,000 CHZ per match
```

**Risk:** Medium (10:1 reserve ratio maintained)
**Profit Potential:** 50-500 CHZ profit per match

### Level 3: Mature Platform (Aggressive)
```
Treasury Reserve: 5,000,000 CHZ
Max Liability per Match: 500,000 CHZ
Max Single Bet: 50,000 CHZ
Expected Volume: 100,000-500,000 CHZ per match
```

**Risk:** Medium-High (10:1 reserve ratio)
**Profit Potential:** 5,000-25,000 CHZ profit per match

### Kelly Criterion for Optimal Sizing
```
Optimal Bet Size = (Edge × Odds - 1) / (Odds - 1)

Example:
If house has 5% edge, odds are 2.0x:
Optimal = (0.05 × 2 - 1) / (2 - 1) = -0.90 / 1 = -90%

This suggests we should be taking the OTHER side!
Proper implementation requires accurate edge calculation.
```

---

## Risk Management Features

### 1. Maximum Exposure Limits
```solidity
mapping(uint8 => uint256) public maxExposurePerOutcome;

function placeBet(uint8 outcome) internal {
    uint256 potentialPayout = (msg.value * odds[outcome]) / 10_000;
    
    require(
        pool[outcome] + potentialPayout <= maxExposurePerOutcome[outcome],
        "Max exposure reached"
    );
    // ...
}
```

### 2. Circuit Breakers
```solidity
uint256 public maxLossPerMatch = 10_000 ether;
uint256 public emergencyPauseThreshold = 5_000 ether;

function settle(uint8 winning) external {
    // ...
    int256 housePnL = int256(totalStaked) - int256(totalLiability);
    
    if (housePnL < -int256(emergencyPauseThreshold)) {
        _pause(); // Auto-pause if large loss
        emit EmergencyPause(housePnL);
    }
    // ...
}
```

### 3. Gradual Odds Adjustment
```solidity
// Implement moving average of odds over time
// Prevent sharp swings that could be exploited
```

### 4. Maximum Bet Sizes
```solidity
uint256 public maxBetAmount = 1000 ether;

function placeBet(uint8 outcome) internal {
    require(msg.value <= maxBetAmount, "Bet too large");
    // ...
}
```

---

## Liquidity Provisioning Model

### Option A: Centralized Treasury (Recommended for Launch)
```
✅ Simple to implement
✅ Full control over risk
✅ Immediate deployment
❌ Requires team to hold reserves
❌ Single point of failure
```

### Option B: Liquidity Pool with Staking
```
Users stake CHZ → Earn share of house profits
✅ Decentralized liquidity
✅ Community incentive
❌ Complex implementation
❌ Requires careful tokenomics
```

### Option C: Hybrid Model (Future)
```
50% centralized treasury + 50% community staking
✅ Risk distribution
✅ Community involvement
✅ Controlled rollout
```

---

## Testing Strategy

### Test Odds Values (Unrealistic but Clear)
```solidity
// Football Match: Real Madrid vs Barcelona
uint256[3] memory testOdds = [
    15000,  // Home: 1.5x (Real Madrid favorite)
    40000,  // Draw: 4.0x 
    25000   // Away: 2.5x (Barcelona underdog)
];

// UFC Fight: Champion vs Challenger
uint256[2] memory testOdds = [
    12000,  // Red (Champion): 1.2x
    55000   // Blue (Challenger): 5.5x
];
```

### Test Cases
1. **Basic bet + win**: Bet 100 CHZ @ 2.5x → Win → Claim 250 CHZ
2. **Multiple bets same outcome**: Two users bet on Home → Both claim proportional
3. **House profit scenario**: More bets on losers than winners
4. **House loss scenario**: Heavy betting on winner
5. **Odds change between bets**: First bet @ 2.5x, odds update to 2.3x, second bet @ 2.3x
6. **Maximum liability reached**: Reject bets when maxLiability exceeded
7. **Treasury liquidity shortage**: Ensure contract has enough balance to pay out
8. **Claim after loss**: User bets on losing outcome, claim reverts

---

## Migration Path

### Week 1: Core Implementation
- [ ] Add odds storage structures
- [ ] Modify initialize() to accept odds array
- [ ] Update placeBet() to lock odds per bet
- [ ] Update claim() to use locked odds

### Week 2: Treasury Integration
- [ ] Implement settlement with PnL calculation
- [ ] Add treasury funding mechanism
- [ ] Build liability tracking system
- [ ] Add max exposure limits

### Week 3: Testing
- [ ] Unit tests with mock odds
- [ ] Integration tests with multiple users
- [ ] Treasury balance edge cases
- [ ] Gas optimization

### Week 4: Advanced Features
- [ ] Dynamic odds updates
- [ ] Admin odds management UI
- [ ] Risk monitoring dashboard
- [ ] Emergency pause mechanisms

---

## Chainlink Integration for Real Odds

### Current: Price Feed Only
```solidity
AggregatorV3Interface priceFeed; // CHZ/USD price
```

### Future: Odds Feed via Chainlink Functions
```solidity
// Chainlink Functions can fetch odds from external APIs
// Example: Fetching from odds aggregator API

string source = `
    const matchId = args[0];
    const response = await Functions.makeHttpRequest({
        url: 'https://api.oddsapi.io/v4/sports/soccer_epl/odds',
        params: { apiKey: secrets.apiKey, matchId: matchId }
    });
    return Functions.encodeUint256(response.data.homeOdds * 10000);
`;

// Deployed via Chainlink Functions
// Updates odds automatically before match
```

### Alternative: Manual Odds Setting (Launch Strategy)
```solidity
function setInitialOdds(
    bytes32 matchId,
    uint256[3] memory odds
) external onlyRole(ADMIN_ROLE) {
    // Admin sets odds based on external data feed
    // Manual process initially, automate later
}
```

---

## Economic Model

### Revenue Streams
1. **House Edge**: 2-5% built into odds
2. **Platform Fees**: 1-3% of volume (optional, on top of edge)
3. **Failed Bet Funds**: Bets below minimum that fail validation

### Expense Streams
1. **Payouts**: 95-98% of volume (if balanced book)
2. **Oracle Costs**: Chainlink price feed updates
3. **Liquidity Costs**: Opportunity cost of locked CHZ

### Break-Even Analysis
```
Assumption: 5% house edge, 100,000 CHZ monthly volume

Monthly Revenue: 100,000 × 5% = 5,000 CHZ
Monthly Expenses: ~500 CHZ (oracles, gas)
Monthly Profit: 4,500 CHZ

Required Reserve: 50,000 CHZ
Monthly ROI: 4,500 / 50,000 = 9% monthly = 108% annual

Risk-Adjusted: Assuming 20% of months have net loss
Expected Annual ROI: 108% × 80% = 86.4%
```

---

## Security Considerations

### 1. Oracle Manipulation
- Use multiple price feeds
- Implement price deviation checks
- Add time delays for large odds changes

### 2. Front-Running
- Use commit-reveal for large bets
- Add mempool monitoring
- Implement fair ordering mechanisms

### 3. Liquidity Attacks
- Max bet sizes per user
- Cooldown periods between large bets
- Gradual odds adjustments

### 4. Treasury Security
- Multi-sig for treasury operations
- Timelock for parameter changes
- Emergency withdrawal only by governance

---

## Comparison: Parimutuel vs Fixed Odds

| Feature | Parimutuel (Current) | Fixed Odds (Proposed) |
|---------|---------------------|----------------------|
| **User Experience** | Poor (unknown payout) | Excellent (known payout) |
| **House Risk** | None | High (requires liquidity) |
| **Implementation** | Simple | Complex |
| **Competitiveness** | Low | High |
| **Scalability** | Excellent | Requires capital |
| **Profit Potential** | Fee-based only | Edge-based + fees |
| **User Trust** | High (transparent) | Moderate (trust in reserves) |

---

## Recommendation

### For Launch: **Hybrid Model**

Keep parimutuel for low-liquidity matches, introduce fixed odds for high-liquidity marquee matches.

```solidity
enum BettingMode {
    PARIMUTUEL,  // Winners split losers' money
    FIXED_ODDS   // House provides liquidity
}

BettingMode public bettingMode;
```

This allows:
1. ✅ Safe launch with existing parimutuel system
2. ✅ Test fixed odds on selected matches
3. ✅ Gradually migrate as liquidity grows
4. ✅ Maintain both options long-term

### For Growth: **Full Fixed Odds**

Once treasury reaches 500k-1M CHZ, transition entirely to fixed odds for better UX and competitiveness.

---

## Next Steps

1. **Review this proposal** - Approve approach
2. **Implement basic odds system** - Add storage + initialization
3. **Build test suite** - Validate with mock odds
4. **Deploy to testnet** - Real-world testing
5. **Plan liquidity bootstrapping** - How to fund initial treasury
6. **Launch conservatively** - Start with low limits, increase over time

**Estimated Timeline**: 4-6 weeks for full implementation and testing.

**Required Resources**:
- Initial treasury: 10,000-50,000 CHZ
- Development time: 80-120 hours
- Security audit: Recommended for mainnet

---

## Questions to Address

1. **Initial treasury size?** Recommend 50,000 CHZ minimum
2. **Maximum liability per match?** Suggest 10% of treasury (5,000 CHZ)
3. **Odds update frequency?** Manual initially, automated later
4. **Emergency fund access?** Multi-sig with 3/5 threshold
5. **Profit distribution?** Reinvest 50%, distribute 50% to stakeholders

---

**Status**: Proposal Ready for Review
**Author**: AI Development Team
**Date**: October 31, 2025
**Version**: 1.0
