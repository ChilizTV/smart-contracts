// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IFootballInit
/// @notice Interface for FootballBetting initialization and betting functions
/// @dev Used by MatchHubBeaconFactory to encode initialization call data for BeaconProxy
interface IFootballInit {
    /// @notice Initializes a FootballBetting contract instance
    /// @param owner_ Address to receive admin roles
    /// @param token_ ERC20 token for betting
    /// @param matchId_ Unique match identifier
    /// @param cutoffTs_ Betting cutoff timestamp
    /// @param feeBps_ Platform fee in basis points
    /// @param treasury_ Address to receive fees
    function initialize(
        address owner_,
        address token_,
        bytes32 matchId_,
        uint64 cutoffTs_,
        uint16 feeBps_,
        address treasury_
    ) external;

    /// @notice Places a bet on home team to win
    /// @param amount Amount of tokens to stake
    function betHome(uint256 amount) external;
    
    /// @notice Places a bet on draw
    /// @param amount Amount of tokens to stake
    function betDraw(uint256 amount) external;
    
    /// @notice Places a bet on away team to win
    /// @param amount Amount of tokens to stake
    function betAway(uint256 amount) external;
}
