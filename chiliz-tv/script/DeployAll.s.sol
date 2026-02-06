// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";

// Import betting system (factory deploys implementations internally)
import {BettingMatchFactory} from "../src/betting/BettingMatchFactory.sol";

// Import streaming system
import {StreamWalletFactory} from "../src/streamer/StreamWalletFactory.sol";

/**
 * @title DeployAll
 * @author ChilizTV
 * @notice Complete deployment script for both Multi-Sport Betting and Streaming systems
 * 
 * USAGE:
 * =====
 * Set environment variables:
 *   export PRIVATE_KEY=0x...           # Deployer private key
 *   export RPC_URL=https://...         # Network RPC endpoint
 *   export SAFE_ADDRESS=0x...          # Safe multisig (treasury)
 * 
 * Run:
 *   forge script script/DeployAll.s.sol --rpc-url $RPC_URL --broadcast --verify
 */
contract DeployAll is Script {
    
    // Betting contracts
    BettingMatchFactory public bettingFactory;
    
    // Streaming contracts
    StreamWalletFactory public streamFactory;
    
    address public deployer;
    address public treasury;
    
    function run() external {
        deployer = msg.sender;
        
        // Load Safe address
        try vm.envAddress("SAFE_ADDRESS") returns (address addr) {
            treasury = addr;
        } catch {
            console.log("ERROR: SAFE_ADDRESS environment variable not set!");
            revert("SAFE_ADDRESS required");
        }
        
        vm.startBroadcast();
        
        console.log("=========================================");
        console.log("CHILIZ-TV COMPLETE SYSTEM DEPLOYMENT");
        console.log("=========================================");
        console.log("");
        console.log("Deployer:", deployer);
        console.log("Safe/Treasury:", treasury);
        console.log("");
        
        // Deploy Betting System
        console.log("BETTING SYSTEM");
        console.log("==============");
        bettingFactory = new BettingMatchFactory();
        console.log("BettingMatchFactory:", address(bettingFactory));
        console.log("  (Implementations deployed internally)");
        console.log("");
        
        // Deploy Streaming System
        console.log("STREAMING SYSTEM");
        console.log("================");
        streamFactory = new StreamWalletFactory(
            deployer,
            treasury,
            500  // 5% platform fee
        );
        console.log("StreamWalletFactory:", address(streamFactory));
        console.log("  (Implementation deployed internally)");
        console.log("");
        
        // Transfer ownership
        console.log("OWNERSHIP TRANSFER");
        console.log("==================");
        streamFactory.transferOwnership(treasury);
        console.log("StreamWalletFactory -> Safe [OK]");
        console.log("");
        
        console.log("=========================================");
        console.log("DEPLOYMENT COMPLETE!");
        console.log("=========================================");
        
        vm.stopBroadcast();
    }
}
