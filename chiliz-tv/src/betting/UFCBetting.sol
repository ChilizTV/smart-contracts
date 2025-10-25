// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./MatchBettingBase.sol";

/// @title UFCBetting
/// @notice 2 or 3 outcomes (Red/Blue[/Draw]) pari-mutuel for UFC fights
contract UFCBetting is MatchBettingBase {
    // Outcome indexes
    uint8 public constant RED  = 0;
    uint8 public constant BLUE = 1;
    uint8 public constant DRAW = 2; 
    uint8 public constant RED_TKO = 3; // optional
    uint8 public constant BLUE_TKO = 4; // optional

    bool public allowDraw;

    /// @notice Initialize for a UFC fight
    /// @param owner_    Admin/owner (Safe)
    /// @param token_    ERC-20 stake token
    /// @param matchId_  Identifier
    /// @param cutoffTs_ Betting cutoff
    /// @param feeBps_   Fees in bps
    /// @param treasury_ Fee receiver
    /// @param allowDraw_ If true, enable DRAW as a 3rd outcome
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

    // Convenience wrappers
    function betRed(uint256 amount) external { placeBet(RED, amount); }
    function betBlue(uint256 amount) external { placeBet(BLUE, amount); }
    function betDraw(uint256 amount) external {
        require(allowDraw, "DRAW_DISABLED");
        placeBet(DRAW, amount);
    }
}
