# ChilizTV — Liquidity Provider Guide

**You (the LP) are the house.** When bettors lose, you earn. When bettors win, your capital pays them. This guide explains precisely how that works, what risks you take, and how to deposit, monitor, and withdraw.

---

## TL;DR

- You deposit **USDC** into the `LiquidityPool` and receive **ctvLP** shares (ERC-4626).
- Every losing bet sends **50% of the net stake** to LP NAV (auto-compounded into your share price) and the other **50% to a treasury claim**.
- Every winning bet is paid out from the pool. That payout is funded **only by LP capital** — the treasury's accrued claim is not at risk.
- Your withdrawal may be temporarily capped by outstanding bet liabilities (see **Free balance & utilization** below).

---

## How yield is generated

1. Bettor stakes USDC on a market at fixed odds set by the backend.
2. Bettor's stake is split: a small protocol fee goes directly to the treasury, the rest (`netStake`) enters the pool. The pool also reserves `netExposure = netStake × odds / 10000 − netStake` against its free balance to guarantee the payout if the bet wins.
3. **When the bet loses:**
   - `netExposure` reservation is released back into free balance.
   - `netStake` stays in the pool. `50% (TREASURY_SHARE_BPS)` is earmarked as `accruedTreasury`; the remaining 50% is untouched USDC that now belongs to LPs (visible as an increase in `totalAssets()` and therefore in your ctvLP share price).
4. **When the bet wins:**
   - Pool pays `payout = netStake × odds / 10000` in USDC to the winner.
   - The bet's reserved `netExposure` is released.
   - Net outflow for LP NAV = `payout − netStake = netExposure`. The treasury's accrued claim is NOT touched.

Over many bets with a correctly-priced house edge, losing stakes dominate winning payouts and ctvLP share price trends upward. This yield is **real yield** — there is no token emission, no inflationary subsidy. Every unit of LP NAV comes from actual bet losses.

---

## The treasury asymmetry (read this carefully)

**The treasury's accrued claim is a fixed historical allocation.** When a bet loses, 50% of the net stake is booked to `accruedTreasury` and that figure never decreases except when the treasury actively pulls it via `withdrawTreasury()`. Winning bets do NOT reduce the treasury's claim.

**What this means for you as an LP:**

- You absorb **100% of the downside** from winning-bet payouts.
- The treasury captures a **fixed, variance-free 50%** of every losing stake.
- Your risk-adjusted return is lower than if treasury shared drawdowns with you (pari-passu model).

**Worked example** — LP deposits 1000 USDC:

| Event | Pool USDC | accruedTreasury | totalAssets | ctvLP share price |
|---|---:|---:|---:|---:|
| LP deposits 1000 | 1000 | 0 | 1000 | 1.00 |
| Bettors lose 200 net stake | 1200 | 100 | 1100 | 1.10 |
| Bettor wins: stake 200, payout 1000 | 400 | 100 | 300 | 0.30 |

After the winning bet, LP is down 70% while treasury's 100 claim is intact. If the house edge is priced correctly, over a large sample of bets the losing-bet compounding outpaces winning-bet drawdowns — but day-to-day LP returns are much more volatile than treasury accrual.

---

## Free balance & utilization

Two numbers you should watch:

- **`freeBalance()`** — USDC available right now for LP withdrawals (= `totalAssets()`).
- **`utilization()`** — `totalLiabilities / totalAssets` in basis points. 7000 = 70% utilization; 10000+ = fully utilized.

When utilization is high, `maxWithdraw(you)` may return less than the nominal value of your shares. This is protective: the pool cannot pay out more than `freeBalance` without risking bet-payout insolvency. When bets settle, free balance replenishes and the cap lifts automatically. Cooldown (`depositCooldownSeconds`) also gates each individual depositor — you cannot deposit and withdraw inside the cooldown window.

**Peak-weekend planning:** if you anticipate needing liquidity during a heavy match day, withdraw ahead of kickoff. Mid-weekend withdrawals may be partially blocked until games settle.

