// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "../SportBeaconRegistry.sol";
import "../interfaces/IFootballInit.sol";
import "../interfaces/IUFCInit.sol";

contract MatchHubBeaconFactory is Ownable{
    SportBeaconRegistry public immutable registry;

    bytes32 public constant SPORT_FOOTBALL = keccak256("FOOTBALL");
    bytes32 public constant SPORT_UFC      = keccak256("UFC");

    event MatchHubCreated(
        bytes32 indexed sport,
        address indexed proxy,
        bytes32 indexed matchId,
        address owner
    );

    constructor(address initialOwner, address registryAddr) Ownable(initialOwner) {
        require(registryAddr != address(0), "REGISTRY_ZERO");
        registry = SportBeaconRegistry(registryAddr);
    }

    /// FOOTBALL (1x2)
    function createFootballMatch(
        address owner_,
        address token_,
        bytes32 matchId_,
        uint64 cutoffTs_,
        uint16 feeBps_,
        address treasury_
    ) external onlyOwner returns (address proxy) {
        address beacon = registry.getBeacon(SPORT_FOOTBALL);
        require(beacon != address(0), "FOOTBALL_BEACON_NOT_SET");

        bytes memory initData = abi.encodeWithSelector(
            IFootballInit.initialize.selector,
            owner_, token_, matchId_, cutoffTs_, feeBps_, treasury_
        );

        proxy = address(new BeaconProxy(beacon, initData));
        emit MatchHubCreated(SPORT_FOOTBALL, proxy, matchId_, owner_);
    }

    /// UFC (2 ou 3 issues selon allowDraw)
    function createUFCMatch(
        address owner_,
        address token_,
        bytes32 matchId_,
        uint64 cutoffTs_,
        uint16 feeBps_,
        address treasury_,
        bool allowDraw_
    ) external onlyOwner returns (address proxy) {
        address beacon = registry.getBeacon(SPORT_UFC);
        require(beacon != address(0), "UFC_BEACON_NOT_SET");

        bytes memory initData = abi.encodeWithSelector(
            IUFCInit.initialize.selector,
            owner_, token_, matchId_, cutoffTs_, feeBps_, treasury_, allowDraw_
        );

        proxy = address(new BeaconProxy(beacon, initData));
        emit MatchHubCreated(SPORT_UFC, proxy, matchId_, owner_);
    }
}
