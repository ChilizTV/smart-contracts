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
    
    /// @notice Initializes a UFC fight betting instance
    /// @dev Called by BeaconProxy constructor, can only be called once
    ///      Sets up 2 outcomes (RED/BLUE) or 3 outcomes (RED/BLUE/DRAW)
    /// @param owner_ Address to receive admin roles (recommended: multisig)
    /// @param token_ ERC20 token address for bets
    /// @param matchId_ Unique fight identifier
    /// @param cutoffTs_ Unix timestamp when betting closes
    /// @param feeBps_ Platform fee in basis points (max 1000 = 10%)
    /// @param treasury_ Address to receive platform fees
    /// @param allowDraw_ If true, enables DRAW as third outcome; if false, only RED/BLUE
    function initialize(
        address owner_,
        address token_,
        bytes32 matchId_,
        uint64 cutoffTs_,
        uint16 feeBps_,
        address treasury_,
        bool allowDraw_
    ) external initializer {
        allowDraw = allowDraw_;
        uint8 outcomes = allowDraw_ ? 3 : 2;
        _initSport(owner_, token_, matchId_, cutoffTs_, feeBps_, treasury_, outcomes);
    }

    // ------------------------- BETTING WRAPPERS -------------------------
    
    /// @notice Places a bet on Red corner fighter to win
    /// @dev Convenience wrapper for placeBet(RED, amount)
    /// @param amount Amount of betToken to stake
    function betRed(uint256 amount) external { placeBet(RED, amount); }
    
    /// @notice Places a bet on Blue corner fighter to win
    /// @dev Convenience wrapper for placeBet(BLUE, amount)
    /// @param amount Amount of betToken to stake
    function betBlue(uint256 amount) external { placeBet(BLUE, amount); }
    
    /// @notice Places a bet on draw result
    /// @dev Convenience wrapper for placeBet(DRAW, amount)
    ///      Only available if allowDraw was set to true during initialization
    /// @param amount Amount of betToken to stake
    function betDraw(uint256 amount) external {
        require(allowDraw, "DRAW_DISABLED");
        placeBet(DRAW, amount);
    }
}
