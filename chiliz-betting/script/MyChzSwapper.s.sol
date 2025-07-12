// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../src/MyChzSwapper.sol";
import {Script, console} from "forge-std/Script.sol";

// Separate script for testnet deployment
contract DeployMyChzSwapperTestnet is Script {
    // Add testnet addresses here when available
    // For now using mainnet addresses as placeholder
    address constant WCHZ_ADDRESS = 0x678c34581db0a7808d0aC669d7025f1408C9a3C6;
    address constant KAYEN_ROUTER_ADDRESS = 0xb82b0e988a1FcA39602c5079382D360C870b44c8;
    
    function run() external {
        uint256 deployerPrivateKey =  vm.envUint("SPICY_TESTNET_PK"); // Replace with your actual private key
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("Deploying MyChzSwapper on TESTNET with deployer:", deployer);
        console.log("Deployer balance:", deployer.balance);
        
        vm.startBroadcast(deployerPrivateKey);
        
        MyChzSwapper swapper = new MyChzSwapper();
        
        vm.stopBroadcast();
        
        console.log("MyChzSwapper deployed on testnet at:", address(swapper));
        
        // Save testnet deployment info
        string memory deploymentInfo = string.concat(
            "{\n",
            '  "contract": "MyChzSwapper",\n',
            '  "address": "', vm.toString(address(swapper)), '",\n',
            '  "deployer": "', vm.toString(deployer), '",\n',
            '  "network": "testnet",\n',
            '  "timestamp": ', vm.toString(block.timestamp), '\n',
            "}"
        );
        
        vm.writeFile("deployments/MyChzSwapper-testnet.json", deploymentInfo);
        console.log("Testnet deployment info saved to deployments/MyChzSwapper-testnet.json");
    }
}