---

## Depositing

```solidity
USDC.approve(address(liquidityPool), amount);
liquidityPool.deposit(amount, yourAddress);
```

You receive ctvLP shares. Share price = `totalAssets() / totalSupply`. Shares are transferable ERC-20s.

**Inflation-attack protection.** The pool uses OpenZeppelin 5.x's `_decimalsOffset = 6`, which makes the classic first-depositor attack uneconomic. You can safely deposit any amount regardless of whether you're the first LP or the hundredth.

---

## Withdrawing

```solidity
liquidityPool.withdraw(assets, yourAddress, yourAddress);
// or
liquidityPool.redeem(shares, yourAddress, yourAddress);
```

Both respect `maxWithdraw` / `maxRedeem`, which return the minimum of your share-value and the pool's free balance. If you try to pull more than the cap, the transaction reverts cleanly.

Before withdrawing, check:
- `maxWithdraw(you)` — how much you can pull right now.
- `utilization()` — pool stress level.
- Your `lastDepositAt[you] + depositCooldownSeconds` — cooldown expiry.

---

## Risks you are taking

1. **Odds-setter error or compromise.** The backend sets odds off-chain. A bug or compromised key could systematically favor bettors. Mitigations: `maxAllowedOdds` cap per match, `maxBetAmount` pool-wide cap, emergency `pause()`. All three are operational, not eliminating the risk.
2. **Tail events.** A correlated cluster of winning bets (favorites all hitting on one match day) can rapidly draw down LP NAV. Per-market and per-match caps mitigate this but do not eliminate cross-match correlation.
3. **Smart-contract risk.** The pool is UUPS-upgradeable. An upgrade bug or admin-key compromise could damage the pool. Upgrades are gated by `DEFAULT_ADMIN_ROLE` which is distinct from the treasury Safe.
4. **Withdrawal liquidity risk.** During high utilization, you may face temporary withdrawal caps. Plan exits around settlement cycles.
5. **Treasury asymmetry.** Already covered above — LPs carry all downside; treasury's accrual is protected.
6. **Pricing model risk.** If the house edge is underpriced (or backend pricing is stale vs. real market), LPs lose expected return. You are implicitly trusting the odds-setter's modelling.

---

## Key contract reads for monitoring

| Call | Meaning |
|---|---|
| `totalAssets()` | LP-owned USDC (your share of this = ctvLP % × totalAssets). |
| `freeBalance()` | USDC available for LP withdrawals right now. |
| `totalLiabilities()` | USDC reserved for outstanding bet payouts. |
| `utilization()` | Liabilities / totalAssets in bps. |
| `accruedTreasury()` | Treasury's pull-claim on the pool (NOT LP capital). |
| `treasuryWithdrawable()` | How much treasury can pull RIGHT NOW. |
| `maxWithdraw(you)` | Your current withdraw cap. |
| `maxRedeem(you)` | Same, in share terms. |
| `convertToAssets(shares)` | Convert your shares to nominal USDC value. |
| `lastDepositAt(you)` | Your cooldown anchor timestamp. |

---

## What ChilizTV commits to LPs

- **No emission subsidies.** All yield is real yield from losing bets.
- **Transparent accounting.** Every bet, settlement, accrual, and withdrawal emits events. Anyone can reconstruct full pool history from logs.
- **No sudden parameter flips.** Protocol fee, caps, and cooldowns are admin-settable but each change emits a public event. LP-docs updates will flag any material shift.
- **Separation of powers.** Admin key (operational) and Safe treasury are distinct. Admin cannot touch accrued treasury funds. Treasury cannot upgrade the contract or authorize matches.
- **Pull-based treasury.** Accrued treasury balance stays inside the pool until the Safe actively withdraws — if the team never pulls, their accrued balance continues to back pool solvency (but does not dilute LP share price).

---

## Contract addresses

See [DEPLOYMENT_SUMMARY.md](../DEPLOYMENT_SUMMARY.md) for current deployed addresses (mainnet + testnet).
