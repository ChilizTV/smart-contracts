// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title ILiquidityPool
/// @notice External surface of the ChilizTV LP pool. Implemented by
///         `LiquidityPool.sol`. Consumed by `BettingMatch` and
///         `ChilizSwapRouter` to deposit stake liquidity and pull payouts.
/// @dev    USDC is the only asset. All bet amounts are denominated in USDC
///         (6 decimals). `netExposure` = `payout - netStake`, i.e. the pool's
///         marginal exposure for a bet (the stake itself enters the pool).
interface ILiquidityPool {
    // -----------------------------------------------------------------------
    // BettingMatch / ChilizSwapRouter-facing
    // -----------------------------------------------------------------------

    /// @notice Record a bet that has already been funded to the pool.
    /// @dev    Caller MUST have transferred `netStake` USDC to the pool
    ///         before calling. Caller must hold `MATCH_ROLE` or `ROUTER_ROLE`.
    ///         Reverts on cap breach, insufficient free balance, or breach
    ///         of the pool-wide `maxBetAmount` (if set).
    function recordBet(
        address bettingMatch,
        uint256 marketId,
        address bettor,
        uint256 netStake,
        uint256 netExposure
    ) external;

    /// @notice Release losing-side liability AND accrue the treasury's share
    ///         of the losing stakes at market resolution.
    /// @dev    Called by the match contract during `resolveMarket`.
    ///         `losingNetStake` is the sum of post-fee stakes on all losing
    ///         selections. 50% of this amount (`TREASURY_SHARE_BPS`) accrues
    ///         as a pull-based claim for the treasury; the remaining 50%
    ///         stays in the pool and compounds into LP NAV.
    function settleMarket(
        address bettingMatch,
        uint256 marketId,
        uint256 losingLiabilityToRelease,
        uint256 losingNetStake
    ) external;

    /// @notice Pay a winner. Transfers `payout` USDC and releases the bet's
    ///         reserved liability.
    /// @dev    `releasedNetExposure` MUST equal the `netExposure` originally
    ///         passed to `recordBet` for this winning bet (= payout - stake).
    ///         The pool balance drops by `payout`; `totalLiabilities` drops
    ///         by `releasedNetExposure`. Mismatched values will drift the
    ///         pool's accounting.
    function payWinner(
        address bettingMatch,
        uint256 marketId,
        address to,
        uint256 payout,
        uint256 releasedNetExposure
    ) external;

    /// @notice Refund a bettor on cancellation. Transfers `stake` USDC and
    ///         releases the bet's reserved net exposure.
    function payRefund(
        address bettingMatch,
        uint256 marketId,
        address to,
        uint256 stake,
        uint256 releasedNetExposure
    ) external;

    // -----------------------------------------------------------------------
    // Treasury rotation (2-step) and withdrawal (pull-based)
    // -----------------------------------------------------------------------

    /// @notice Propose a new treasury address. Only callable by the current
    ///         treasury. Rotation completes when the pending address calls
    ///         `acceptTreasury()`.
    function proposeTreasury(address newTreasury) external;

    /// @notice Cancel a pending treasury proposal. Only callable by the
    ///         current treasury.
    function cancelTreasuryProposal() external;

    /// @notice Accept the pending treasury role. Must be called from the
    ///         address set via `proposeTreasury`. Completes the rotation.
    function acceptTreasury() external;

    /// @notice Withdraw `amount` of accrued treasury balance in USDC.
    /// @dev    Only callable by the current treasury. Funds always go to
    ///         `treasury`. Reverts if `amount` exceeds either the accrued
    ///         balance or the pool's free (non-bet-liability) balance.
    function withdrawTreasury(uint256 amount) external;

    // -----------------------------------------------------------------------
    // Admin (DEFAULT_ADMIN_ROLE-gated)
    // -----------------------------------------------------------------------

    /// @notice Set a pool-wide maximum per-bet netStake. 0 = disabled.
    function setMaxBetAmount(uint256 newMax) external;

    /// @notice Grant `MATCH_ROLE` to a match proxy, allowing it to call
    ///         `recordBet` / `settleMarket` / `payWinner` / `payRefund`.
    /// @dev    Callable by holders of `DEFAULT_ADMIN_ROLE` or the narrower
    ///         `MATCH_AUTHORIZER_ROLE` (granted to the `BettingMatchFactory`
    ///         so it can register matches atomically with their creation).
    function authorizeMatch(address bettingMatch) external;

    /// @notice Revoke `MATCH_ROLE` from a match proxy.
    /// @dev    Same access as `authorizeMatch`.
    function revokeMatch(address bettingMatch) external;

    // -----------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------

    /// @notice Configured protocol fee in basis points (stake skim at placement).
    function protocolFeeBps() external view returns (uint16);

    /// @notice Address receiving protocol fees and holding withdrawal rights
    ///         over accrued treasury balance.
    function treasury() external view returns (address);

    /// @notice Pending treasury in a 2-step rotation (0 = none pending).
    function pendingTreasury() external view returns (address);

    /// @notice Treasury's accrued USDC claim against the pool. Physically
    ///         held inside the pool contract; withdrawable via
    ///         `withdrawTreasury`.
    function accruedTreasury() external view returns (uint256);

    /// @notice Amount of USDC the treasury can withdraw RIGHT NOW. Equal to
    ///         `min(accruedTreasury, USDC.balance - totalLiabilities)` —
    ///         i.e. capped so a withdrawal can never starve live bet payouts.
    function treasuryWithdrawable() external view returns (uint256);

    /// @notice USDC not currently reserved for potential winners or treasury
    ///         accrual. Same value as ERC-4626 `totalAssets()`.
    function freeBalance() external view returns (uint256);

    /// @notice Global sum of reserved winning-side liabilities.
    function totalLiabilities() external view returns (uint256);

    /// @notice Pool utilization in basis points:
    ///         `totalLiabilities * 10_000 / totalAssets()`. Capped at
    ///         `type(uint16).max` to avoid overflow when totalAssets → 0.
    function utilization() external view returns (uint16);

    /// @notice Pool-wide maximum per-bet netStake (0 = disabled).
    function maxBetAmount() external view returns (uint256);
}
