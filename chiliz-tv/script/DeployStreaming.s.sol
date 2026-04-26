// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

// Import streaming system contracts
import {StreamWalletFactory} from "../src/streamer/StreamWalletFactory.sol";

/**
 * @title DeployStreaming
 * @author ChilizTV
 * @notice Deployment script for the Streaming System (UUPS Proxy)
 * @dev Deploys StreamWalletFactory which creates ERC1967 UUPS proxies
 * 
 * ARCHITECTURE:
 * ============
 * - StreamWallet: UUPS upgradeable implementation with subscription & donation logic
 * - StreamWalletFactory: Factory that deploys ERC1967 proxy instances
 * - Each streamer gets their own UUPS proxy wallet
 * - Each wallet upgrades individually (streamer controls their own upgrades)
 * 
 * STREAMING FLOW:
 * ==============
 * 1. Factory creates a StreamWallet UUPS proxy for a streamer
 * 2. Users subscribe/donate with native CHZ
 * 3. Platform fee split to treasury
 * 4. Streamer receives net amount
 * 5. Streamer can withdraw anytime
 * 6. Streamer can upgrade their wallet via UUPS
 * 
 * USAGE:
 * =====
 * Set environment variables:
 *   export PRIVATE_KEY=0x...           # Deployer private key
 *   export RPC_URL=https://...         # Network RPC endpoint
 *   export SAFE_ADDRESS=0x...          # Safe multisig (treasury)
 *   export KAYEN_ROUTER=0x...          # Kayen DEX MasterRouterV2
 *   export USDC_ADDRESS=0x...          # USDC token
 *
 * Run:
 *   forge script script/DeployStreaming.s.sol --rpc-url $RPC_URL --broadcast --verify
 */
contract DeployStreaming is Script {
    
    // ============================================================================
    // DEPLOYED CONTRACTS
    // ============================================================================
    
    StreamWalletFactory public factory;

    address public deployer;
    address public treasury;    // Safe multisig
    address public kayenRouter; // Kayen DEX MasterRouterV2
    address public usdc;        // USDC token


    // ============================================================================
    // MAIN DEPLOYMENT
    // ============================================================================

    function run() external {
        deployer = msg.sender;

        // All three are required up-front so the factory ships in a usable state.
        // The previous version passed address(0) for kayenRouter/usdc and relied on
        // post-deploy setter txs that were easy to forget — every subscribe/donate
        // call would revert until they ran. Fail fast here instead.
        treasury    = vm.envAddress("SAFE_ADDRESS");
        kayenRouter = vm.envAddress("KAYEN_ROUTER");
        usdc        = vm.envAddress("USDC_ADDRESS");

        require(treasury    != address(0), "SAFE_ADDRESS required");
        require(kayenRouter != address(0), "KAYEN_ROUTER required");
        require(usdc        != address(0), "USDC_ADDRESS required");

        vm.startBroadcast();

        _printHeader();
        _deployFactory();
        // NOTE: Ownership transfer skipped during deployment.
        // After all post-deployment setup (setSwapRouter), transfer ownership to
        // the Safe manually:  factory.transferOwnership(SAFE_ADDRESS)
        _printSummary();

        vm.stopBroadcast();
    }
    
    
    // ============================================================================
    // DEPLOYMENT STEPS
    // ============================================================================
    
    /**
     * @notice Deploy StreamWalletFactory (deploys implementation internally)
     * @dev Factory creates ERC1967 UUPS proxies for streamers
     */
    function _deployFactory() internal {
        console.log("Deploying StreamWalletFactory");
        console.log("-----------------------------");

        factory = new StreamWalletFactory(
            deployer,
            treasury,
            500,         // 5% platform fee
            kayenRouter, // Kayen DEX router (required)
            usdc         // USDC token       (required)
        );
        console.log("StreamWalletFactory:", address(factory));
        console.log("  Owner:", deployer);
        console.log("  Implementation: deployed internally");
        console.log("  Treasury:", treasury);
        console.log("  Kayen Router:", kayenRouter);
        console.log("  USDC:", usdc);
        console.log("  Platform Fee: 5%");
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
        console.log("Kayen Router:", kayenRouter);
        console.log("USDC:", usdc);
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
        console.log("StreamWalletFactory:", address(factory));
        console.log("  (Implementation deployed internally)");
        console.log("  Owner:", deployer, "(transfer to Safe after setSwapRouter wiring)");
        console.log("");
        
        console.log("CREATE A STREAM WALLET:");
        console.log("----------------------");
        console.log("cast send", address(factory));
        console.log("  'deployWalletFor(address)'");
        console.log("  <STREAMER_ADDRESS>");
        console.log("");
        
        console.log("SUBSCRIBE TO STREAM:");
        console.log("-------------------");
        console.log("cast send", address(factory), "--value 1ether");
        console.log("  'subscribeToStream(address,uint256,uint256,address)'");
        console.log("  <STREAMER_ADDRESS> <DURATION_SECONDS> <AMOUNT> <TOKEN_ADDRESS>");
        console.log("");
    }
}
