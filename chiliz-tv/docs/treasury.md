# Treasury & Safe Operations

> **Last reviewed:** 2026-04-22 — role separation refactor.

## Architecture

Treasury authority on `LiquidityPool` is split between **two distinct keys**.
Conflating them defeats the whole defence:

| Key | Role | What it can do | What it CANNOT do |
|---|---|---|---|
| **Admin key** (EOA or Safe) | `DEFAULT_ADMIN_ROLE` + `PAUSER_ROLE` | `authorizeMatch` / `revokeMatch`, set caps & fees & cooldown, `setMaxBetAmount`, pause / unpause, UUPS upgrades | Rotate treasury, touch `accruedTreasury`, withdraw USDC |
| **Treasury Safe** | `treasury` (state variable — NOT a role) | `proposeTreasury` / `cancelTreasuryProposal`, `acceptTreasury`, `withdrawTreasury` | Authorize matches, set fees, pause, upgrade contracts |

```
┌─────────────────────────────┐        ┌─────────────────────────────┐
│  Admin key                  │        │  Treasury Safe              │
│  DEFAULT_ADMIN_ROLE         │        │  state: `treasury`          │
│  PAUSER_ROLE                │        │                             │
├─────────────────────────────┤        ├─────────────────────────────┤
│ • authorizeMatch            │        │ • proposeTreasury (2-step)  │
│ • revokeMatch               │        │ • cancelTreasuryProposal    │
│ • setProtocolFeeBps         │        │ • acceptTreasury            │
│ • setMaxLiabilityPerMarketBps│       │ • withdrawTreasury          │
│ • setMaxLiabilityPerMatchBps │       │                             │
│ • setDepositCooldownSeconds  │       │                             │
│ • setMaxBetAmount           │        │                             │
│ • pause / unpause           │        │                             │
│ • UUPS upgrade              │        │                             │
└──────────────┬──────────────┘        └──────────────┬──────────────┘
               │                                      │
               └──────────────────┬───────────────────┘
                                  ▼
              ┌─────────────────────────────────────────┐
              │  LiquidityPool (ERC-4626, UUPS)         │
              │  - USDC vault                           │
              │  - `accruedTreasury` (pull claim)       │
              │  - 50/50 loss split on settlement       │
              └─────────────────────────────────────────┘
                                  ▲
                                  │ deposit / withdraw
              ┌─────────────────────────────────────────┐
              │  Liquidity Providers (ctvLP holders)    │
              └─────────────────────────────────────────┘
```

### Why the separation matters

- **Admin compromise** cannot redirect funds. The admin key holds no authority over `treasury` or `accruedTreasury`.
- **Treasury compromise** cannot brick the protocol. The Safe can take the accrued balance but cannot revoke matches, change parameters, or upgrade the contract.

Deploy with **different addresses** for `admin_` and `treasury_` in `LiquidityPool.initialize(...)`. The contract does not enforce this invariant — it is a deployment discipline.

---

## How value accrues to the treasury

The pool splits every losing stake 50/50: LPs get half (compounded into ctvLP NAV), the treasury gets the other half booked as an **accrued claim** that stays as USDC inside the pool until the Safe pulls it.

```
Bettor loses netStake  ──▶  LiquidityPool.settleMarket(..., losingNetStake)
                                │
                                ├─ accruedTreasury += losingNetStake × 50% / 10_000
                                └─ remaining 50% stays as pool USDC → LP NAV
```

- **No push.** Nothing transfers to the treasury on settlement.
- **No dilution.** `totalAssets()` subtracts `accruedTreasury` so LP share price does not reflect the treasury's share.
- **Pool solvency first.** `withdrawTreasury(amount)` reverts if `amount > USDC balance − totalLiabilities`. Bettors with outstanding bets always have precedence.

The constant split is on-chain: `TREASURY_SHARE_BPS = 5000`. Not admin-configurable by design — predictability for LPs.

---

## Initial Setup (after deployment)

### 1. Verify role separation

```solidity
pool.hasRole(DEFAULT_ADMIN_ROLE, safeAddress)  // expect FALSE
pool.hasRole(DEFAULT_ADMIN_ROLE, adminAddress) // expect TRUE
pool.treasury() == safeAddress                 // expect TRUE
```

