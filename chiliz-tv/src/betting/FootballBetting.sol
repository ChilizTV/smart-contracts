// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./MatchBettingBase.sol";

/// @title FootballBetting
/// @notice 1x2 (Home/Draw/Away) pari-mutuel for football matches
contract FootballBetting is MatchBettingBase {
    // Outcome indexes
    uint8 public constant HOME = 0;
    uint8 public constant DRAW = 1;
    uint8 public constant AWAY = 2;
    uint8 public constant HOME_FIRST_GOAL = 3;
    uint8 public constant AWAY_FIRST_GOAL = 4;
    uint8 public constant NO_GOAL = 5;
    
    /// @notice Initialize for a football match
    /// @param owner_    Admin/owner (Safe)
    /// @param token_    ERC-20 stake token
    /// @param matchId_  Identifier
    /// @param cutoffTs_ Betting cutoff
    /// @param feeBps_   Fees in bps
    /// @param treasury_ Fee receiver
    function initialize(
        address owner_,
        address token_,
        bytes32 matchId_,
        uint64 cutoffTs_,
        uint16 feeBps_,
        address treasury_
    ) external initializer {
        // Football = 3 outcomes
        _initSport(owner_, token_, matchId_, cutoffTs_, feeBps_, treasury_, 3);
    }

    // Convenience wrappers
    function betHome(uint256 amount) external { placeBet(HOME, amount); }
    function betDraw(uint256 amount) external { placeBet(DRAW, amount); }
    function betAway(uint256 amount) external { placeBet(AWAY, amount); }
}
