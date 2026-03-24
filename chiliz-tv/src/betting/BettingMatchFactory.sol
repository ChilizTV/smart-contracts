// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FootballMatch} from "./FootballMatch.sol";
import {BasketballMatch} from "./BasketballMatch.sol";
import {PayoutEscrow} from "./PayoutEscrow.sol";

/// @title BettingMatchFactory
/// @notice Factory contract to deploy UUPS-upgradeable sport-specific match proxies with dynamic odds
/// @dev Implementation addresses are mutable so that bug-fixed implementations can be rolled out
///      to new match deployments without redeploying the factory. Existing proxies are NOT
///      auto-upgraded; their DEFAULT_ADMIN_ROLE holder must call upgradeToAndCall directly.
contract BettingMatchFactory is Ownable {

    // ══════════════════════════════════════════════════════════════════════════
    // TYPES
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Sport types supported by the factory
    enum SportType { FOOTBALL, BASKETBALL }

    // ══════════════════════════════════════════════════════════════════════════
    // STATE
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice List of all deployed match proxy addresses
    address[] public allMatches;

    /// @notice Mapping from match address to its sport type
    mapping(address => SportType) public matchSportType;

    /// @notice Tracks whether an address was deployed by this factory
    mapping(address => bool) public isMatch;

    /// @notice Current FootballMatch implementation used for new proxy deployments.
    /// @dev Mutable so bug-fixes can be applied to new matches without redeploying factory.
    ///      Existing proxies are NOT auto-upgraded.
    address public footballImplementation;

    /// @notice Current BasketballMatch implementation used for new proxy deployments.
    /// @dev Mutable so bug-fixes can be applied to new matches without redeploying factory.
    ///      Existing proxies are NOT auto-upgraded.
    address public basketballImplementation;

    // ══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Emitted when a new match proxy is created
    event MatchCreated(address indexed proxy, SportType sportType, address indexed owner);

    /// @notice Emitted when the football implementation is updated for future deployments
    event FootballImplementationUpdated(address indexed oldImpl, address indexed newImpl);

    /// @notice Emitted when the basketball implementation is updated for future deployments
    event BasketballImplementationUpdated(address indexed oldImpl, address indexed newImpl);

    // ══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ══════════════════════════════════════════════════════════════════════════

    error MatchNotFound(address matchAddress);
    error InvalidAddress();

    // ══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Deploy initial implementations and initialize factory
    constructor() Ownable(msg.sender) {
        footballImplementation = address(new FootballMatch());
        basketballImplementation = address(new BasketballMatch());
    }

    // ══════════════════════════════════════════════════════════════════════════
    // MATCH DEPLOYMENT
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Deploy a new FootballMatch proxy and initialize it
    /// @param _matchName The name of the match
    /// @param _owner The owner of the match contract
    /// @return proxy Address of the newly deployed proxy
    function createFootballMatch(string calldata _matchName, address _owner) external onlyOwner returns (address proxy) {
        bytes memory initData = abi.encodeWithSelector(
            FootballMatch.initialize.selector,
            _matchName,
            _owner
        );
        proxy = address(new ERC1967Proxy(footballImplementation, initData));
        allMatches.push(proxy);
        isMatch[proxy] = true;
        matchSportType[proxy] = SportType.FOOTBALL;
        emit MatchCreated(proxy, SportType.FOOTBALL, _owner);
    }

    /// @notice Deploy a new BasketballMatch proxy and initialize it
    /// @param _matchName The name of the match
    /// @param _owner The owner of the match contract
    /// @return proxy Address of the newly deployed proxy
    function createBasketballMatch(string calldata _matchName, address _owner) external onlyOwner returns (address proxy) {
        bytes memory initData = abi.encodeWithSelector(
            BasketballMatch.initialize.selector,
            _matchName,
            _owner
        );
        proxy = address(new ERC1967Proxy(basketballImplementation, initData));
        allMatches.push(proxy);
        isMatch[proxy] = true;
        matchSportType[proxy] = SportType.BASKETBALL;
        emit MatchCreated(proxy, SportType.BASKETBALL, _owner);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // IMPLEMENTATION MANAGEMENT (Owner)
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Update the FootballMatch implementation used for all future proxy deployments.
    /// @dev Does NOT affect already-deployed proxies. Those must be upgraded individually
    ///      by their DEFAULT_ADMIN_ROLE holder calling upgradeToAndCall on the proxy.
    /// @param newImpl Address of the new FootballMatch implementation
    function setFootballImplementation(address newImpl) external onlyOwner {
        if (newImpl == address(0)) revert InvalidAddress();
        address old = footballImplementation;
        footballImplementation = newImpl;
        emit FootballImplementationUpdated(old, newImpl);
    }

    /// @notice Update the BasketballMatch implementation used for all future proxy deployments.
    /// @dev Does NOT affect already-deployed proxies. Those must be upgraded individually
    ///      by their DEFAULT_ADMIN_ROLE holder calling upgradeToAndCall on the proxy.
    /// @param newImpl Address of the new BasketballMatch implementation
    function setBasketballImplementation(address newImpl) external onlyOwner {
        if (newImpl == address(0)) revert InvalidAddress();
        address old = basketballImplementation;
        basketballImplementation = newImpl;
        emit BasketballImplementationUpdated(old, newImpl);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════════════════════════

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
