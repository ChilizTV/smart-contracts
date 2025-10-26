// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

/// @title SportBeaconRegistry
/// @notice Maintains one UpgradeableBeacon per sport (e.g., FOOTBALL, BASKETBALL)
contract SportBeaconRegistry is Ownable {
    /// @dev sport id => beacon
    mapping(bytes32 => UpgradeableBeacon) private _beacons;

    event SportBeaconCreated(bytes32 indexed sport, address indexed beacon, address indexed implementation);
    event SportBeaconUpgraded(bytes32 indexed sport, address indexed newImplementation);

    error NullAddressImplementation();
    /// @param initialOwner Owner of the registry (Gnosis Safe recommandé)
    constructor(address initialOwner) Ownable(initialOwner) {}

    modifier checkNullAddress(address _addr){
         if (_addr == address(0)) revert NullAddressImplementation();
         _;
    }
    /// @notice Create or upgrade the beacon for a sport
    /// @param sport A bytes32 tag (e.g., keccak256("FOOTBALL"))
    /// @param implementation New logic implementation address (non-zero)
    function setSportImplementation(bytes32 sport, address implementation) external onlyOwner checkNullAddress(implementation){

        UpgradeableBeacon beacon = _beacons[sport];

        if (address(beacon) == address(0)) {
            beacon = new UpgradeableBeacon(implementation, msg.sender);
            // Optionnel: transférer plus tard la propriété au Safe/Timelock:
            // beacon.transferOwnership(owner());
            _beacons[sport] = beacon;
            emit SportBeaconCreated(sport, address(beacon), implementation);
        } else {
            beacon.upgradeTo(implementation);
            emit SportBeaconUpgraded(sport, implementation);
        }
    }

    /// @return The beacon address for a sport (0x0 if not set)
    function getBeacon(bytes32 sport) external view returns (address) {
        return address(_beacons[sport]);
    }

    /// @return Current implementation address for a sport (reverts if not set)
    function getImplementation(bytes32 sport) external view checkNullAddress(address(_beacons[sport])) returns (address) {
        return UpgradeableBeacon(address(_beacons[sport])).implementation();
    }
}
