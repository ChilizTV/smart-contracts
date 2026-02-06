// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import {BettingMatchFactory} from "../src/betting/BettingMatchFactory.sol";
import {FootballMatch} from "../src/betting/FootballMatch.sol";

/**
 * @title SetupFootballMatch
 * @author ChilizTV
 * @notice Complete script to create a football match, add markets, and open them for betting
 * 
 * USAGE:
 * ======
 * 1. Set environment variables:
 *    export PRIVATE_KEY=0x...
 *    export FACTORY_ADDRESS=0x...
 * 
 * 2. Run the script:
 *    forge script script/SetupFootballMatch.s.sol --rpc-url https://base-sepolia.drpc.org --broadcast -vvvv
 * 
 * 3. After execution, users can bet on the created match!
 * 
 * ODDS PRECISION:
 * ===============
 * Odds use x10000 precision (4 decimal places)
 *   - 1.50x = 15000
 *   - 2.00x = 20000
 *   - 2.18x = 21800
 *   - 3.50x = 35000
 * 
 * SELECTIONS:
 * ===========
 * WINNER market: 0=Home, 1=Draw, 2=Away
 * GOALS_TOTAL market: 0=Under, 1=Over
 * BOTH_SCORE market: 0=No, 1=Yes
 */
contract SetupFootballMatch is Script {
    
    // ============================================================================
    // CONFIGURATION - MODIFY THESE VALUES
    // ============================================================================
    
    // Match details
    string constant MATCH_NAME = "Barcelona vs Real Madrid - La Liga";
    
    // Market odds (x10000 precision)
    uint32 constant ODDS_HOME_WIN = 22000;     // 2.20x
    uint32 constant ODDS_DRAW = 33000;         // 3.30x  
    uint32 constant ODDS_AWAY_WIN = 28000;     // 2.80x
    uint32 constant ODDS_OVER_25 = 18500;      // 1.85x
    uint32 constant ODDS_UNDER_25 = 19500;     // 1.95x
    uint32 constant ODDS_BTTS_YES = 17000;     // 1.70x
    uint32 constant ODDS_BTTS_NO = 21000;      // 2.10x
    
    // Market type hashes (must match FootballMatch constants)
    bytes32 constant MARKET_WINNER = keccak256("WINNER");
    bytes32 constant MARKET_GOALS_TOTAL = keccak256("GOALS_TOTAL");
    bytes32 constant MARKET_BOTH_SCORE = keccak256("BOTH_SCORE");
    
    // ============================================================================
    // STATE
    // ============================================================================
    
    BettingMatchFactory public factory;
    FootballMatch public match_;
    address public matchAddress;
    address public deployer;
    
    // ============================================================================
    // MAIN
    // ============================================================================
    
    function run() external {
        deployer = msg.sender;
        
        // Load factory address from environment
        address factoryAddr = vm.envAddress("FACTORY_ADDRESS");
        factory = BettingMatchFactory(factoryAddr);
        
        vm.startBroadcast();
        
        _printHeader();
        
        // Step 1: Create the match
        _createMatch();
        
        // Step 2: Add markets
        _addMarkets();
        
        // Step 3: Open markets for betting
        _openMarkets();
        
        _printSummary();
        
        vm.stopBroadcast();
    }
    
    // ============================================================================
    // DEPLOYMENT STEPS
    // ============================================================================
    
    function _createMatch() internal {
        console.log("STEP 1: Creating Football Match");
        console.log("================================");
        
        matchAddress = factory.createFootballMatch(MATCH_NAME, deployer);
        match_ = FootballMatch(payable(matchAddress));
        
        console.log("Match Name:", MATCH_NAME);
        console.log("Match Address:", matchAddress);
        console.log("Owner:", deployer);
        console.log("");
    }
    
    function _addMarkets() internal {
        console.log("STEP 2: Adding Markets");
        console.log("======================");
        
        // Market 0: Winner (1X2)
        console.log("Adding WINNER market (Home/Draw/Away)...");
        match_.addMarket(MARKET_WINNER, ODDS_HOME_WIN);
        console.log("  Market ID: 0");
        console.log("  Initial Odds: 2.20x (Home Win)");
        
        // Market 1: Goals Over/Under 2.5
        console.log("Adding GOALS_TOTAL market (Over/Under 2.5)...");
        match_.addMarketWithLine(MARKET_GOALS_TOTAL, ODDS_OVER_25, 25); // line=25 means 2.5 goals
        console.log("  Market ID: 1");
        console.log("  Line: 2.5 goals");
        console.log("  Initial Odds: 1.85x (Over)");
        
        // Market 2: Both Teams To Score
        console.log("Adding BOTH_SCORE market (Yes/No)...");
        match_.addMarket(MARKET_BOTH_SCORE, ODDS_BTTS_YES);
        console.log("  Market ID: 2");
        console.log("  Initial Odds: 1.70x (Yes)");
        
        console.log("");
    }
    
    function _openMarkets() internal {
        console.log("STEP 3: Opening Markets for Betting");
        console.log("====================================");
        
        // Open all markets
        match_.openMarket(0);
        console.log("Market 0 (WINNER): OPEN");
        
        match_.openMarket(1);
        console.log("Market 1 (GOALS_TOTAL): OPEN");
        
        match_.openMarket(2);
        console.log("Market 2 (BOTH_SCORE): OPEN");
        
        console.log("");
        console.log("All markets are now accepting bets!");
        console.log("");
    }
    
    // ============================================================================
    // HELPERS
    // ============================================================================
    
    function _printHeader() internal view {
        console.log("");
        console.log("=============================================");
        console.log("CHILIZ-TV FOOTBALL MATCH SETUP");
        console.log("=============================================");
        console.log("");
        console.log("Factory:", address(factory));
        console.log("Deployer:", deployer);
        console.log("");
    }
    
    function _printSummary() internal view {
        console.log("=============================================");
        console.log("SETUP COMPLETE!");
        console.log("=============================================");
        console.log("");
        console.log("MATCH ADDRESS:", matchAddress);
        console.log("");
        console.log("MARKETS AVAILABLE:");
        console.log("------------------");
        console.log("Market 0 - WINNER (1X2):");
        console.log("  Selection 0 = Home Win");
        console.log("  Selection 1 = Draw");
        console.log("  Selection 2 = Away Win");
        console.log("");
        console.log("Market 1 - GOALS TOTAL (Over/Under 2.5):");
        console.log("  Selection 0 = Under 2.5");
        console.log("  Selection 1 = Over 2.5");
        console.log("");
        console.log("Market 2 - BOTH TEAMS TO SCORE:");
        console.log("  Selection 0 = No");
        console.log("  Selection 1 = Yes");
        console.log("");
        console.log("=============================================");
        console.log("HOW TO BET (using cast):");
        console.log("=============================================");
        console.log("");
        console.log("Bet 0.01 ETH on Home Win (Market 0, Selection 0):");
        console.log("  cast send", matchAddress);
        console.log("    'placeBet(uint256,uint64)'");
        console.log("    0 0");
        console.log("    --value 0.01ether");
        console.log("    --rpc-url https://base-sepolia.drpc.org");
        console.log("    --private-key $PRIVATE_KEY");
        console.log("");
        console.log("Bet 0.05 ETH on Over 2.5 goals (Market 1, Selection 1):");
        console.log("  cast send", matchAddress);
        console.log("    'placeBet(uint256,uint64)'");
        console.log("    1 1");
        console.log("    --value 0.05ether");
        console.log("    --rpc-url https://base-sepolia.drpc.org");
        console.log("    --private-key $PRIVATE_KEY");
        console.log("");
        console.log("=============================================");
        console.log("ADMIN COMMANDS:");
        console.log("=============================================");
        console.log("");
        console.log("Update odds (e.g., change Home Win to 2.50x):");
        console.log("  cast send", matchAddress);
        console.log("    'setMarketOdds(uint256,uint32)'");
        console.log("    0 25000");
        console.log("");
        console.log("Resolve market (e.g., Home Win = selection 0):");
        console.log("  cast send", matchAddress);
        console.log("    'resolveMarket(uint256,uint64)'");
        console.log("    0 0");
        console.log("");
        console.log("Close market (stop accepting bets):");
        console.log("  cast send", matchAddress);
        console.log("    'closeMarket(uint256)'");
        console.log("    0");
        console.log("");
    }
}
