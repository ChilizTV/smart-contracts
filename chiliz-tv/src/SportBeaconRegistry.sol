// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

/// @title SportBeaconRegistry
/// @author ChilizTV
/// @notice Central registry managing UpgradeableBeacons for different sport betting implementations
/// @dev Maintains one beacon per sport type (identified by bytes32 hash)
///      Enables upgrading all match instances of a sport simultaneously via beacon pattern
///      Examples: keccak256("FOOTBALL"), keccak256("UFC"), keccak256("BASKETBALL")
contract SportBeaconRegistry is Ownable {
    
    // ----------------------------- STORAGE ------------------------------
    
    /// @notice Mapping from sport identifier to its UpgradeableBeacon
    /// @dev sport hash => beacon contract
    mapping(bytes32 => UpgradeableBeacon) private _beacons;

    // ----------------------------- EVENTS -------------------------------
    
    /// @notice Emitted when a new sport beacon is created
    /// @param sport Sport identifier hash
    /// @param beacon Address of the new UpgradeableBeacon
    /// @param implementation Initial implementation address
    event SportBeaconCreated(bytes32 indexed sport, address indexed beacon, address indexed implementation);
    
    /// @notice Emitted when a sport's implementation is upgraded
    /// @param sport Sport identifier hash
    /// @param newImplementation Address of the new implementation
    event SportBeaconUpgraded(bytes32 indexed sport, address indexed newImplementation);

    // ----------------------------- ERRORS -------------------------------
    
    /// @notice Thrown when a zero address is provided for implementation
    error NullAddressImplementation();
    
    // --------------------------- CONSTRUCTOR ----------------------------
    
    /// @notice Initializes the registry with an owner
    /// @param initialOwner Address that will own the registry (recommended: Gnosis Safe multisig)
    constructor(address initialOwner) Ownable(initialOwner) {}

    // ---------------------------- MODIFIERS -----------------------------
    
    /// @notice Ensures address is not zero
    /// @param _addr Address to check
    modifier checkNullAddress(address _addr){
         if (_addr == address(0)) revert NullAddressImplementation();
         _;
    }
    
    // ------------------------- ADMIN FUNCTIONS --------------------------
    
    /// @notice Creates a new beacon or upgrades an existing one for a sport
    /// @dev If beacon doesn't exist, creates new UpgradeableBeacon
    ///      If beacon exists, upgrades it to new implementation
    ///      All existing BeaconProxies for this sport will use new implementation
    /// @param sport Sport identifier (e.g., keccak256("FOOTBALL"))
    /// @param implementation Address of the new logic contract (must be non-zero)
    function setSportImplementation(bytes32 sport, address implementation) external onlyOwner checkNullAddress(implementation){

        UpgradeableBeacon beacon = _beacons[sport];

        if (address(beacon) == address(0)) {
            // Create new beacon with msg.sender as initial owner
            beacon = new UpgradeableBeacon(implementation, msg.sender);
            _beacons[sport] = beacon;
            emit SportBeaconCreated(sport, address(beacon), implementation);
        } else {
            // Upgrade existing beacon to new implementation
            beacon.upgradeTo(implementation);
            emit SportBeaconUpgraded(sport, implementation);
        }
    }

    // ------------------------------ VIEWS -------------------------------
    
    /// @notice Returns the beacon address for a sport
    /// @param sport Sport identifier hash
    /// @return Beacon contract address (address(0) if not set)
    function getBeacon(bytes32 sport) external view returns (address) {
        return address(_beacons[sport]);
    }

    /// @notice Returns the current implementation address for a sport
    /// @dev Reverts if beacon doesn't exist (zero address check)
    /// @param sport Sport identifier hash
    /// @return Current implementation contract address
    function getImplementation(bytes32 sport) external view checkNullAddress(address(_beacons[sport])) returns (address) {
        return UpgradeableBeacon(address(_beacons[sport])).implementation();
    }
}