If the Safe accidentally ended up as admin, rotate admin (`grantRole` from the Safe-qua-admin to the new admin EOA, then `renounceRole`). This is cheap to fix pre-launch, expensive to fix post-launch.

### 2. Authorize each BettingMatch proxy

Admin tx (Safe can also act as admin if this is the only path you have):

```
Target:   LiquidityPool
Function: authorizeMatch(address matchContract)
Effect:   Grants MATCH_ROLE → the proxy can call recordBet/payWinner/payRefund/settleMarket
```

### 3. Configure risk caps (have sensible defaults)

```
LiquidityPool.setMaxLiabilityPerMarketBps(uint16)  // e.g. 500  = 5%   of totalAssets
LiquidityPool.setMaxLiabilityPerMatchBps(uint16)   // e.g. 2000 = 20%  of totalAssets
LiquidityPool.setMaxBetAmount(uint256)             // e.g. 10_000e6 (10k USDC/bet), 0 = disabled
LiquidityPool.setDepositCooldownSeconds(uint48)    // e.g. 3600 (1h anti-flash-NAV)
```

Each BettingMatch also has its own soft odds cap:

```
BettingMatch.setMaxAllowedOdds(uint32)             // e.g. 50_000 = 5.00x; 0 = uses MAX_ODDS (100x)
```

### 4. Seed initial liquidity

The Safe (or any LP) deposits USDC directly. `_decimalsOffset = 6` defuses the classic first-depositor inflation attack — any deposit is safe.

```
USDC.approve(pool, amount)
LiquidityPool.deposit(amount, receiverAddress)
```

---

## Treasury rotation (2-step)

Rotation is gated to the **current treasury only**. Admin cannot rotate.

```
┌──────────────┐            ┌──────────────┐
│  Safe A      │            │  Safe B      │
│ (current)    │            │ (target)     │
└──────┬───────┘            └──────┬───────┘
       │ 1. proposeTreasury(B)     │
       ├──────────────────────────▶│  pendingTreasury = B
       │                           │  Safe A still holds withdrawal rights
       │                           │
       │                           │ 2. acceptTreasury() (from Safe B)
       │                           ├────────────────────┐
       │                           │                    ▼
       │                                          treasury = B
       │                                          pendingTreasury = 0
```

Common patterns:

