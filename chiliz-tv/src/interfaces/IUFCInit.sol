// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IUFCInit
/// @notice Interface for UFCBetting initialization and betting functions with native CHZ
/// @dev Used by MatchHubBeaconFactory to encode initialization call data for BeaconProxy
interface IUFCInit {
    /// @notice Initializes a UFCBetting contract instance with native CHZ
    /// @param owner_ Address to receive admin roles
    /// @param priceFeed_ Chainlink price feed for CHZ/USD
    /// @param matchId_ Unique match identifier
    /// @param cutoffTs_ Betting cutoff timestamp
    /// @param feeBps_ Platform fee in basis points
    /// @param treasury_ Address to receive fees
    /// @param minBetUsd_ Minimum bet in USD (8 decimals, e.g. 5e8 = $5)
    /// @param allowDraw_ Whether to enable draw betting (3 outcomes vs 2)
    function initialize(
        address owner_,
        address priceFeed_,
        bytes32 matchId_,
        uint64 cutoffTs_,
        uint16 feeBps_,
        address treasury_,
        uint256 minBetUsd_,
        bool allowDraw_
    ) external;

    /// @notice Places a bet on Red corner fighter using native CHZ
    /// @dev Amount is sent via msg.value
    function betRed() external payable;
    
    /// @notice Places a bet on Blue corner fighter using native CHZ
    /// @dev Amount is sent via msg.value
    function betBlue() external payable;
    
    /// @notice Places a bet on draw using native CHZ (only if enabled)
    /// @dev Amount is sent via msg.value
    function betDraw() external payable;
}
