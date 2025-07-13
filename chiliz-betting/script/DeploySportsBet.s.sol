// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/SportsBet.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeploySportsBet is Script {
    function run() external {
        // Chargement de la clé privée depuis l'environnement
        uint256 deployerKey = vm.envUint("SPICY_TESTNET_PK");
        vm.startBroadcast(deployerKey);

        // 1) Déploiement de l'implémentation SportsBet
        SportsBet logic = new SportsBet();

        // 2) Encodage des données d'initialisation (initialize)
        //    Exemple : eventId = 1, eventName = "MatchA vs MatchB", cotes Home=150, Away=200, Draw=180
        bytes memory initData = abi.encodeWithSelector(
            SportsBet.initialize.selector,
            1,
            "PSG vs Inter Milan",
            150,
            200,
            180,
            msg.sender      // ownership du contrat
        );

        // 3) Déploiement du proxy ERC1967
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(logic),
            initData
        );

        vm.stopBroadcast();

        // Affichage des adresses (console disponible via forge script -vvvv)
        console.log("Logic contract deployed at:", address(logic));
        console.log("Proxy deployed at:", address(proxy));
    }
}
