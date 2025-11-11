// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IUFCInit
/// @notice Interface for UFCBetting initialization and betting functions with native CHZ
/// @dev Used by MatchHubBeaconFactory to encode initialization call data for BeaconProxy
interface IUFCInit {
    /// @notice Initializes a UFCBetting contract instance with native CHZ
    /// @param owner_ Address to receive admin roles
    /// @param matchId_ Unique match identifier
    /// @param cutoffTs_ Betting cutoff timestamp
    /// @param feeBps_ Platform fee in basis points
    /// @param treasury_ Address to receive fees
    /// @param minBetChz_ Minimum bet in CHZ (18 decimals, e.g. 5e18 = 5 CHZ)
    /// @param allowDraw_ Whether to enable draw betting (3 outcomes vs 2)
    function initialize(
        address owner_,
        bytes32 matchId_,
        uint64 cutoffTs_,
        uint16 feeBps_,
        address treasury_,
        uint256 minBetChz_,
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
