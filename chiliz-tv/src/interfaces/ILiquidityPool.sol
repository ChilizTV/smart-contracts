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
    ///         Reverts on cap breach or insufficient free balance.
    function recordBet(
        address bettingMatch,
        uint256 marketId,
        address bettor,
        uint256 netStake,
        uint256 netExposure
    ) external;

    /// @notice Release losing-side liability when a market resolves.
    /// @dev    Called by the match contract during `resolveMarket`.
    function settleMarket(
        address bettingMatch,
        uint256 marketId,
        uint256 losingLiabilityToRelease
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
    // Governance / view
    // -----------------------------------------------------------------------

    /// @notice Configured protocol fee in basis points (stake skim at placement).
    function protocolFeeBps() external view returns (uint16);

    /// @notice Address receiving protocol fees (NOT LP capital).
    function treasury() external view returns (address);

    /// @notice USDC not currently reserved for potential winners.
    function freeBalance() external view returns (uint256);

    /// @notice Global sum of reserved winning-side liabilities.
    function totalLiabilities() external view returns (uint256);
}