- **Typo in propose:** Safe A calls `cancelTreasuryProposal()` — pending cleared, nothing changed.
- **Safe B mis-configured (can't sign):** `acceptTreasury` never arrives. Safe A stays in charge indefinitely. No funds moved.
- **Propose slipped through A's multisig hostilely:** accrued balance is safe — only Safe B can complete the rotation. Safe A can cancel before B signs.

This is the exact pattern of OZ `Ownable2Step` — it protects against the single class of error that has no recovery path (once accepted, old treasury loses all rights).

### Safe transaction templates

**Propose rotation (Safe A):**

```json
{
  "to": "<LiquidityPool>",
  "value": "0",
  "data": "proposeTreasury(address)",
  "params": ["<Safe B address>"]
}
```

**Accept rotation (Safe B):**

```json
{
  "to": "<LiquidityPool>",
  "value": "0",
  "data": "acceptTreasury()",
  "params": []
}
```

**Cancel (Safe A):**

```json
{
  "to": "<LiquidityPool>",
  "value": "0",
  "data": "cancelTreasuryProposal()",
  "params": []
}
```

---

## Withdrawing accrued funds

```solidity
uint256 available = pool.treasuryWithdrawable();
// available = min(accruedTreasury, USDC.balanceOf(pool) - totalLiabilities)
pool.withdrawTreasury(amount);  // amount <= available
```

- Always sends to `treasury` (no `to` parameter). The Safe pulls to itself; forward from there if needed.
- Reverts `InsufficientTreasuryBalance` if requesting more than `treasuryWithdrawable`.
- Reverts `NotTreasury` for any caller except the current treasury address.
- LP NAV is unchanged by any valid withdrawal (the claim was already excluded from `totalAssets()`).

**When to leave funds in vs. withdraw.** Leaving accrued balance inside the pool effectively lets the team participate as house capital (funds back bet liabilities until withdrawn, but don't dilute LPs). Withdrawing pulls the claim out for off-chain deployment.

**Safe transaction template:**

```json
{
  "to": "<LiquidityPool>",
  "value": "0",
  "data": "withdrawTreasury(uint256)",
  "params": ["500000000"]
}
```

---

## Operational Runbook

### Monitoring pool health (hourly)

| Check | Call | Healthy when |
|---|---|---|
| LP NAV | `pool.totalAssets()` | > 0, trending up over time |
| Free balance for LP exits | `pool.freeBalance()` | > 0 |
| Utilization | `pool.utilization()` | < 7000 bps (70%) — alert at 8000 |
| Total bet liabilities | `pool.totalLiabilities()` | Decreases after settlement windows |
| Treasury accrued | `pool.accruedTreasury()` | Monotonically ↑ until withdrawn |
| Treasury withdrawable right now | `pool.treasuryWithdrawable()` | ≤ accruedTreasury; gap = USDC tied up in bets |
| NAV / share | `pool.convertToAssets(1e12)` | Stable or growing |
| Per-match liability | `pool.matchLiability(matchAddr)` | < `maxLiabilityPerMatchBps × totalAssets() / 10_000` |

**Alert thresholds:**
- `utilization() > 8000 bps` → too much LP capital tied up, exits may cap
- `freeBalance() < 10% × totalAssets()` → new bets approaching solvency floor
- `accruedTreasury` growing but `treasuryWithdrawable` flat → pool fully deployed to bets (acceptable short-term, watch for settlement)

### Emergency: pause pool

```
LiquidityPool.pause()  // PAUSER_ROLE (admin key)
```

Blocks all deposits, withdrawals, `recordBet`, `settleMarket`, `payWinner`, `payRefund`, and `withdrawTreasury`. Resume with `unpause()` from admin.

### Revoking a compromised or decommissioned match

```
LiquidityPool.revokeMatch(matchProxy)  // DEFAULT_ADMIN_ROLE
```

Match can no longer record bets or trigger payouts. Pre-existing liabilities remain but can only be released by a fresh authorization.

### Adjusting parameters

| Change | Caller | Function |
|---|---|---|
| Protocol fee | Admin | `setProtocolFeeBps(newBps)` — ≤ 1000 (10%) |
| Per-market cap | Admin | `setMaxLiabilityPerMarketBps(newBps)` |
| Per-match cap | Admin | `setMaxLiabilityPerMatchBps(newBps)` |
| Per-bet cap | Admin | `setMaxBetAmount(newAmount)` — 0 disables |
| Withdraw cooldown | Admin | `setDepositCooldownSeconds(newSeconds)` |
| Max odds (per match) | Match admin | `BettingMatch.setMaxAllowedOdds(newMax)` |
| Rotate treasury | Treasury (Safe) | `proposeTreasury` → `acceptTreasury` |
| Pull accrued funds | Treasury (Safe) | `withdrawTreasury(amount)` |
| Pause | Admin | `pause()` |

---

## Network Configuration

Stored in `config/<network>.json`:

```json
{
  "chainId": 88888,
  "rpcUrl": "https://rpc.chiliz.com",
  "adminKey":    "0x...",
  "treasurySafe":"0x...",
  "usdc":        "0x...",
  "liquidityPool":"0x...",
  "matches": ["0x...", "0x..."]
}
```

Keep `adminKey` and `treasurySafe` distinct. The deploy script MUST pass them as separate `initialize()` arguments.

---

## Cost estimates

| Operation | Approx. Gas |
|---|---|
| `pool.authorizeMatch()` | ~50,000 |
| `pool.deposit()` | ~95,000 |
| `pool.withdraw()` | ~95,000 |
| `pool.withdrawTreasury()` | ~55,000 |
| `pool.proposeTreasury()` | ~30,000 |
| `pool.acceptTreasury()` | ~35,000 |
| `claim()` (pool pays winner) | ~100,000 |
| `claimAll()` (N bets) | ~70,000 + N×50,000 |
