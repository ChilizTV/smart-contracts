// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

/**
 * @title StreamBeaconRegistry
 * @notice Manages the UpgradeableBeacon for StreamWallet implementation
 * @dev Similar to SportBeaconRegistry but for streaming wallets
 */
contract StreamBeaconRegistry is Ownable {
    /// @notice The beacon that points to the current StreamWallet implementation
    UpgradeableBeacon public beacon;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event BeaconCreated(address indexed beacon, address indexed implementation);
    event BeaconUpgraded(address indexed newImplementation);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error NullAddressImplementation();
    error BeaconAlreadySet();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @param initialOwner Owner of the registry (Gnosis Safe recommended)
     */
    constructor(address initialOwner) Ownable(initialOwner) {}

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier checkNullAddress(address _addr) {
        if (_addr == address(0)) revert NullAddressImplementation();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                           BEACON MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set or upgrade the StreamWallet implementation
     * @param implementation New logic implementation address (non-zero)
     */
    function setImplementation(address implementation)
        external
        onlyOwner
        checkNullAddress(implementation)
    {
        if (address(beacon) == address(0)) {
            // Create beacon for the first time
            beacon = new UpgradeableBeacon(implementation, address(this));
            emit BeaconCreated(address(beacon), implementation);
        } else {
            // Upgrade existing beacon
            beacon.upgradeTo(implementation);
            emit BeaconUpgraded(implementation);
        }
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get the beacon address
     * @return The beacon address (address(0) if not set)
     */
    function getBeacon() external view returns (address) {
        return address(beacon);
    }

    /**
     * @notice Get current implementation address
     * @return Current implementation address (reverts if not set)
     */
    function getImplementation()
        external
        view
        checkNullAddress(address(beacon))
        returns (address)
    {
        return beacon.implementation();
    }

    /**
     * @notice Check if beacon has been initialized
     * @return bool True if beacon exists
     */
    function isInitialized() external view returns (bool) {
        return address(beacon) != address(0);
    }
}
