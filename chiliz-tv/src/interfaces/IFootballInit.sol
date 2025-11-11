// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IFootballInit
/// @notice Interface for FootballBetting initialization and betting functions with native CHZ
/// @dev Used by MatchHubBeaconFactory to encode initialization call data for BeaconProxy
interface IFootballInit {
    /// @notice Initializes a FootballBetting contract instance with native CHZ
    /// @param owner_ Address to receive admin roles
    /// @param matchId_ Unique match identifier
    /// @param cutoffTs_ Betting cutoff timestamp
    /// @param feeBps_ Platform fee in basis points
    /// @param treasury_ Address to receive fees
    /// @param minBetChz_ Minimum bet in CHZ (18 decimals, e.g. 5e18 = 5 CHZ)
    function initialize(
        address owner_,
        bytes32 matchId_,
        uint64 cutoffTs_,
        uint16 feeBps_,
        address treasury_,
        uint256 minBetChz_
    ) external;

    /// @notice Places a bet on home team to win using native CHZ
    /// @dev Amount is sent via msg.value
    function betHome() external payable;
    
    /// @notice Places a bet on draw using native CHZ
    /// @dev Amount is sent via msg.value
    function betDraw() external payable;
    
    /// @notice Places a bet on away team to win using native CHZ
    /// @dev Amount is sent via msg.value
    function betAway() external payable;
}
