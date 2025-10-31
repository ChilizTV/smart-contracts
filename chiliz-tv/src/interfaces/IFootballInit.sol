// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IFootballInit
/// @notice Interface for FootballBetting initialization and betting functions with native CHZ
/// @dev Used by MatchHubBeaconFactory to encode initialization call data for BeaconProxy
interface IFootballInit {
    /// @notice Initializes a FootballBetting contract instance with native CHZ
    /// @param owner_ Address to receive admin roles
    /// @param priceFeed_ Chainlink price feed for CHZ/USD
    /// @param matchId_ Unique match identifier
    /// @param cutoffTs_ Betting cutoff timestamp
    /// @param feeBps_ Platform fee in basis points
    /// @param treasury_ Address to receive fees
    /// @param minBetUsd_ Minimum bet in USD (8 decimals, e.g. 5e8 = $5)
    function initialize(
        address owner_,
        address priceFeed_,
        bytes32 matchId_,
        uint64 cutoffTs_,
        uint16 feeBps_,
        address treasury_,
        uint256 minBetUsd_
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
