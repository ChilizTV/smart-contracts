# Treasury & Gnosis Safe Operations

## Architecture

Each network has **one Gnosis Safe** that serves as the treasury. The Safe:
- Holds `DEFAULT_ADMIN_ROLE` on the `LiquidityPool` (authorizes matches, sets parameters, upgrades)
- Is the `treasury` address on `LiquidityPool` (receives protocol fees skimmed from stakes)
- Optionally holds admin roles on `BettingMatchFactory`, `StreamWalletFactory`, `ChilizSwapRouter`

```
┌──────────────────────────────┐
│  Gnosis Safe (Treasury)      │
│                              │
│  DEFAULT_ADMIN_ROLE on:      │
│  - LiquidityPool             │
│  - BettingMatchFactory       │
│  - ChilizSwapRouter          │
└──────────────┬───────────────┘
               │ authorizeMatch() / setProtocolFeeBps() / pause() / upgrade
               ▼
┌──────────────────────────────┐
│  LiquidityPool (ERC-4626)    │◄──── BettingMatch proxies call:
│  Single USDC vault           │      recordBet / payWinner / payRefund / settleMarket
│  treasury = Safe address     │
└──────────────────────────────┘
               ▲
               │ deposit USDC → receive ctvLP shares
┌──────────────────────────────┐
│  Liquidity Providers (LPs)   │
└──────────────────────────────┘
```

## Initial Setup (After Deployment)

### 1. Authorize Each BettingMatch Proxy

For every match contract, the Safe executes:

```
Target:   LiquidityPool
Function: authorizeMatch(address matchContract)
Params:   matchContract = <BettingMatch proxy address>
Effect:   Grants MATCH_ROLE to the proxy
```

### 2. Configure Liability Caps (Optional — has sane defaults)

```
Target:   LiquidityPool
Function: setMaxLiabilityPerMarketBps(uint16 bps)
Params:   bps = max per-market exposure as bps of totalAssets() (e.g. 500 = 5%)

Target:   LiquidityPool
Function: setMaxLiabilityPerMatchBps(uint16 bps)
Params:   bps = max per-match exposure as bps of totalAssets() (e.g. 2000 = 20%)
```

### 3. Seed Initial Liquidity (Safe can act as first LP)

The Safe (or any LP) deposits USDC directly:

```
Target:   <USDC token address>
Function: approve(address spender, uint256 amount)
Params:   spender = <LiquidityPool address>
          amount  = <deposit amount in 6-decimal USDC>

Target:   <LiquidityPool address>
Function: deposit(uint256 assets, address receiver)
Params:   assets   = <same deposit amount>
          receiver = <Safe address or LP address>
```

## Operational Runbook

### Monitoring Pool Health

Query these view functions periodically (e.g., every hour):

| Check | Call | Healthy When |
|-------|------|--------------|
| Free balance | `pool.freeBalance()` | > 0; ideally > projected max payout |
| Total liabilities | `pool.totalLiabilities()` | Decreasing after settlement windows |
| NAV per share | `pool.convertToAssets(1e18)` | Stable or growing (house edge compounding) |
| Per-match liability | `pool.matchLiability(matchAddr)` | < `maxLiabilityPerMatchBps × totalAssets / 10_000` |

**Alert threshold**: `pool.freeBalance() < 10% of pool.totalAssets()` — new bets approaching cap.

### Emergency: Pause Pool

If suspicious activity is detected:

```
Target:   LiquidityPool
Function: pause()
Effect:   All deposits, withdrawals, and match operations (recordBet, payWinner, etc.) blocked
```

To resume: `pool.unpause()` (requires `DEFAULT_ADMIN_ROLE`)

### Revoking a Match

If a match contract is compromised or decommissioned:

```
Target:   LiquidityPool
Function: revokeMatch(address matchContract)
Effect:   Revokes MATCH_ROLE — match can no longer record bets or trigger payouts
```

### Adjusting Protocol Fee

```
Target:   LiquidityPool
Function: setProtocolFeeBps(uint16 newBps)
Params:   newBps <= 1000 (10% maximum)
Effect:   New fee applied on subsequent bets; accrues to treasury address
```

## Network Configuration

Treasury addresses and contract addresses are stored in `config/<network>.json`:

```json
{
  "chainId": 88882,
  "rpcUrl": "https://spicy-rpc.chiliz.com",
  "safeAddress": "0x...",
  "usdc": "0x...",
  "liquidityPool": "0x...",
  "matches": [
    "0x...",
    "0x..."
  ]
}
```

## Safe Transaction Templates

### Batch: Authorize New Match + Set Caps

```json
[
  {
    "to": "<LiquidityPool>",
    "value": "0",
    "data": "authorizeMatch(address)",
    "params": ["<newMatchProxy>"]
  },
  {
    "to": "<LiquidityPool>",
    "value": "0",
    "data": "setMaxLiabilityPerMatchBps(uint16)",
    "params": ["2000"]
  }
]
```

### Batch: Seed Liquidity

```json
[
  {
    "to": "<USDC>",
    "value": "0",
    "data": "approve(address,uint256)",
    "params": ["<LiquidityPool>", "10000000000"]
  },
  {
    "to": "<LiquidityPool>",
    "value": "0",
    "data": "deposit(uint256,address)",
    "params": ["10000000000", "<Safe address>"]
  }
]
```

## Cost Estimates

| Operation | Approx. Gas |
|-----------|-------------|
| `pool.authorizeMatch()` | ~50,000 |
| `pool.deposit()` | ~90,000 |
| `pool.withdraw()` | ~95,000 |
| `claim()` (pool pays winner) | ~100,000 |
| `claimAll()` (N bets) | ~70,000 + N×50,000 |
