// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../src/MyChzSwapper.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Script, console} from "forge-std/Script.sol";

contract InteractWithMyChzSwapper is Script {
    // Contract addresses
    address constant SWAPPER_ADDRESS = 0xB5A4Db33256782398D6bd42C49c42819a4b9953D; // Replace with your deployed swapper address
    address constant WCHZ_ADDRESS = 0x678c34581db0a7808d0aC669d7025f1408C9a3C6;
    
    // Example Fan Token addresses (replace with actual ones)
    address constant FAN_TOKEN_EXAMPLE = 0xb0Fa395a3386800658B9617F90e834E2CeC76Dd3; // $PSG Testnet
    
    // User private key for interaction
    uint256 constant USER_PRIVATE_KEY =  vm.envUint("SPICY_TESTNET_PK"); // Replace with actual key
    
    function run() external {
        address user = vm.addr(USER_PRIVATE_KEY);
        
        console.log("=== MyChzSwapper Interaction Script ===");
        console.log("User address:", user);
        console.log("Swapper address:", SWAPPER_ADDRESS);
        console.log("User CHZ balance:", user.balance);
        
        // Initialize contracts
        MyChzSwapper swapper = MyChzSwapper(SWAPPER_ADDRESS);
        IERC20 wChz = IERC20(WCHZ_ADDRESS);
        IERC20 fanToken = IERC20(FAN_TOKEN_EXAMPLE);
        
        // Check initial balances
        console.log("User wCHZ balance:", wChz.balanceOf(user));
        console.log("User FanToken balance:", fanToken.balanceOf(user));
        
        // Start broadcasting transactions
        vm.startBroadcast(USER_PRIVATE_KEY);
        
        wChz.mint(user, 1000 * 10**18);

        // Example interaction: Swap 1 wCHZ for Fan Token
        swapChzForFan(100, 1, [WCHZ_ADDRESS, FAN_TOKEN_EXAMPLE]);
        
        vm.stopBroadcast();
        
        // Check final balances
        console.log("=== Final Balances ===");
        console.log("User wCHZ balance:", wChz.bal

    }
}