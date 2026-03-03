# Treasury & Gnosis Safe Operations

## Architecture

Each network has **one Gnosis Safe** that serves as the treasury. The Safe:
- Owns the `PayoutEscrow` contract
- Funds it with USDT to back betting payouts
- Controls authorization of BettingMatch proxies
- Can pause/unpause the escrow in emergencies

```
┌─────────────────┐
│  Gnosis Safe     │
│  (Treasury)      │
│                  │
│  Owns:           │
│  - PayoutEscrow  │
│  - BettingMatchFactory (optional) │
│  - ChilizSwapRouter (optional)    │
└────────┬────────┘
         │ fund() / authorizeMatch() / pause()
         ▼
┌─────────────────┐
│  PayoutEscrow    │◄────── BettingMatch proxies call disburseTo()
│  (USDT Reserve)  │
└─────────────────┘
```

## Initial Setup (After Deployment)

### 1. Authorize Each BettingMatch Proxy

For every match contract that needs payout support, the Safe executes:

```
Target:   PayoutEscrow
Function: authorizeMatch(address matchContract)
```

### 2. Set Escrow on Each Match

The match admin (or Safe if it holds ADMIN_ROLE) calls:

```
Target:   <BettingMatch proxy>
Function: setPayoutEscrow(address escrow)
Param:    <PayoutEscrow address>
```

### 3. Fund the Escrow

The Safe executes two transactions (can be batched):

**Transaction 1 — Approve USDT:**
```
Target:   <USDT token address>
Function: approve(address spender, uint256 amount)
Params:   spender = <PayoutEscrow address>
          amount  = <funding amount in 6-decimal USDT>
```

**Transaction 2 — Deposit:**
```
Target:   <PayoutEscrow address>
Function: fund(uint256 amount)
Param:    amount = <same funding amount>
```

## Operational Runbook

### Monitoring Escrow Health

Query these view functions periodically (e.g., every hour):

| Check | Call | Healthy When |
|-------|------|--------------|
| Escrow balance | `escrow.availableBalance()` | > sum of all match deficits |
| Per-match deficit | `match.getFundingDeficit()` | 0 (fully funded) or small |
| Total liabilities | `match.totalUSDTLiabilities()` | Decreasing after claims |
| Total disbursed | `escrow.totalDisbursed()` | Growing slowly |

**Alert threshold**: `escrow.availableBalance() < 2 × Σ match.getFundingDeficit()`

### Replenishing the Escrow

When the escrow balance drops below the alert threshold:

1. Calculate total deficit across all active matches
2. Add a safety buffer (e.g., 2× deficit)
3. Execute Safe transaction: `approve` + `fund`

### Emergency: Pause Escrow

If suspicious activity is detected:

```
Target:   PayoutEscrow
Function: pause()
Effect:   All disburseTo() calls will revert → claims from escrow blocked
          Claims from contract balance still work
```

To resume: `escrow.unpause()`

### Emergency: Withdraw from Escrow

If funds need to be recovered:

```
Target:   PayoutEscrow
Function: withdraw(uint256 amount)
Effect:   USDT transferred from escrow to Safe
```

### Revoking a Match

If a match contract is compromised or decommissioned:

```
Target:   PayoutEscrow
Function: revokeMatch(address matchContract)
Effect:   Match can no longer pull from escrow
```

## Network Configuration

Treasury addresses and contract addresses are stored in `config/<network>.json`:

```json
{
  "chainId": 88882,
  "rpcUrl": "https://spicy-rpc.chiliz.com",
  "safeAddress": "0x...",
  "usdt": "0x...",
  "payoutEscrow": "0x...",
  "matches": [
    "0x...",
    "0x..."
  ]
}
```

## Safe Transaction Templates

### Batch: Authorize + Fund (for new deployment)

```json
[
  {
    "to": "<PayoutEscrow>",
    "value": "0",
    "data": "authorizeMatch(address)",
    "params": ["<match1>"]
  },
  {
    "to": "<USDT>",
    "value": "0",
    "data": "approve(address,uint256)",
    "params": ["<PayoutEscrow>", "1000000000"]
  },
  {
    "to": "<PayoutEscrow>",
    "value": "0",
    "data": "fund(uint256)",
    "params": ["1000000000"]
  }
]
```

### Batch: Authorize New Match

```json
[
  {
    "to": "<PayoutEscrow>",
    "value": "0",
    "data": "authorizeMatch(address)",
    "params": ["<newMatchProxy>"]
  }
]
```

## Cost Estimates

| Operation | Approx. Gas |
|-----------|-------------|
| `escrow.fund()` | ~60,000 |
| `escrow.authorizeMatch()` | ~45,000 |
| `escrow.withdraw()` | ~55,000 |
| `claim()` (contract pays) | ~85,000 |
| `claim()` (escrow fallback) | ~130,000 |
| `claimAll()` (N bets) | ~60,000 + N×45,000 |
