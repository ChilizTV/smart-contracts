# Treasury & Gnosis Safe Operations

> **Roadmap note (2026-04-16).** The current treasury model is a **static, Safe-funded `PayoutEscrow`** — described in this doc. A **liquidity-pool model** (LPs deposit to back payouts and earn yield from the house edge priced into fixed odds) was agreed on 2026-04-15 as the future direction. No LP contract exists in the current codebase. When the LP-pool work starts, this document — and the escrow auth/fund flow described below — will need to be superseded or augmented. Until then, `PayoutEscrow` is the live, authoritative solvency mechanism.

## Architecture

Each network has **one Gnosis Safe** that serves as the treasury. The Safe:
- Owns the `PayoutEscrow` contract
- Funds it with USDC to back betting payouts
- Controls authorization of BettingMatch proxies
- Can pause/unpause the escrow in emergencies

```
â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
â”‚  Gnosis Safe     â”‚
â”‚  (Treasury)      â”‚
â”‚                  â”‚
â”‚  Owns:           â”‚
â”‚  - PayoutEscrow  â”‚
â”‚  - BettingMatchFactory (optional) â”‚
â”‚  - ChilizSwapRouter (optional)    â”‚
â””â”€â”€â”€â”€â”€â”€â”€â”€â”¬â”€â”€â”€â”€â”€â”€â”€â”€â”˜
         â”‚ fund() / authorizeMatch() / pause()
         â–¼
â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
â”‚  PayoutEscrow    â”‚â—„â”€â”€â”€â”€â”€â”€ BettingMatch proxies call disburseTo()
â”‚  (USDC Reserve)  â”‚
â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜
```

## Initial Setup (After Deployment)

### 1. Authorize Each BettingMatch Proxy

For every match contract that needs payout support, the Safe executes:

```
Target:   PayoutEscrow
Function: authorizeMatch(address matchContract, uint256 cap)
Params:   matchContract = <BettingMatch proxy>
          cap           = max cumulative USDC this match may pull from escrow
```
The `cap` is added to `totalAllocated`, reserving that much of the escrow's
balance for this match. Use `updateMatchCap` to adjust it later.

### 2. Set Escrow on Each Match

The match admin (or Safe if it holds ADMIN_ROLE) calls:

```
Target:   <BettingMatch proxy>
Function: setPayoutEscrow(address escrow)
Param:    <PayoutEscrow address>
```

### 3. Fund the Escrow

The Safe executes two transactions (can be batched):

**Transaction 1 â€” Approve USDC:**
```
Target:   <USDC token address>
Function: approve(address spender, uint256 amount)
Params:   spender = <PayoutEscrow address>
          amount  = <funding amount in 6-decimal USDC>
```

**Transaction 2 â€” Deposit:**
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
| Total liabilities | `match.totalUSDCLiabilities()` | Decreasing after claims |
| Total disbursed | `escrow.totalDisbursed()` | Growing slowly |

**Alert threshold**: `escrow.availableBalance() < 2 Ã— Î£ match.getFundingDeficit()`

### Replenishing the Escrow

When the escrow balance drops below the alert threshold:

1. Calculate total deficit across all active matches
2. Add a safety buffer (e.g., 2Ã— deficit)
3. Execute Safe transaction: `approve` + `fund`

### Emergency: Pause Escrow

If suspicious activity is detected:

```
Target:   PayoutEscrow
Function: pause()
Effect:   All disburseTo() calls will revert â†’ claims from escrow blocked
          Claims from contract balance still work
```

To resume: `escrow.unpause()`

### Emergency: Withdraw from Escrow

If funds need to be recovered:

```
Target:   PayoutEscrow
Function: withdraw(uint256 amount)
Effect:   USDC transferred from escrow to Safe
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
  "usdc": "0x...",
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
    "data": "authorizeMatch(address,uint256)",
    "params": ["<match1>", "<cap in 6-decimal USDC>"]
  },
  {
    "to": "<USDC>",
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
| `claimAll()` (N bets) | ~60,000 + NÃ—45,000 |
