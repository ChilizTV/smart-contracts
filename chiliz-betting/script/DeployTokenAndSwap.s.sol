// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../src/MockWrappedChz.sol";
import {Script, console} from "forge-std/Script.sol";
import "../src/MyChzSwapper.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeployMockWrappedChzAndSwap is Script {
    // Token parameters
    string constant TOKEN_NAME = "Wrapped CHZ";
    string constant TOKEN_SYMBOL = "WCHZ";
    uint256 constant INITIAL_SUPPLY = 1000000 * 10 ** 18; // 1M tokens

    // Add testnet addresses here when available
    // For now using mainnet addresses as placeholder
    address constant WCHZ_ADDRESS = 0x678c34581db0a7808d0aC669d7025f1408C9a3C6;
    address constant KAYEN_ROUTER_ADDRESS = 0xb82b0e988a1FcA39602c5079382D360C870b44c8;

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
        MockWrappedChz mockWChz = new MockWrappedChz(TOKEN_NAME, TOKEN_SYMBOL); // NOT_USED FOR TESTING

        // Mint initial supply to deployer
        mockWChz.mint(deployer, INITIAL_SUPPLY);
        MyChzSwapper swapper = new MyChzSwapper();

        vm.stopBroadcast();

        console.log("MyChzSwapper deployed on testnet at:", address(swapper));
        console.log("=== Deployment Complete ===");
        console.log("MockWrappedChz deployed at:", address(mockWChz));
        console.log("Total supply:", mockWChz.totalSupply());
        console.log("Deployer balance:", mockWChz.balanceOf(deployer));
        console.log("Token name:", mockWChz.name());
        console.log("Token symbol:", mockWChz.symbol());
        console.log("Decimals:", mockWChz.decimals());

        // Save testnet deployment info
        string memory deploymentInfo = string.concat(
            "{\n",
            '  "contract": "MyChzSwapper",\n',
            '  "address": "',
            vm.toString(address(swapper)),
            '",\n',
            '  "deployer": "',
            vm.toString(deployer),
            '",\n',
            '  "network": "testnet",\n',
            '  "timestamp": ',
            vm.toString(block.timestamp),
            "\n",
            "}"
        );

        console.log(deploymentInfo);
    }
}
