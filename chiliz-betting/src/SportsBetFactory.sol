// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "./SportsBet.sol";

/// @title SportsBetFactory
/// @notice Factory contract for deploying UUPS-upgradeable SportsBet proxies
contract SportsBetFactory is Ownable {
    /// @notice Address of the SportsBet logic contract implementation
    address public implementation;

    /// @notice List of all deployed SportsBet proxy addresses
    address[] public allBets;

    /// @notice Mapping of whitelisted addresses allowed to create bets
    mapping(address => bool) public whitelist;

    /// @notice Emitted when the implementation address is updated
    /// @param newImplementation The new logic contract address
    event ImplementationUpdated(address indexed newImplementation);

    /// @notice Emitted when a new SportsBet proxy is created
    /// @param proxy Address of the deployed proxy
    /// @param eventId Identifier of the sports event
    event SportsBetCreated(address indexed proxy, uint256 indexed eventId);

    /// @notice Emitted when a whitelist entry is added or removed
    /// @param user Address whose whitelist status changed
    /// @param whitelisted Whether the address is now whitelisted
    event WhitelistUpdated(address indexed user, bool whitelisted);

    /// @notice Custom error for unauthorized whitelist access
    error NotWhitelisted(address caller);

    /// @notice Custom error for invalid implementation address
    error ImplementationAddressWrong(address addr);

    /// @param _implementation Address of the SportsBet logic contract
    constructor(address _implementation)
        Ownable(msg.sender)
        ImplementationAddressCheck(_implementation)
    {
        implementation = _implementation;
    }

    /// @notice Modifier to restrict functions to only whitelisted addresses
    modifier onlyWhitelisted() {
        if (!whitelist[msg.sender]) revert NotWhitelisted(msg.sender);
        _;
    }

    /// @notice Modifier to ensure a non-zero implementation address
    /// @param _impl Address to validate
    modifier ImplementationAddressCheck(address _impl) {
        if (_impl == address(0)) revert ImplementationAddressWrong(_impl);
        _;
    }

    /// @notice Update the SportsBet logic contract for future proxies
    /// @param _newImpl Address of the new logic contract
    function setImplementation(address _newImpl)
        external
        onlyOwner
        ImplementationAddressCheck(_newImpl)
    {
        implementation = _newImpl;
        emit ImplementationUpdated(_newImpl);
    }

    /// @notice Add or remove an address from the factory whitelist
    /// @param user Address to update
    /// @param allowed Whether the address should be whitelisted
    function setWhitelist(address user, bool allowed) external onlyOwner {
        whitelist[user] = allowed;
        emit WhitelistUpdated(user, allowed);
    }

    /// @notice Deploy a new SportsBet proxy and initialize it
    /// @param eventId Unique identifier for the sports event
    /// @param eventName Description or name of the event
    /// @param oddsHome Odds ×100 for the home team
    /// @param oddsAway Odds ×100 for the away team
    /// @param oddsDraw Odds ×100 for a draw
    /// @return proxy Address of the newly deployed proxy
    function createSportsBet(
        uint256 eventId,
        string calldata eventName,
        uint256 oddsHome,
        uint256 oddsAway,
        uint256 oddsDraw
    ) external onlyWhitelisted returns (address proxy) {
        bytes memory initData = abi.encodeWithSelector(
            SportsBet.initialize.selector,
            eventId,
            eventName,
            oddsHome,
            oddsAway,
            oddsDraw,
            msg.sender
        );

        proxy = address(new ERC1967Proxy(implementation, initData));
        allBets.push(proxy);
        emit SportsBetCreated(proxy, eventId);
    }

    /// @notice Retrieve all deployed SportsBet proxies
    /// @return Array of proxy addresses
    function getAllBets() external view returns (address[] memory) {
        return allBets;
    }
}
