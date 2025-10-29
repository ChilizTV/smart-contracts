// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "./MatchHub.sol";

/// @title MatchHubFactory
/// @notice Factory contract to deploy UUPS‑upgradeable MatchHub proxies
contract MatchHubFactory is Ownable {
    /// @notice Address of the MatchHub logic contract implementation
    address public implementation;

    /// @notice List of all deployed MatchHub proxy addresses
    address[] public allHubs;

    /// @notice Emitted when the implementation logic address is updated
    /// @param newImplementation The new implementation address
    event ImplementationUpdated(address indexed newImplementation);

    /// @notice Emitted when a new MatchHub proxy is created
    /// @param proxy Address of the deployed proxy
    /// @param owner Address that will own the new proxy
    event MatchHubCreated(address indexed proxy, address indexed owner);

    /// @notice Custom error for zero‑address inputs
    error ZeroAddress();

    /// @param _implementation Initial MatchHub implementation address
    constructor(address _implementation) Ownable(msg.sender) {
        if (_implementation == address(0)) revert ZeroAddress();
        implementation = _implementation;
    }

    /// @notice Update the logic contract address for future proxies
    /// @param _newImpl New implementation contract address
    function setImplementation(address _newImpl) external onlyOwner {
        if (_newImpl == address(0)) revert ZeroAddress();
        implementation = _newImpl;
        emit ImplementationUpdated(_newImpl);
    }

    /// @notice Deploy a new MatchHub proxy and initialize it for the caller
    /// @dev Uses ERC‑1967 proxy pattern to delegate to `implementation`
    /// @return proxy Address of the newly deployed proxy
    function createHub() external returns (address proxy) {
        bytes memory initData = abi.encodeWithSelector(
            MatchHub.initialize.selector,
            msg.sender
        );
        proxy = address(new ERC1967Proxy(implementation, initData));
        allHubs.push(proxy);
        emit MatchHubCreated(proxy, msg.sender);
    }

    /// @notice Retrieve all deployed proxy addresses
    /// @return Array of MatchHub proxy addresses
    function getAllHubs() external view returns (address[] memory) {
        return allHubs;
    }
}
