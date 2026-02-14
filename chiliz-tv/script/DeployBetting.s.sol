// forge script script/DeployAll.s.sol:DeployAll \
//   --rpc-url https://spicy-rpc.chiliz.com \
//   --private-key $PRIVATE_KEY \
//   --broadcast \
//   --verify \
//   --verifier blockscout \
//   --verifier-url https://api.routescan.io/v2/network/testnet/evm/88882/etherscan/api \
//   --etherscan-api-key $ETHERSCAN_API_KEY \
//   --with-gas-price 100000000000 \
//   -vvvv// SPDX-License-Identifier: MIT

pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";

// Import betting system factory (implementations deployed internally)
import {BettingMatchFactory} from "../src/betting/BettingMatchFactory.sol";

/**
 * @title DeployBetting
 * @author ChilizTV
 * @notice Deployment script for the UUPS-based Multi-Sport Betting System
 * @dev Deploys FootballMatch and BasketballMatch implementations, plus BettingMatchFactory
 * 
 * ARCHITECTURE:
 * ============
 * - FootballMatch: UUPS upgradeable contract for football betting
 * - BasketballMatch: UUPS upgradeable contract for basketball betting
 * - BettingMatchFactory: Factory to deploy ERC1967 proxies for both sports
 * - Each proxy is an independent match with sport-specific markets
 * 
 * BETTING FLOW:
 * ============
 * 1. Factory creates a new football or basketball match proxy
 * 2. Match owner adds sport-specific markets
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
    
    BettingMatchFactory public factory;
    
    address public deployer;
    
    
    // ============================================================================
    // MAIN DEPLOYMENT
    // ============================================================================
    
    function run() external {
        deployer = msg.sender;
        
        vm.startBroadcast();
        
        _printHeader();
        _deployFactory();
        _printSummary();
        
        vm.stopBroadcast();
    }
    
    
    // ============================================================================
    // DEPLOYMENT STEPS
    // ============================================================================
    
    /**
     * @notice Deploy BettingMatchFactory (deploys implementations internally)
     * @dev Factory creates ERC1967 proxies for both sports
     */
    function _deployFactory() internal {
        console.log("Deploying BettingMatchFactory");
        console.log("------------------------------");
        factory = new BettingMatchFactory();
        console.log("BettingMatchFactory:", address(factory));
        console.log("  Owner:", deployer);
        console.log("  Implementations deployed internally");
        console.log("");
    }
    
    
    // ============================================================================
    // HELPER FUNCTIONS
    // ============================================================================
    
    function _printHeader() internal view {
        console.log("=========================================");
        console.log("CHILIZ-TV MULTI-SPORT BETTING DEPLOYMENT");
        console.log("=========================================");
        console.log("");
        console.log("Deployer:", deployer);
        console.log("");
        console.log("=========================================");
        console.log("");
    }
    
    function _printSummary() internal view {
        console.log("=====================================");
        console.log("DEPLOYMENT COMPLETE!");
        console.log("=====================================");
        console.log("");
        
        console.log("DEPLOYED CONTRACTS:");
        console.log("------------------");
        console.log("BettingMatchFactory:", address(factory));
        console.log("  (Implementations deployed internally)");
        console.log("");
        
        console.log("CREATE A FOOTBALL MATCH:");
        console.log("-----------------------");
        console.log("cast send", address(factory));
        console.log("  'createFootballMatch(string,address)'");
        console.log("  'Barcelona vs Real Madrid'  # Match name");
        console.log("  <OWNER_ADDRESS>             # Match admin");
        console.log("");
        
        console.log("CREATE A BASKETBALL MATCH:");
        console.log("-------------------------");
        console.log("cast send", address(factory));
        console.log("  'createBasketballMatch(string,address)'");
        console.log("  'Lakers vs Celtics'    # Match name");
        console.log("  <OWNER_ADDRESS>        # Match admin");
        console.log("");
        
        console.log("ADD MARKETS TO MATCH:");
        console.log("--------------------");
        console.log("cast send <MATCH_ADDRESS>");
        console.log("  'addMarket(bytes32,uint32)'");
        console.log("  keccak256('WINNER')       # Market type (bytes32)");
        console.log("  20000                     # Odds: 2.0x (20000/10000)");
        console.log("");
        
        console.log("BETTING FLOW:");
        console.log("------------");
        console.log("1. Open market: match.setMarketState(0, MarketState.Open)");
        console.log("2. User bets: match.placeBet{value: 1 ether}(0, 0)");
        console.log("   - marketId: 0 (first market)");
        console.log("   - selection: 0 (Home/Over/Yes/etc.)");
        console.log("   - Odds locked at time of bet (x10000 precision)");
        console.log("3. Owner resolves: match.resolveMarket(0, 0)");
        console.log("   - marketId: 0");
        console.log("   - result: 0 (actual outcome)");
        console.log("4. Winner claims: match.claim(0)");
        console.log("   - Receives bet * lockedOdds / 10000");
        console.log("");
        
        console.log("UPGRADING:");
        console.log("---------");
        console.log("Implementations are immutable in factory.");
        console.log("Each match can be upgraded individually via UUPS:");
        console.log("  1. Deploy new implementation (FootballMatch or BasketballMatch)");
        console.log("  2. Call match.upgradeToAndCall(newImpl, '') as match owner");
        console.log("");
    }
}
