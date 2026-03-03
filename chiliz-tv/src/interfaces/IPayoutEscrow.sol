// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @title IPayoutEscrow
/// @notice Minimal interface used by BettingMatch to pull payout deficits from escrow
interface IPayoutEscrow {
    /// @notice Transfer USDT from the escrow to a recipient
    /// @param recipient Address to receive USDT
    /// @param amount USDT amount (6 decimals)
    function disburseTo(address recipient, uint256 amount) external;
}
