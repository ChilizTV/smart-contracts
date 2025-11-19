// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

// Import streaming system contracts
import {StreamWallet} from "../src/streamer/StreamWallet.sol";
import {StreamWalletFactory} from "../src/streamer/StreamWalletFactory.sol";
import {StreamBeaconRegistry} from "../src/streamer/StreamBeaconRegistry.sol";

/**
 * @title DeployStreaming
 * @author ChilizTV
 * @notice Deployment script for the Streaming System (Beacon Proxy)
 * @dev Deploys StreamWallet implementation, StreamBeaconRegistry, and StreamWalletFactory
 * 
 * ARCHITECTURE:
 * ============
 * - StreamWallet: Implementation with subscription & donation logic (native CHZ)
 * - StreamBeaconRegistry: Manages UpgradeableBeacon for atomic upgrades
 * - StreamWalletFactory: Factory to deploy BeaconProxy instances
 * - Each streamer gets their own BeaconProxy wallet
 * 
 * STREAMING FLOW:
 * ==============
 * 1. Factory creates a StreamWallet proxy for a streamer
 * 2. Users subscribe/donate with native CHZ
 * 3. Platform fee split to treasury
 * 4. Streamer receives net amount
 * 5. Streamer can withdraw anytime
 * 
 * USAGE:
 * =====
 * Set environment variables:
 *   export PRIVATE_KEY=0x...           # Deployer private key
 *   export RPC_URL=https://...         # Network RPC endpoint
 *   export SAFE_ADDRESS=0x...          # Safe multisig (treasury + registry owner)
 * 
 * Run:
 *   forge script script/DeployStreaming.s.sol --rpc-url $RPC_URL --broadcast --verify
 */
contract DeployStreaming is Script {
    
    // ============================================================================
    // DEPLOYED CONTRACTS
    // ============================================================================
    
    StreamWallet public streamWalletImpl;
    StreamBeaconRegistry public registry;
    StreamWalletFactory public factory;
    
    address public deployer;
    address public treasury; // Safe multisig
    
    
    // ============================================================================
    // MAIN DEPLOYMENT
    // ============================================================================
    
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
        
        _printHeader();
        _deployImplementation();
        _deployRegistry();
        _deployFactory();
        _transferOwnership();
        _printSummary();
        
        vm.stopBroadcast();
    }
    
    
    // ============================================================================
    // DEPLOYMENT STEPS
    // ============================================================================
    
    /**
     * @notice STEP 1: Deploy StreamWallet implementation
     */
    function _deployImplementation() internal {
        console.log("STEP 1: Deploying StreamWallet Implementation");
        console.log("---------------------------------------------");
        
        streamWalletImpl = new StreamWallet();
        console.log("StreamWallet Implementation:", address(streamWalletImpl));
        console.log("  Type: Beacon Proxy Upgradeable");
        console.log("  Currency: Native CHZ");
        console.log("");
    }
    
    /**
     * @notice STEP 2: Deploy StreamBeaconRegistry
     */
    function _deployRegistry() internal {
        console.log("STEP 2: Deploying StreamBeaconRegistry");
        console.log("--------------------------------------");
        
        registry = new StreamBeaconRegistry(deployer);
        registry.setImplementation(address(streamWalletImpl));
        console.log("StreamBeaconRegistry:", address(registry));
        console.log("  Temporary Owner:", deployer);
        console.log("  Beacon:", registry.getBeacon());
        console.log("");
    }
    
    /**
     * @notice STEP 3: Deploy StreamWalletFactory
     */
    function _deployFactory() internal {
        console.log("STEP 3: Deploying StreamWalletFactory");
        console.log("-------------------------------------");
        
        factory = new StreamWalletFactory(
            deployer,
            address(registry),
            treasury,
            500  // 5% platform fee
        );
        console.log("StreamWalletFactory:", address(factory));
        console.log("  Owner:", deployer);
        console.log("  Registry:", address(registry));
        console.log("  Treasury:", treasury);
        console.log("  Platform Fee: 5%");
        console.log("");
    }
    
    /**
     * @notice STEP 4: Transfer registry ownership to Safe
     */
    function _transferOwnership() internal {
        console.log("STEP 4: Transferring Ownership to Safe");
        console.log("---------------------------------------");
        
        registry.transferOwnership(treasury);
        console.log("StreamBeaconRegistry -> Safe:", treasury);
        console.log("");
    }
    
    
    // ============================================================================
    // HELPER FUNCTIONS
    // ============================================================================
    
    function _printHeader() internal view {
        console.log("=====================================");
        console.log("CHILIZ-TV STREAMING SYSTEM DEPLOYMENT");
        console.log("=====================================");
        console.log("");
        console.log("Deployer:", deployer);
        console.log("Safe/Treasury:", treasury);
        console.log("");
        console.log("=====================================");
        console.log("");
    }
    
    function _printSummary() internal view {
        console.log("=====================================");
        console.log("DEPLOYMENT COMPLETE!");
        console.log("=====================================");
        console.log("");
        
        console.log("DEPLOYED CONTRACTS:");
        console.log("------------------");
        console.log("StreamWallet Implementation:", address(streamWalletImpl));
        console.log("StreamBeaconRegistry:", address(registry));
        console.log("  Owner:", treasury);
        console.log("  Beacon:", registry.getBeacon());
        console.log("StreamWalletFactory:", address(factory));
        console.log("");
        
        console.log("CREATE A STREAM WALLET:");
        console.log("----------------------");
        console.log("cast send", address(factory));
        console.log("  'createStreamWallet(address)'");
        console.log("  <STREAMER_ADDRESS>");
        console.log("");
        
        console.log("SUBSCRIBE TO STREAM:");
        console.log("-------------------");
        console.log("cast send", address(factory), "--value 1ether");
        console.log("  'subscribeToStream(address)'");
        console.log("  <STREAMER_ADDRESS>");
        console.log("");
    }
}
