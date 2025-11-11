// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./MatchBettingBase.sol";

/// @title FootballBetting
/// @author ChilizTV
/// @notice Parimutuel betting implementation for football matches with 1X2 outcomes
/// @dev Extends MatchBettingBase with 3 outcomes: HOME (0), DRAW (1), AWAY (2)
///      Used via BeaconProxy pattern - each match gets its own proxy instance
contract FootballBetting is MatchBettingBase {
    
    // ----------------------------- CONSTANTS ----------------------------
    
    /// @notice Outcome index for home team win
    uint8 public constant HOME = 0;
    
    /// @notice Outcome index for draw
    uint8 public constant DRAW = 1;
    
    /// @notice Outcome index for away team win
    uint8 public constant AWAY = 2;
    
    /// @notice Reserved for future feature: home team scores first goal
    uint8 public constant HOME_FIRST_GOAL = 3;
    
    /// @notice Reserved for future feature: away team scores first goal
    uint8 public constant AWAY_FIRST_GOAL = 4;
    
    /// @notice Reserved for future feature: no goals scored
    uint8 public constant NO_GOAL = 5;
    
    // --------------------------- INITIALIZER ----------------------------
    
    /// @notice Initializes a football match betting instance with native CHZ
    /// @dev Called by BeaconProxy constructor, can only be called once
    ///      Sets up 3 outcomes (HOME/DRAW/AWAY) for standard 1X2 betting
    /// @param owner_ Address to receive admin roles (recommended: multisig)
    /// @param matchId_ Unique match identifier
    /// @param cutoffTs_ Unix timestamp when betting closes
    /// @param feeBps_ Platform fee in basis points (max 1000 = 10%)
    /// @param treasury_ Address to receive platform fees
    /// @param minBetChz_ Minimum bet amount in CHZ (18 decimals, e.g., 5e18 = 5 CHZ)
    function initialize(
        address owner_,
        bytes32 matchId_,
        uint64 cutoffTs_,
        uint16 feeBps_,
        address treasury_,
        uint256 minBetChz_
    ) external initializer {
        _initSport(owner_, matchId_, 3, cutoffTs_, feeBps_, treasury_, minBetChz_);
    }

    // ------------------------- BETTING WRAPPERS -------------------------
    
    /// @notice Places a bet on home team to win using native CHZ with locked odds
    /// @dev Convenience wrapper for placeBet(HOME, odds), amount sent via msg.value
    /// @param odds Odds in 4 decimals (e.g., 20000 = 2.0x, 25000 = 2.5x)
    function betHome(uint64 odds) external payable { placeBet(HOME, odds); }
    
    /// @notice Places a bet on draw result using native CHZ with locked odds
    /// @dev Convenience wrapper for placeBet(DRAW, odds), amount sent via msg.value
    /// @param odds Odds in 4 decimals (e.g., 30000 = 3.0x)
    function betDraw(uint64 odds) external payable { placeBet(DRAW, odds); }
    
    /// @notice Places a bet on away team to win using native CHZ with locked odds
    /// @dev Convenience wrapper for placeBet(AWAY, odds), amount sent via msg.value
    /// @param odds Odds in 4 decimals (e.g., 18000 = 1.8x)
    function betAway(uint64 odds) external payable { placeBet(AWAY, odds); }
}
