// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IFootballInit {
    function initialize(
        address owner_,
        address token_,
        bytes32 matchId_,
        uint64 cutoffTs_,
        uint16 feeBps_,
        address treasury_
    ) external;

        // Convenience wrappers
    function betHome(uint256 amount) external ;
    function betDraw(uint256 amount) external ;
    function betAway(uint256 amount) external ;
}
