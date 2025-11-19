// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "./BettingMatch.sol";

/// @title BettingMatchFactory
/// @notice Factory contract to deploy UUPS-upgradeable BettingMatch proxies
contract BettingMatchFactory is Ownable {
    /// @notice Address of the BettingMatch logic contract implementation
    address public implementation;

    /// @notice List of all deployed BettingMatch proxy addresses
    address[] public allMatches;

    /// @notice Emitted when the implementation logic address is updated
    /// @param newImplementation The new implementation address
    event ImplementationUpdated(address indexed newImplementation);

    /// @notice Emitted when a new BettingMatch proxy is created
    /// @param proxy Address of the deployed proxy
    /// @param owner Address that will own the new proxy
    event BettingMatchCreated(address indexed proxy, address indexed owner);

    /// @notice Custom error for zero-address inputs
    error ZeroAddress();

    /// @param _implementation Initial BettingMatch implementation address
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

    /// @notice Deploy a new BettingMatch proxy and initialize it
    /// @dev Uses ERC-1967 proxy pattern to delegate to `implementation`
    /// @param _matchName The name of the match
    /// @param _owner The owner of the match contract
    /// @return proxy Address of the newly deployed proxy
    function createMatch(string calldata _matchName, address _owner) external returns (address proxy) {
        bytes memory initData = abi.encodeWithSelector(
            BettingMatch.initialize.selector,
            _matchName,
            _owner
        );
        proxy = address(new ERC1967Proxy(implementation, initData));
        allMatches.push(proxy);
        emit BettingMatchCreated(proxy, _owner);
    }

    /// @notice Retrieve all deployed proxy addresses
    /// @return Array of BettingMatch proxy addresses
    function getAllMatches() external view returns (address[] memory) {
        return allMatches;
    }
    
}
