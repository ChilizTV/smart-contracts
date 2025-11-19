// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

// Import betting system contracts
import {BettingMatch} from "../src/betting/BettingMatch.sol";
import {BettingMatchFactory} from "../src/betting/BettingMatchFactory.sol";

/**
 * @title DeployBetting
 * @author ChilizTV
 * @notice Deployment script for the UUPS-based Betting Match System
 * @dev Deploys BettingMatch implementation and BettingMatchFactory
 * 
 * ARCHITECTURE:
 * ============
 * - BettingMatch: UUPS upgradeable match contract with multiple markets
 * - BettingMatchFactory: Factory to deploy ERC1967 proxies of BettingMatch
 * - Each proxy is an independent match with its own markets and bets
 * 
 * BETTING FLOW:
 * ============
 * 1. Factory creates a new match proxy
 * 2. Match owner adds markets (Winner, GoalsCount, FirstScorer, etc.)
 * 3. Users bet CHZ on market selections
 * 4. Match owner resolves markets with actual results
 * 5. Winners claim payouts based on odds
 * 
 * USAGE:
 * =====
 * Set environment variables:
 *   export PRIVATE_KEY=0x...           # Deployer private key
 *   export RPC_URL=https://...         # Network RPC endpoint
 * 
 * Run:
 *   forge script script/DeployBetting.s.sol --rpc-url $RPC_URL --broadcast --verify
 */
contract DeployBetting is Script {
    
    // ============================================================================
    // DEPLOYED CONTRACTS
    // ============================================================================
    
    BettingMatch public bettingMatchImpl;
    BettingMatchFactory public factory;
    
    address public deployer;
    
    
    // ============================================================================
    // MAIN DEPLOYMENT
    // ============================================================================
    
    function run() external {
        deployer = msg.sender;
        
        vm.startBroadcast();
        
        _printHeader();
        _deployImplementation();
        _deployFactory();
        _printSummary();
        
        vm.stopBroadcast();
    }
    
    
    // ============================================================================
    // DEPLOYMENT STEPS
    // ============================================================================
    
    /**
     * @notice STEP 1: Deploy BettingMatch implementation
     * @dev This is the logic contract for all matches
     */
    function _deployImplementation() internal {
        console.log("STEP 1: Deploying BettingMatch Implementation");
        console.log("---------------------------------------------");
        
        bettingMatchImpl = new BettingMatch();
        console.log("BettingMatch Implementation:", address(bettingMatchImpl));
        console.log("  Type: UUPS Upgradeable");
        console.log("  Markets: Winner, GoalsCount, FirstScorer, Custom");
        console.log("  Betting: Parimutuel with fixed odds");
        console.log("  Currency: Native CHZ");
        console.log("");
    }
    
    /**
     * @notice STEP 2: Deploy BettingMatchFactory
     * @dev Factory creates ERC1967 proxies of BettingMatch
     */
    function _deployFactory() internal {
        console.log("STEP 2: Deploying BettingMatchFactory");
        console.log("-------------------------------------");
        
        factory = new BettingMatchFactory(address(bettingMatchImpl));
        console.log("BettingMatchFactory:", address(factory));
        console.log("  Owner:", deployer);
        console.log("  Implementation:", address(bettingMatchImpl));
        console.log("");
    }
    
    
    // ============================================================================
    // HELPER FUNCTIONS
    // ============================================================================
    
    function _printHeader() internal view {
        console.log("=====================================");
        console.log("CHILIZ-TV BETTING SYSTEM DEPLOYMENT");
        console.log("=====================================");
        console.log("");
        console.log("Deployer:", deployer);
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
        console.log("BettingMatch Implementation:", address(bettingMatchImpl));
        console.log("BettingMatchFactory:", address(factory));
        console.log("");
        
        console.log("CREATE A MATCH:");
        console.log("---------------");
        console.log("cast send", address(factory));
        console.log("  'createMatch(string,address)'");
        console.log("  'Man United vs Chelsea'  # Match name");
        console.log("  <OWNER_ADDRESS>           # Match admin");
        console.log("");
        
        console.log("ADD MARKETS TO MATCH:");
        console.log("--------------------");
        console.log("cast send <MATCH_ADDRESS>");
        console.log("  'addMarket(uint8,uint256)'");
        console.log("  0                         # MarketType.Winner");
        console.log("  150                       # Odds: 1.5x (150/100)");
        console.log("");
        
        console.log("BETTING FLOW:");
        console.log("------------");
        console.log("1. User bets: match.placeBet{value: 1 ether}(0, 1)");
        console.log("   - marketId: 0 (Winner market)");
        console.log("   - selection: 1 (their pick)");
        console.log("2. Owner resolves: match.resolveMarket(0, 1)");
        console.log("   - marketId: 0");
        console.log("   - result: 1 (actual outcome)");
        console.log("3. Winner claims: match.claim(0)");
        console.log("   - Receives bet * odds / 100");
        console.log("");
        
        console.log("UPGRADING (Factory Owner):");
        console.log("--------------------------");
        console.log("1. Deploy new BettingMatch implementation");
        console.log("2. factory.setImplementation(newImpl)");
        console.log("3. Future matches use new implementation");
        console.log("4. Existing matches can be upgraded individually");
        console.log("");
    }
}
