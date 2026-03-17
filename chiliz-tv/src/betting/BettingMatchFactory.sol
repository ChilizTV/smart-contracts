// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FootballMatch} from "./FootballMatch.sol";
import {BasketballMatch} from "./BasketballMatch.sol";
import {PayoutEscrow} from "./PayoutEscrow.sol";

/// @title BettingMatchFactory
/// @notice Factory contract to deploy UUPS-upgradeable sport-specific match proxies,
///         each paired with a dedicated PayoutEscrow for isolated treasury backstop.
contract BettingMatchFactory is Ownable {
    /// @notice Sport types supported by the factory
    enum SportType { FOOTBALL, BASKETBALL }

    /// @notice Bundled addresses returned on match creation
    struct MatchInfo {
        address proxy;
        address escrow;
    }

    /// @notice List of all deployed match proxy addresses
    address[] public allMatches;

    /// @notice Mapping from match address to its sport type
    mapping(address => SportType) public matchSportType;

    /// @notice Tracks whether an address was deployed by this factory
    mapping(address => bool) public isMatch;

    /// @notice Per-match dedicated escrow address
    mapping(address => address) public matchEscrow;

    /// @notice Immutable implementation contracts deployed once
    address private immutable FOOTBALL_IMPLEMENTATION;
    address private immutable BASKETBALL_IMPLEMENTATION;

    /// @notice Emitted when a new match proxy + escrow pair is created
    event MatchCreated(
        address indexed proxy,
        address indexed escrow,
        SportType sportType,
        address indexed owner
    );

    error MatchNotFound(address matchAddress);

    /// @notice Deploy implementations and initialize factory
    constructor() Ownable(msg.sender) {
        FOOTBALL_IMPLEMENTATION = address(new FootballMatch());
        BASKETBALL_IMPLEMENTATION = address(new BasketballMatch());
    }

    /// @notice Deploy a new FootballMatch proxy + dedicated PayoutEscrow
    /// @param _matchName    The name of the match
    /// @param _matchOwner   Owner/admin of the match contract
    /// @param _usdc         USDC token address for the escrow
    /// @param _escrowOwner  Owner of the escrow (Gnosis Safe / treasury)
    /// @return info         Addresses of the deployed proxy and escrow
    function createFootballMatch(
        string calldata _matchName,
        address _matchOwner,
        address _usdc,
        address _escrowOwner
    ) external onlyOwner returns (MatchInfo memory info) {
        info.proxy = _deployProxy(
            FOOTBALL_IMPLEMENTATION,
            abi.encodeWithSelector(FootballMatch.initialize.selector, _matchName, _matchOwner)
        );
        info.escrow = _deployEscrow(info.proxy, _usdc, _escrowOwner);
        _register(info.proxy, info.escrow, SportType.FOOTBALL, _matchOwner);
    }

    /// @notice Deploy a new BasketballMatch proxy + dedicated PayoutEscrow
    /// @param _matchName    The name of the match
    /// @param _matchOwner   Owner/admin of the match contract
    /// @param _usdc         USDC token address for the escrow
    /// @param _escrowOwner  Owner of the escrow (Gnosis Safe / treasury)
    /// @return info         Addresses of the deployed proxy and escrow
    function createBasketballMatch(
        string calldata _matchName,
        address _matchOwner,
        address _usdc,
        address _escrowOwner
    ) external onlyOwner returns (MatchInfo memory info) {
        info.proxy = _deployProxy(
            BASKETBALL_IMPLEMENTATION,
            abi.encodeWithSelector(BasketballMatch.initialize.selector, _matchName, _matchOwner)
        );
        info.escrow = _deployEscrow(info.proxy, _usdc, _escrowOwner);
        _register(info.proxy, info.escrow, SportType.BASKETBALL, _matchOwner);
    }

    /// @notice Retrieve all deployed proxy addresses
    function getAllMatches() external view returns (address[] memory) {
        return allMatches;
    }

    /// @notice Get the sport type of a specific match
    function getSportType(address matchAddress) external view returns (SportType) {
        if (!isMatch[matchAddress]) revert MatchNotFound(matchAddress);
        return matchSportType[matchAddress];
    }

    /// @notice Get the dedicated escrow for a match
    function getEscrow(address matchAddress) external view returns (address) {
        if (!isMatch[matchAddress]) revert MatchNotFound(matchAddress);
        return matchEscrow[matchAddress];
    }

    // ── internals ─────────────────────────────────────────────────────────────

    function _deployProxy(address impl, bytes memory initData) internal returns (address proxy) {
        proxy = address(new ERC1967Proxy(impl, initData));
    }

    function _deployEscrow(
        address matchProxy,
        address _usdc,
        address _escrowOwner
    ) internal returns (address escrow) {
        escrow = address(new PayoutEscrow(_usdc, matchProxy, _escrowOwner));
    }

    function _register(
        address proxy,
        address escrow,
        SportType sport,
        address matchOwner
    ) internal {
        allMatches.push(proxy);
        isMatch[proxy] = true;
        matchSportType[proxy] = sport;
        matchEscrow[proxy] = escrow;
        emit MatchCreated(proxy, escrow, sport, matchOwner);
    }
}
