// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IUFCInit {
    function initialize(
        address owner_,
        address token_,
        bytes32 matchId_,
        uint64 cutoffTs_,
        uint16 feeBps_,
        address treasury_,
        bool allowDraw_
    ) external;
}
