// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FootballMatch} from "./FootballMatch.sol";
import {BasketballMatch} from "./BasketballMatch.sol";

/// @title BettingMatchFactory
/// @notice Factory contract to deploy UUPS-upgradeable sport-specific match proxies.
/// @dev Implementation addresses are mutable so bug-fixed implementations can be rolled
///      out to new match deployments without redeploying the factory. Existing proxies
///      are NOT auto-upgraded; their DEFAULT_ADMIN_ROLE holder must call
///      upgradeToAndCall directly (or use the UpgradeBetting script).
///
///      A single shared PayoutEscrow is deployed separately and manages a whitelist
///      of authorized match proxies. After creating a match, authorize it on the
///      escrow via PayoutEscrow.authorizeMatch(matchProxy, cap).
contract BettingMatchFactory is Ownable {

    // ══════════════════════════════════════════════════════════════════════════
    // TYPES
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Sport types supported by the factory
    enum SportType { FOOTBALL, BASKETBALL }

    // ══════════════════════════════════════════════════════════════════════════
    // STATE
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice List of all deployed match proxy addresses (insertion order)
    address[] public allMatches;

    /// @notice Sport type for each deployed proxy
    mapping(address => SportType) public matchSportType;

    /// @notice Whether an address was deployed by this factory
    mapping(address => bool) public isMatch;

    /// @notice Current FootballMatch implementation used for new proxy deployments.
    /// @dev Mutable — update via setFootballImplementation(). Existing proxies unaffected.
    address public footballImplementation;

    /// @notice Current BasketballMatch implementation used for new proxy deployments.
    /// @dev Mutable — update via setBasketballImplementation(). Existing proxies unaffected.
    address public basketballImplementation;

    // ══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Emitted when a new match proxy is created
    event MatchCreated(address indexed proxy, SportType sportType, address indexed owner);

    /// @notice Emitted when the football implementation pointer is updated
    event FootballImplementationUpdated(address indexed oldImpl, address indexed newImpl);

    /// @notice Emitted when the basketball implementation pointer is updated
    event BasketballImplementationUpdated(address indexed oldImpl, address indexed newImpl);

    // ══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ══════════════════════════════════════════════════════════════════════════

    error MatchNotFound(address matchAddress);
    error InvalidAddress();

    // ══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Deploy initial implementations and initialize the factory
    constructor() Ownable(msg.sender) {
        footballImplementation   = address(new FootballMatch());
        basketballImplementation = address(new BasketballMatch());
    }

    // ══════════════════════════════════════════════════════════════════════════
    // MATCH DEPLOYMENT
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Deploy a new FootballMatch UUPS proxy and initialize it
    /// @param _matchName Human-readable match name
    /// @param _owner     Address that receives DEFAULT_ADMIN_ROLE on the proxy
    /// @return proxy     Address of the newly deployed proxy
    function createFootballMatch(
        string calldata _matchName,
        address _owner
    ) external onlyOwner returns (address proxy) {
        bytes memory initData = abi.encodeWithSelector(
            FootballMatch.initialize.selector,
            _matchName,
            _owner
        );
        proxy = address(new ERC1967Proxy(footballImplementation, initData));
        allMatches.push(proxy);
        isMatch[proxy]        = true;
        matchSportType[proxy] = SportType.FOOTBALL;
        emit MatchCreated(proxy, SportType.FOOTBALL, _owner);
    }

    /// @notice Deploy a new BasketballMatch UUPS proxy and initialize it
    /// @param _matchName Human-readable match name
    /// @param _owner     Address that receives DEFAULT_ADMIN_ROLE on the proxy
    /// @return proxy     Address of the newly deployed proxy
    function createBasketballMatch(
        string calldata _matchName,
        address _owner
    ) external onlyOwner returns (address proxy) {
        bytes memory initData = abi.encodeWithSelector(
            BasketballMatch.initialize.selector,
            _matchName,
            _owner
        );
        proxy = address(new ERC1967Proxy(basketballImplementation, initData));
        allMatches.push(proxy);
        isMatch[proxy]        = true;
        matchSportType[proxy] = SportType.BASKETBALL;
        emit MatchCreated(proxy, SportType.BASKETBALL, _owner);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // IMPLEMENTATION MANAGEMENT (Owner)
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Point the factory at a new FootballMatch implementation for future deployments.
    /// @dev Does NOT affect already-deployed proxies. Upgrade existing matches individually
    ///      via the UpgradeBetting script or upgradeToAndCall on the proxy directly.
    function setFootballImplementation(address newImpl) external onlyOwner {
        if (newImpl == address(0)) revert InvalidAddress();
        address old = footballImplementation;
        footballImplementation = newImpl;
        emit FootballImplementationUpdated(old, newImpl);
    }

    /// @notice Point the factory at a new BasketballMatch implementation for future deployments.
    function setBasketballImplementation(address newImpl) external onlyOwner {
        if (newImpl == address(0)) revert InvalidAddress();
        address old = basketballImplementation;
        basketballImplementation = newImpl;
        emit BasketballImplementationUpdated(old, newImpl);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Retrieve all deployed proxy addresses (insertion order)
    function getAllMatches() external view returns (address[] memory) {
        return allMatches;
    }

    /// @notice Get the sport type of a specific match proxy
    function getSportType(address matchAddress) external view returns (SportType) {
        if (!isMatch[matchAddress]) revert MatchNotFound(matchAddress);
        return matchSportType[matchAddress];
    }
}
