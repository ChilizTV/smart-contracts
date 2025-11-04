// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {SportBeaconRegistry} from "../src/SportBeaconRegistry.sol";
import {MatchHubBeaconFactory} from "../src/matchhub/MatchHubBeaconFactory.sol";
import {FootballBetting} from "../src/betting/FootballBetting.sol";
import {UFCBetting} from "../src/betting/UFCBetting.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

/// @title ChilizTV Betting System Deployment Script
/// @notice Deploys complete Beacon Pattern architecture for betting system
/// @dev Deployment order:
///      1. SportBeaconRegistry (central registry)
///      2. Sport Implementations (FootballBetting, UFCBetting)
///      3. UpgradeableBeacons (one per sport)
///      4. Register beacons in registry
///      5. MatchHubBeaconFactory (creates match instances)
contract DeployBettingSystem is Script {
    // ========================================================================
    // STATE VARIABLES
    // ========================================================================
    
    // Core contracts
    SportBeaconRegistry public registry;
    MatchHubBeaconFactory public factory;
    
    // Sport implementations
    FootballBetting public footballImpl;
    UFCBetting public ufcImpl;
    
    // Beacons
    UpgradeableBeacon public footballBeacon;
    UpgradeableBeacon public ufcBeacon;
    
    // Sport identifiers (matching MatchHubBeaconFactory constants)
    bytes32 public constant SPORT_FOOTBALL = keccak256("FOOTBALL");
    bytes32 public constant SPORT_UFC = keccak256("UFC");
    
    // Configuration parameters
    address public deployer;
    address public treasury;
    uint256 public minBetChz;
    
    // ========================================================================
    // SETUP
    // ========================================================================
    
    function setUp() public {
        // Get deployer from private key
        deployer = vm.addr(vm.envUint("PRIVATE_KEY"));
        
        // Load configuration from environment
        _loadConfiguration();
        
        // Display configuration
        _displayConfiguration();
    }
    
    // ========================================================================
    // MAIN DEPLOYMENT FUNCTION
    // ========================================================================
    
    function run() public {
        console.log("\n========================================");
        console.log("STARTING DEPLOYMENT");
        console.log("========================================\n");
        
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        
        // PHASE 1: Deploy Registry
        _deployRegistry();
        
        // PHASE 2: Deploy Implementations
        _deployImplementations();
        
        // PHASE 3: Register Implementations (Registry creates beacons)
        _registerImplementations();
        
        // PHASE 4: Deploy Factory
        _deployFactory();
        
        vm.stopBroadcast();
        
        // Display summary
        _displaySummary();
    }
    
    // ========================================================================
    // DEPLOYMENT PHASES
    // ========================================================================
    
    /// @notice Phase 1: Deploy SportBeaconRegistry
    function _deployRegistry() internal {
        console.log("PHASE 1: Deploying SportBeaconRegistry");
        console.log("---------------------------------------");
        
        registry = new SportBeaconRegistry(deployer);
        
        console.log("[OK] SportBeaconRegistry deployed at:", address(registry));
        console.log("     Owner:", deployer);
        console.log("");
    }
    
    /// @notice Phase 2: Deploy sport implementation contracts
    function _deployImplementations() internal {
        console.log("PHASE 2: Deploying Sport Implementations");
        console.log("-----------------------------------------");
        
        // Deploy FootballBetting implementation
        footballImpl = new FootballBetting();
        console.log("[OK] FootballBetting impl deployed at:", address(footballImpl));
        
        // Deploy UFCBetting implementation
        ufcImpl = new UFCBetting();
        console.log("[OK] UFCBetting impl deployed at:", address(ufcImpl));
        console.log("");
    }
    
    /// @notice Phase 3: Register implementations with Registry (creates beacons)
    function _registerImplementations() internal {
        console.log("PHASE 3: Registering Sport Implementations");
        console.log("-------------------------------------------");
        
        // Register Football implementation (registry creates beacon internally)
        registry.setSportImplementation(SPORT_FOOTBALL, address(footballImpl));
        footballBeacon = UpgradeableBeacon(registry.getBeacon(SPORT_FOOTBALL));
        
        console.log("[OK] Football sport registered");
        console.log("     Sport ID:", vm.toString(SPORT_FOOTBALL));
        console.log("     Implementation:", address(footballImpl));
        console.log("     Beacon (auto-created):", address(footballBeacon));
        
        // Register UFC implementation (registry creates beacon internally)
        registry.setSportImplementation(SPORT_UFC, address(ufcImpl));
        ufcBeacon = UpgradeableBeacon(registry.getBeacon(SPORT_UFC));
        
        console.log("[OK] UFC sport registered");
        console.log("     Sport ID:", vm.toString(SPORT_UFC));
        console.log("     Implementation:", address(ufcImpl));
        console.log("     Beacon (auto-created):", address(ufcBeacon));
        console.log("");
    }
    
    /// @notice Phase 4: Deploy MatchHubBeaconFactory
    function _deployFactory() internal {
        console.log("PHASE 4: Deploying MatchHubBeaconFactory");
        console.log("-----------------------------------------");
        
        factory = new MatchHubBeaconFactory(
            deployer,          // initialOwner
            address(registry),  // registryAddr
            treasury,          // treasuryAddr
            minBetChz          // minBetChz_
        );
        
        console.log("[OK] MatchHubBeaconFactory deployed at:", address(factory));
        console.log("     Owner:", deployer);
        console.log("     Registry:", address(registry));
        console.log("     Treasury:", treasury);
        console.log("     Min Bet CHZ:", minBetChz);
        console.log("");
    }
    
    // ========================================================================
    // CONFIGURATION HELPERS
    // ========================================================================
    
    /// @notice Load configuration from environment variables
    function _loadConfiguration() internal {
        // Get treasury
        try vm.envAddress("TREASURY") returns (address treasuryAddr) {
            treasury = treasuryAddr;
        } catch {
            console.log("[WARN] TREASURY not set, using deployer address");
            treasury = deployer;
        }
        
        // Get minimum bet in CHZ
        try vm.envUint("MIN_BET_CHZ") returns (uint256 minBet) {
            minBetChz = minBet;
        } catch {
            console.log("[WARN] MIN_BET_CHZ not set, using default: 5 CHZ");
            minBetChz = 5e18; // Default: 5 CHZ
        }
    }
    
    /// @notice Display deployment configuration
    function _displayConfiguration() internal view {
        console.log("\n========================================");
        console.log("DEPLOYMENT CONFIGURATION");
        console.log("========================================");
        console.log("Deployer:", deployer);
        console.log("Deployer Balance (CHZ):", deployer.balance / 1e18);
        console.log("");
        console.log("Treasury:", treasury);
        console.log("Min Bet (CHZ, 18 decimals):", minBetChz);
        console.log("Min Bet (display):", minBetChz / 1e18, "CHZ");
        console.log("========================================\n");
    }
    
    /// @notice Display deployment summary
    function _displaySummary() internal view {
        console.log("\n========================================");
        console.log("DEPLOYMENT SUMMARY");
        console.log("========================================");
        console.log("");
        console.log("Core Contracts:");
        console.log("---------------");
        console.log("SportBeaconRegistry:", address(registry));
        console.log("MatchHubBeaconFactory:", address(factory));
        console.log("");
        console.log("Sport Implementations:");
        console.log("----------------------");
        console.log("FootballBetting:", address(footballImpl));
        console.log("UFCBetting:", address(ufcImpl));
        console.log("");
        console.log("Beacons:");
        console.log("--------");
        console.log("Football Beacon:", address(footballBeacon));
        console.log("UFC Beacon:", address(ufcBeacon));
        console.log("");
        console.log("Configuration:");
        console.log("--------------");
        console.log("Owner:", deployer);
        console.log("Treasury:", treasury);
        console.log("Min Bet:", minBetChz / 1e18, "CHZ");
        console.log("");
        
        console.log("Next Steps:");
        console.log("-----------");
        console.log("1. Verify contracts on block explorer");
        console.log("2. Create matches via factory:");
        console.log("   factory.createFootballMatch(...)");
        console.log("   factory.createUFCMatch(...)");
        console.log("3. Users can bet on created match proxies");
        console.log("4. Settler resolves matches via proxy.settle()");
        console.log("5. Winners claim payouts via proxy.claim()");
        console.log("");
        console.log("========================================");
        console.log("DEPLOYMENT COMPLETE!");
        console.log("========================================\n");
    }
}
