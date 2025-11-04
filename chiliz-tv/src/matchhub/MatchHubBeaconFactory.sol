// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "../SportBeaconRegistry.sol";
import "../interfaces/IFootballInit.sol";
import "../interfaces/IUFCInit.sol";

/// @title MatchHubBeaconFactory
/// @author ChilizTV
/// @notice Factory contract for creating sport-specific match betting instances via BeaconProxy
/// @dev Each match gets its own BeaconProxy pointing to sport-specific beacon
///      Enables per-match instances while allowing global upgrades through beacons
///      Only owner can create matches (typically backend service or multisig)
contract MatchHubBeaconFactory is Ownable{
    
    // ----------------------------- STORAGE ------------------------------
    
    /// @notice Reference to the SportBeaconRegistry containing all sport beacons
    SportBeaconRegistry public immutable registry;
    
    /// @notice Address receiving platform fees
    address public immutable treasury;
    
    /// @notice Minimum bet amount in CHZ (18 decimals)
    uint256 public immutable minBetChz;

    /// @notice Sport identifier for Football (1X2 betting)
    bytes32 public constant SPORT_FOOTBALL = keccak256("FOOTBALL");
    
    /// @notice Sport identifier for UFC/MMA (2-3 outcome betting)
    bytes32 public constant SPORT_UFC      = keccak256("UFC");

    // ----------------------------- EVENTS -------------------------------
    
    /// @notice Emitted when a new match betting instance is created
    /// @param sport Sport identifier hash
    /// @param proxy Address of the newly created BeaconProxy
    /// @param matchId Unique match identifier
    /// @param owner Address granted admin roles on the match
    event MatchHubCreated(
        bytes32 indexed sport,
        address indexed proxy,
        bytes32 indexed matchId,
        address owner
    );

    // --------------------------- CONSTRUCTOR ----------------------------
    
    /// @notice Initializes the factory with owner, registry and default parameters
    /// @param initialOwner Address that can create matches (recommended: backend service or multisig)
    /// @param registryAddr Address of the SportBeaconRegistry
    /// @param treasuryAddr Address to receive platform fees
    /// @param minBetChz_ Minimum bet amount in CHZ (18 decimals, e.g., 5e18 = 5 CHZ)
    constructor(
        address initialOwner,
        address registryAddr,
        address treasuryAddr,
        uint256 minBetChz_
    ) Ownable(initialOwner) {
        require(registryAddr != address(0), "REGISTRY_ZERO");
        require(treasuryAddr != address(0), "TREASURY_ZERO");
        registry = SportBeaconRegistry(registryAddr);
        treasury = treasuryAddr;
        minBetChz = minBetChz_;
    }

    // ----------------------- MATCH CREATION FUNCTIONS -------------------
    
    /// @notice Creates a new Football match betting instance with native CHZ
    /// @dev Creates BeaconProxy pointing to Football beacon with 1X2 outcomes
    ///      Reverts if Football beacon not set in registry
    ///      Uses factory's default treasury and minBetChz
    /// @param owner_ Address to receive admin roles on the match
    /// @param matchId_ Unique match identifier
    /// @param cutoffTs_ Betting cutoff timestamp
    /// @param feeBps_ Platform fee in basis points
    /// @param treasuryOverride_ Optional treasury override (use address(0) for default)
    /// @param minBetChzOverride_ Optional minimum bet override (use 0 for default)
    /// @return proxy Address of the created BeaconProxy
    function createFootballMatch(
        address owner_,
        bytes32 matchId_,
        uint64 cutoffTs_,
        uint16 feeBps_,
        address treasuryOverride_,
        uint256 minBetChzOverride_
    ) external onlyOwner returns (address proxy) {
        address beacon = registry.getBeacon(SPORT_FOOTBALL);
        require(beacon != address(0), "FOOTBALL_BEACON_NOT_SET");

        proxy = address(new BeaconProxy(beacon, abi.encodeWithSelector(
            IFootballInit.initialize.selector,
            owner_,
            matchId_,
            cutoffTs_,
            feeBps_,
            treasuryOverride_ != address(0) ? treasuryOverride_ : treasury,
            minBetChzOverride_ != 0 ? minBetChzOverride_ : minBetChz
        )));
        
        emit MatchHubCreated(SPORT_FOOTBALL, proxy, matchId_, owner_);
    }

    /// @notice Creates a new UFC/MMA match betting instance with native CHZ
    /// @dev Creates BeaconProxy pointing to UFC beacon with 2 or 3 outcomes
    ///      Reverts if UFC beacon not set in registry
    ///      Uses factory's default treasury and minBetChz
    /// @param owner_ Address to receive admin roles on the match
    /// @param matchId_ Unique match identifier
    /// @param cutoffTs_ Betting cutoff timestamp
    /// @param feeBps_ Platform fee in basis points
    /// @param treasuryOverride_ Optional treasury override (use address(0) for default)
    /// @param minBetChzOverride_ Optional minimum bet override (use 0 for default)
    /// @param allowDraw_ If true, enables 3 outcomes (RED/BLUE/DRAW); if false, 2 outcomes (RED/BLUE)
    /// @return proxy Address of the created BeaconProxy
    function createUFCMatch(
        address owner_,
        bytes32 matchId_,
        uint64 cutoffTs_,
        uint16 feeBps_,
        address treasuryOverride_,
        uint256 minBetChzOverride_,
        bool allowDraw_
    ) external onlyOwner returns (address proxy) {
        address beacon = registry.getBeacon(SPORT_UFC);
        require(beacon != address(0), "UFC_BEACON_NOT_SET");

        proxy = address(new BeaconProxy(beacon, abi.encodeWithSelector(
            IUFCInit.initialize.selector,
            owner_,
            matchId_,
            cutoffTs_,
            feeBps_,
            treasuryOverride_ != address(0) ? treasuryOverride_ : treasury,
            minBetChzOverride_ != 0 ? minBetChzOverride_ : minBetChz,
            allowDraw_
        )));
        
        emit MatchHubCreated(SPORT_UFC, proxy, matchId_, owner_);
    }
}
