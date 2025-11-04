// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./MatchBettingBase.sol";

/// @title UFCBetting
/// @author ChilizTV
/// @notice Parimutuel betting implementation for UFC/MMA fights with 2-3 outcomes
/// @dev Extends MatchBettingBase with RED (0), BLUE (1), optional DRAW (2)
///      Supports both 2-outcome (no draw) and 3-outcome (draw allowed) configurations
///      Used via BeaconProxy pattern - each fight gets its own proxy instance
contract UFCBetting is MatchBettingBase {
    
    // ----------------------------- CONSTANTS ----------------------------
    
    /// @notice Outcome index for Red corner fighter win
    uint8 public constant RED  = 0;
    
    /// @notice Outcome index for Blue corner fighter win
    uint8 public constant BLUE = 1;
    
    /// @notice Outcome index for draw (if enabled)
    uint8 public constant DRAW = 2;
    
    /// @notice Reserved for future feature: Red corner wins by TKO/KO
    uint8 public constant RED_TKO = 3;
    
    /// @notice Reserved for future feature: Blue corner wins by TKO/KO
    uint8 public constant BLUE_TKO = 4;

    // ----------------------------- STORAGE ------------------------------
    
    /// @notice Whether draw betting is enabled for this fight
    /// @dev If false, only RED and BLUE outcomes are valid (2 outcomes)
    ///      If true, DRAW is also valid (3 outcomes)
    bool public allowDraw;

    // --------------------------- INITIALIZER ----------------------------
    
    /// @notice Initializes a UFC fight betting instance with native CHZ
    /// @dev Called by BeaconProxy constructor, can only be called once
    ///      Sets up 2 outcomes (RED/BLUE) or 3 outcomes (RED/BLUE/DRAW)
    /// @param owner_ Address to receive admin roles (recommended: multisig)
    /// @param matchId_ Unique fight identifier
    /// @param cutoffTs_ Unix timestamp when betting closes
    /// @param feeBps_ Platform fee in basis points (max 1000 = 10%)
    /// @param treasury_ Address to receive platform fees
    /// @param minBetChz_ Minimum bet amount in CHZ (18 decimals, e.g., 5e18 = 5 CHZ)
    /// @param allowDraw_ If true, enables DRAW as third outcome; if false, only RED/BLUE
    function initialize(
        address owner_,
        bytes32 matchId_,
        uint64 cutoffTs_,
        uint16 feeBps_,
        address treasury_,
        uint256 minBetChz_,
        bool allowDraw_
    ) external initializer {
        allowDraw = allowDraw_;
        uint8 outcomes = allowDraw_ ? 3 : 2;
        _initSport(owner_, matchId_, outcomes, cutoffTs_, feeBps_, treasury_, minBetChz_);
    }

    // ------------------------- BETTING WRAPPERS -------------------------
    
    /// @notice Places a bet on Red corner fighter to win using native CHZ
    /// @dev Convenience wrapper for placeBet(RED), amount sent via msg.value
    function betRed() external payable { placeBet(RED); }
    
    /// @notice Places a bet on Blue corner fighter to win using native CHZ
    /// @dev Convenience wrapper for placeBet(BLUE), amount sent via msg.value
    function betBlue() external payable { placeBet(BLUE); }
    
    /// @notice Places a bet on draw result using native CHZ
    /// @dev Convenience wrapper for placeBet(DRAW), amount sent via msg.value
    ///      Only available if allowDraw was set to true during initialization
    function betDraw() external payable {
        require(allowDraw, "DRAW_DISABLED");
        placeBet(DRAW);
    }
}
