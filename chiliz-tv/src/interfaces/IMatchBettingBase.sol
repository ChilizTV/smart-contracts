// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IMatchBettingBase
/// @author ChilizTV
/// @notice Interface for the parimutuel betting engine used behind BeaconProxy per match
/// @dev Covers views, admin functions, betting, settlement, and claim functions
///      Also includes events and errors for easier integration (frontend, tests, external contracts)
interface IMatchBettingBase {
    
    // ========================================================================
    // ROLES (constant views)
    // ========================================================================
    
    /// @notice Returns the admin role identifier
    function ADMIN_ROLE() external view returns (bytes32);
    
    /// @notice Returns the settler role identifier
    function SETTLER_ROLE() external view returns (bytes32);
    
    /// @notice Returns the pauser role identifier
    function PAUSER_ROLE() external view returns (bytes32);

    // ========================================================================
    // STORAGE (state views)
    // ========================================================================
    
    /// @notice ERC20 token used for betting
    function betToken() external view returns (IERC20);
    
    /// @notice Address receiving platform fees
    function treasury() external view returns (address);
    
    /// @notice Unique match identifier
    function matchId() external view returns (bytes32);
    
    /// @notice Betting cutoff timestamp
    function cutoffTs() external view returns (uint64);
    
    /// @notice Platform fee in basis points
    function feeBps() external view returns (uint16);
    
    /// @notice Total number of possible outcomes
    function outcomesCount() external view returns (uint8);
    
    /// @notice Whether the match has been settled
    function settled() external view returns (bool);
    
    /// @notice Winning outcome index (valid after settlement)
    function winningOutcome() external view returns (uint8);

    /// @notice Returns total amount staked on a specific outcome
    /// @param outcome Outcome index
    function pool(uint8 outcome) external view returns (uint256);

    /// @notice Returns amount a user has bet on a specific outcome
    /// @param user User address
    /// @param outcome Outcome index
    function bets(address user, uint8 outcome) external view returns (uint256);

    /// @notice Returns whether a user has already claimed their winnings
    /// @param user User address
    function claimed(address user) external view returns (bool);

    // ========================================================================
    // EVENTS
    // ========================================================================
    
    /// @notice Emitted when match betting is initialized
    event Initialized(
        address indexed owner,
        address indexed token,
        bytes32 indexed matchId,
        uint8 outcomesCount,
        uint64 cutoffTs,
        uint16 feeBps,
        address treasury
    );

    /// @notice Emitted when a bet is placed
    event BetPlaced(address indexed user, uint8 indexed outcome, uint256 amount);
    
    /// @notice Emitted when match outcome is settled
    event Settled(uint8 indexed winningOutcome, uint256 totalPool, uint256 feeAmount);
    
    /// @notice Emitted when winnings are claimed
    event Claimed(address indexed user, uint256 payout);
    
    /// @notice Emitted when cutoff time is updated
    event CutoffUpdated(uint64 newCutoff);
    
    /// @notice Emitted when treasury address is updated
    event TreasuryUpdated(address newTreasury);
    
    /// @notice Emitted when fee is updated
    event FeeUpdated(uint16 newFeeBps);

    // ========================================================================
    // ERRORS
    // ========================================================================
    
    /// @notice Thrown when invalid outcome index provided
    error InvalidOutcome();
    
    /// @notice Thrown when invalid parameter provided
    error InvalidParam();
    
    /// @notice Thrown when betting after cutoff
    error BettingClosed();
    
    /// @notice Thrown when attempting to settle already settled match
    error AlreadySettled();
    
    /// @notice Thrown when action requires settlement first
    error NotSettled();
    
    /// @notice Thrown when user has nothing to claim
    error NothingToClaim();
    
    /// @notice Thrown when zero address provided
    error ZeroAddress();
    
    /// @notice Thrown when outcomes count exceeds maximum
    error TooManyOutcomes();

    // ========================================================================
    // ADMIN ACTIONS
    // ========================================================================
    
    /// @notice Updates betting cutoff timestamp (only before settlement)
    /// @param newCutoff New cutoff timestamp
    function setCutoff(uint64 newCutoff) external;

    /// @notice Updates treasury address
    /// @param newTreasury New treasury address
    function setTreasury(address newTreasury) external;

    /// @notice Updates platform fee in basis points (max 1000 = 10%)
    /// @param newFeeBps New fee in basis points
    function setFeeBps(uint16 newFeeBps) external;

    /// @notice Pauses betting operations
    function pause() external;
    
    /// @notice Resumes betting operations
    function unpause() external;

    // ========================================================================
    // BETTING
    // ========================================================================
    
    /// @notice Places a bet on an outcome
    /// @param outcome Outcome index [0..outcomesCount-1]
    /// @param amount Amount of ERC20 tokens to stake (requires prior approval)
    function placeBet(uint8 outcome, uint256 amount) external;

    // ========================================================================
    // SETTLEMENT
    // ========================================================================
    
    /// @notice Settles the match with winning outcome
    /// @param winning Index of the winning outcome
    function settle(uint8 winning) external;

    // ========================================================================
    // CLAIM
    // ========================================================================
    
    /// @notice Claims parimutuel payout for caller (after settlement)
    function claim() external;

    /// @notice Sweeps funds to treasury if no winning bets exist (after settlement)
    function sweepIfNoWinners() external;

    // ========================================================================
    // VIEW FUNCTIONS
    // ========================================================================
    
    /// @notice Returns sum of all bets across all outcomes
    /// @return Total pool amount
    function totalPoolAmount() external view returns (uint256);

    /// @notice Estimates pending payout for a user (returns 0 if not applicable)
    /// @param user User address to check
    /// @return Estimated payout amount
    function pendingPayout(address user) external view returns (uint256);
}
