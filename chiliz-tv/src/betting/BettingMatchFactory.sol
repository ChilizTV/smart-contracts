// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FootballMatch} from "./FootballMatch.sol";
import {BasketballMatch} from "./BasketballMatch.sol";

/// @title BettingMatchFactory
/// @notice Factory contract to deploy UUPS-upgradeable sport-specific match proxies with dynamic odds
contract BettingMatchFactory is Ownable {
    /// @notice Sport types supported by the factory
    enum SportType { FOOTBALL, BASKETBALL }

    /// @notice List of all deployed match proxy addresses
    address[] public allMatches;

    /// @notice Mapping from match address to its sport type
    mapping(address => SportType) public matchSportType;

    /// @notice Immutable implementation contracts deployed once
    address private immutable FOOTBALL_IMPLEMENTATION;
    address private immutable BASKETBALL_IMPLEMENTATION;

    /// @notice Emitted when a new match proxy is created
    event MatchCreated(address indexed proxy, SportType sportType, address indexed owner);

    /// @notice Deploy implementations and initialize factory
    constructor() Ownable(msg.sender) {
        FOOTBALL_IMPLEMENTATION = address(new FootballMatch());
        BASKETBALL_IMPLEMENTATION = address(new BasketballMatch());
    }

    /// @notice Deploy a new FootballMatch proxy and initialize it
    /// @param _matchName The name of the match
    /// @param _owner The owner of the match contract
    /// @return proxy Address of the newly deployed proxy
    function createFootballMatch(string calldata _matchName, address _owner) external returns (address proxy) {
        bytes memory initData = abi.encodeWithSelector(
            FootballMatch.initialize.selector,
            _matchName,
            _owner
        );
        proxy = address(new ERC1967Proxy(FOOTBALL_IMPLEMENTATION, initData));
        allMatches.push(proxy);
        matchSportType[proxy] = SportType.FOOTBALL;
        emit MatchCreated(proxy, SportType.FOOTBALL, _owner);
    }

    /// @notice Deploy a new BasketballMatch proxy and initialize it
    /// @param _matchName The name of the match
    /// @param _owner The owner of the match contract
    /// @return proxy Address of the newly deployed proxy
    function createBasketballMatch(string calldata _matchName, address _owner) external returns (address proxy) {
        bytes memory initData = abi.encodeWithSelector(
            BasketballMatch.initialize.selector,
            _matchName,
            _owner
        );
        proxy = address(new ERC1967Proxy(BASKETBALL_IMPLEMENTATION, initData));
        allMatches.push(proxy);
        matchSportType[proxy] = SportType.BASKETBALL;
        emit MatchCreated(proxy, SportType.BASKETBALL, _owner);
    }

    /// @notice Retrieve all deployed proxy addresses
    /// @return Array of match proxy addresses
    function getAllMatches() external view returns (address[] memory) {
        return allMatches;
    }

    /// @notice Get the sport type of a specific match
    /// @param matchAddress The address of the match contract
    /// @return The sport type (FOOTBALL or BASKETBALL)
    function getSportType(address matchAddress) external view returns (SportType) {
        return matchSportType[matchAddress];
    }
}
