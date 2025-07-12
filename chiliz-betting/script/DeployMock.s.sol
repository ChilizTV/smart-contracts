// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../src/MockWrappedChz.sol";
import {Script, console} from "forge-std/Script.sol";

contract DeployMockWrappedChz is Script {
    // Token parameters
    string constant TOKEN_NAME = "Wrapped CHZ";
    string constant TOKEN_SYMBOL = "WCHZ";
    uint256 constant INITIAL_SUPPLY = 1000000 * 10**18; // 1M tokens
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("SPICY_TESTNET_PK");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("=== Deploying MockWrappedChz ===");
        console.log("Deployer address:", deployer);
        console.log("Deployer balance:", deployer.balance);
        console.log("Token name:", TOKEN_NAME);
        console.log("Token symbol:", TOKEN_SYMBOL);
        console.log("Initial supply:", INITIAL_SUPPLY);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy the MockWrappedChz contract
        MockWrappedChz mockWChz = new MockWrappedChz(TOKEN_NAME, TOKEN_SYMBOL);
        
        // Mint initial supply to deployer
        mockWChz.mint(deployer, INITIAL_SUPPLY);
        
        vm.stopBroadcast();
        
        console.log("=== Deployment Complete ===");
        console.log("MockWrappedChz deployed at:", address(mockWChz));
        console.log("Total supply:", mockWChz.totalSupply());
        console.log("Deployer balance:", mockWChz.balanceOf(deployer));
        console.log("Token name:", mockWChz.name());
        console.log("Token symbol:", mockWChz.symbol());
        console.log("Decimals:", mockWChz.decimals());
        
        // Save deployment info
        string memory deploymentInfo = string.concat(
            "{\n",
            '  "contract": "MockWrappedChz",\n',
            '  "address": "', vm.toString(address(mockWChz)), '",\n',
            '  "deployer": "', vm.toString(deployer), '",\n',
            '  "name": "', TOKEN_NAME, '",\n',
            '  "symbol": "', TOKEN_SYMBOL, '",\n',
            '  "decimals": ', vm.toString(mockWChz.decimals()), ',\n',
            '  "totalSupply": "', vm.toString(mockWChz.totalSupply()), '",\n',
            '  "timestamp": ', vm.toString(block.timestamp), '\n',
            "}"
        );
        
        vm.writeFile("deployments/MockWrappedChz.json", deploymentInfo);
        console.log("Deployment info saved to deployments/MockWrappedChz.json");
        
        // Create verification command
        console.log("\n=== VERIFICATION COMMAND ===");
        console.log("forge verify-contract");
        console.log("  --chain-id 88888");
        console.log("  --watch");
        console.log(string.concat("  ", vm.toString(address(mockWChz))));
        console.log("  src/MockWrappedChz.sol:MockWrappedChz");
        console.log(string.concat("  --constructor-args $(cast abi-encode \"constructor(string,string)\" \"", TOKEN_NAME, "\" \"", TOKEN_SYMBOL, "\")"));
        console.log("  --etherscan-api-key YOUR_API_KEY");
    }
}

// Testnet deployment script with hardcoded private key
contract DeployMockWrappedChzTestnet is Script {
    string constant TOKEN_NAME = "Wrapped CHZ";
    string constant TOKEN_SYMBOL = "WCHZ";
    uint256 constant INITIAL_SUPPLY = 1000000 * 10**18; // 1M tokens
    
    function run() external {
        uint256 deployerPrivateKey =  vm.envUint("SPICY_TESTNET_PK"); // Replace with your actual private key
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("=== Deploying MockWrappedChz on TESTNET ===");
        console.log("Deployer address:", deployer);
        console.log("Deployer balance:", deployer.balance);
        
        vm.startBroadcast(deployerPrivateKey);
        
        MockWrappedChz mockWChz = new MockWrappedChz(TOKEN_NAME, TOKEN_SYMBOL);
        
        // Mint initial supply to deployer
        mockWChz.mint(deployer, INITIAL_SUPPLY);
        
        // Mint some tokens to common test addresses for testing
        address testUser1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
        address testUser2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
        
        mockWChz.mint(testUser1, 10000 * 10**18); // 10K tokens
        mockWChz.mint(testUser2, 10000 * 10**18); // 10K tokens
        
        vm.stopBroadcast();
        
        console.log("=== Testnet Deployment Complete ===");
        console.log("MockWrappedChz deployed at:", address(mockWChz));
        console.log("Total supply:", mockWChz.totalSupply());
        console.log("Deployer balance:", mockWChz.balanceOf(deployer));
        console.log("TestUser1 balance:", mockWChz.balanceOf(testUser1));
        console.log("TestUser2 balance:", mockWChz.balanceOf(testUser2));
        
        // Save testnet deployment info
        string memory deploymentInfo = string.concat(
            "{\n",
            '  "contract": "MockWrappedChz",\n',
            '  "address": "', vm.toString(address(mockWChz)), '",\n',
            '  "deployer": "', vm.toString(deployer), '",\n',
            '  "network": "testnet",\n',
            '  "name": "', TOKEN_NAME, '",\n',
            '  "symbol": "', TOKEN_SYMBOL, '",\n',
            '  "totalSupply": "', vm.toString(mockWChz.totalSupply()), '",\n',
            '  "testUsers": {\n',
            '    "user1": "', vm.toString(testUser1), '",\n',
            '    "user2": "', vm.toString(testUser2), '"\n',
            '  },\n',
            '  "timestamp": ', vm.toString(block.timestamp), '\n',
            "}"
        );
        
        vm.writeFile("deployments/MockWrappedChz-testnet.json", deploymentInfo);
        console.log("Testnet deployment info saved to deployments/MockWrappedChz-testnet.json");
    }
}

// Script to mint additional tokens after deployment
// contract MintMockTokens is Script {
//     address constant MOCK_WCHZ_ADDRESS = 0x123456789; // Replace with deployed address
    
//     function run(address target) external {
//         uint256 deployerPrivateKey =  vm.envUint("SPICY_TESTNET_PK"); // Replace with your actual private key
//         address deployer = vm.addr(deployerPrivateKey);
        
//         console.log("=== Minting Additional Mock Tokens ===");
//         console.log("MockWrappedChz address:", MOCK_WCHZ_ADDRESS);
        
//         MockWrappedChz mockWChz = MockWrappedChz(MOCK_WCHZ_ADDRESS);
        
//         vm.startBroadcast(deployerPrivateKey);
        
//         // Mint tokens to specific addresses if needed
//         mockWChz.mint(target, 50000 * 10**18);

//     }
// }