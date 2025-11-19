// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

// Import betting system
import {BettingMatch} from "../src/betting/BettingMatch.sol";
import {BettingMatchFactory} from "../src/betting/BettingMatchFactory.sol";

// Import streaming system
import {StreamWallet} from "../src/streamer/StreamWallet.sol";
import {StreamWalletFactory} from "../src/streamer/StreamWalletFactory.sol";
import {StreamBeaconRegistry} from "../src/streamer/StreamBeaconRegistry.sol";

/**
 * @title DeployAll
 * @author ChilizTV
 * @notice Complete deployment script for both Betting and Streaming systems
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
    BettingMatch public bettingMatchImpl;
    BettingMatchFactory public bettingFactory;
    
    // Streaming contracts
    StreamWallet public streamWalletImpl;
    StreamBeaconRegistry public streamRegistry;
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
        bettingMatchImpl = new BettingMatch();
        console.log("BettingMatch Implementation:", address(bettingMatchImpl));
        
        bettingFactory = new BettingMatchFactory(address(bettingMatchImpl));
        console.log("BettingMatchFactory:", address(bettingFactory));
        console.log("");
        
        // Deploy Streaming System
        console.log("STREAMING SYSTEM");
        console.log("================");
        streamWalletImpl = new StreamWallet();
        console.log("StreamWallet Implementation:", address(streamWalletImpl));
        
        streamRegistry = new StreamBeaconRegistry(deployer);
        streamRegistry.setImplementation(address(streamWalletImpl));
        console.log("StreamBeaconRegistry:", address(streamRegistry));
        
        streamFactory = new StreamWalletFactory(
            deployer,
            address(streamRegistry),
            treasury,
            500  // 5% platform fee
        );
        console.log("StreamWalletFactory:", address(streamFactory));
        console.log("");
        
        // Transfer ownership
        console.log("OWNERSHIP TRANSFER");
        console.log("==================");
        streamRegistry.transferOwnership(treasury);
        console.log("StreamBeaconRegistry -> Safe [OK]");
        console.log("");
        
        console.log("=========================================");
        console.log("DEPLOYMENT COMPLETE!");
        console.log("=========================================");
        
        vm.stopBroadcast();
    }
}
