// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "./SportsBet.sol";

/// @title  Factory de déploiement de SportsBet UUPS proxies
/// @notice Déploie un nouveau proxy ERC-1967 pointant vers l’implémentation SportsBet
contract SportsBetFactory is Ownable {

    /// @notice Adresse de l’implémentation du logic contract SportsBet
    address public implementation;

    /// @notice Tous les proxies créés
    address[] public allBets;

    event ImplementationUpdated(address indexed newImplementation);
    event SportsBetCreated(address indexed proxy, uint256 indexed eventId);

    error ImplementationAddressWrong(address addr);
    /// @param _implementation adresse du logic contract (SportsBet déployé via `forge create`)

    constructor(address _implementation) Ownable(msg.sender) ImplementationAddressCheck(_implementation) {
        implementation = _implementation;
    }

    modifier ImplementationAddressCheck(address _impl) {
        if (_impl == address(0)) revert ImplementationAddressWrong(address(0));
        _;
    }
    /// @notice Met à jour l’implémentation logic pour les futurs déploiements
    /// @param _newImpl nouvelle adresse logic

    function setImplementation(address _newImpl) external onlyOwner ImplementationAddressCheck(_newImpl) {
        implementation = _newImpl;
        emit ImplementationUpdated(_newImpl);
    }

    /// @notice Crée un nouveau pari sportif upgradeable
    /// @param eventId     identifiant de l’événement
    /// @param eventName   nom ou description de l’événement
    /// @param oddsHome    cote *100 pour l’équipe à domicile
    /// @param oddsAway    cote *100 pour l’équipe à l’extérieur
    /// @param oddsDraw    cote *100 pour le match nul
    /// @return proxy      adresse du nouveau proxy SportBet
    function createSportsBet(
        uint256 eventId,
        string calldata eventName,
        uint256 oddsHome,
        uint256 oddsAway,
        uint256 oddsDraw
    ) external returns (address proxy) {
        // Prépare les données d'appel à initialize(...)
        bytes memory initData = abi.encodeWithSelector(
            SportsBet.initialize.selector, eventId, eventName, oddsHome, oddsAway, oddsDraw, msg.sender
        );

        // Déploie le proxy ERC-1967 pointant vers `implementation`
        proxy = address(new ERC1967Proxy(implementation, initData));

        // Stocke et émet l'événement
        allBets.push(proxy);
        emit SportsBetCreated(proxy, eventId);
    }

    /// @notice Retourne la liste complète des proxies déployés
    function getAllBets() external view returns (address[] memory) {
        return allBets;
    }
}
