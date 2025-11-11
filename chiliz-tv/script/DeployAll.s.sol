// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

// Import all contracts to be deployed
import {SportBeaconRegistry} from "../src/SportBeaconRegistry.sol";
import {StreamBeaconRegistry} from "../src/streamer/StreamBeaconRegistry.sol";
import {FootballBetting} from "../src/betting/FootballBetting.sol";
import {UFCBetting} from "../src/betting/UFCBetting.sol";
import {StreamWallet} from "../src/streamer/StreamWallet.sol";
import {MatchHubBeaconFactory} from "../src/matchhub/MatchHubBeaconFactory.sol";
import {StreamWalletFactory} from "../src/streamer/StreamWalletFactory.sol";

/**
 * @title DeployAll
 * @author ChilizTV
 * @notice Complete deployment script for all Chiliz-TV smart contracts
 * @dev This script deploys the entire system following the Beacon Proxy Pattern for upgradeability
 * 
 * IMPORTANT NOTES:
 * ================
 * 1. SAFE MULTISIG: Acts as both Treasury AND Registry Owner
 *    - TREASURY: Receives all platform fees from betting & streaming
 *    - REGISTRY OWNER: Controls upgrades to all implementations
 *    - Deployer uses PRIVATE_KEY only to pay gas during deployment
 *    - After deployment, Safe controls both fee collection and upgrades
 * 
 * 2. BEACON PROXY PATTERN:
 *    - Uses OpenZeppelin's UpgradeableBeacon for contract upgradeability
 *    - Registry contracts (owned by Safe multisig) manage beacons
 *    - Factory contracts deploy BeaconProxy instances
 *    - All proxies point to same beacon → enables atomic upgrades
 * 
 * 3. TWO PARALLEL SYSTEMS:
 *    A) BETTING SYSTEM:
 *       SportBeaconRegistry → Manages beacons for different sports (Football, UFC)
 *       MatchHubBeaconFactory → Deploys match betting proxies
 *       Implementations: FootballBetting, UFCBetting
 *    
 *    B) STREAMING SYSTEM:
 *       StreamBeaconRegistry → Manages beacon for StreamWallet
 *       StreamWalletFactory → Deploys streamer wallet proxies
 *       Implementation: StreamWallet
 * 
 * 4. DEPLOYMENT ORDER (CRITICAL):
 *    Step 1: Deploy Implementation Contracts (logic)
 *    Step 2: Deploy Registry Contracts (beacon managers)
 *    Step 3: Deploy Factory Contracts (proxy deployers)
 *    Step 4: Configure Registries with Implementations (create beacons)
 *    Step 5: Transfer Registry ownership to Safe multisig
 * 
 * 5. OWNERSHIP & SECURITY:
 *    - Registries MUST be owned by Gnosis Safe (for upgrade security)
 *    - Factories can be owned by backend/deployer (only create matches/wallets)
 *    - Only registry owner can upgrade implementations
 * 
 * 6. USAGE:
 *    Set environment variables:
 *      - PRIVATE_KEY: Deployer private key (pays gas only)
 *      - RPC_URL: Network RPC endpoint
 *      - SAFE_ADDRESS: Safe multisig (Treasury + Registry Owner)
 *    
 *    Run: forge script script/DeployAll.s.sol --rpc-url $RPC_URL --broadcast --verify
 */
contract DeployAll is Script {
    
    // ============================================================================
    // CONFIGURATION CONSTANTS
    // ============================================================================
    
    /// @notice Default platform fee for streaming (5% = 500 basis points)
    uint16 public constant DEFAULT_PLATFORM_FEE_BPS = 500;
    
    /// @notice Sport identifier for Football (1X2 betting)
    bytes32 public constant SPORT_FOOTBALL = keccak256("FOOTBALL");
    
    /// @notice Sport identifier for UFC/MMA (2-3 outcome betting)
    bytes32 public constant SPORT_UFC = keccak256("UFC");
    
    
    // ============================================================================
    // STATE VARIABLES (Deployed Contract Addresses)
    // ============================================================================
    
    // === Implementation Contracts (Logic) ===
    FootballBetting public footballBettingImpl;
    UFCBetting public ufcBettingImpl;
    StreamWallet public streamWalletImpl;
    
    // === Registry Contracts (Beacon Managers) ===
    SportBeaconRegistry public sportRegistry;
    StreamBeaconRegistry public streamRegistry;
    
    // === Factory Contracts (Proxy Deployers) ===
    MatchHubBeaconFactory public matchHubFactory;
    StreamWalletFactory public streamFactory;
    
    // === Environment Variables ===
    address public deployer;
    address public treasury; // Safe multisig - receives fees AND owns registries
    
    
    // ============================================================================
    // MAIN DEPLOYMENT FUNCTION
    // ============================================================================
    
    /**
     * @notice Main deployment function - executes all deployment steps in order
     * @dev Called by `forge script`, uses vm.startBroadcast() for transaction signing
     */
    function run() external {
        // Load environment variables
        _loadConfig();
        
        // Start broadcasting transactions (signs with PRIVATE_KEY from env)
        vm.startBroadcast();
        
        console.log("=====================================");
        console.log("CHILIZ-TV DEPLOYMENT SCRIPT");
        console.log("=====================================");
        console.log("Deployer:", deployer, "(pays gas only)");
        console.log("Safe/Treasury:", treasury, "(receives fees + owns registries)");
        console.log("=====================================\n");
        
        // Execute deployment steps
        _deployImplementations();
        _deployRegistries();
        _deployFactories();
        _configureRegistries();
        _transferOwnership();
        
        vm.stopBroadcast();
        
        // Print deployment summary
        _printSummary();
    }
    
    
    // ============================================================================
    // STEP 1: DEPLOY IMPLEMENTATION CONTRACTS
    // ============================================================================
    
    /**
     * @notice Deploys all implementation contracts (logic contracts for proxies)
     * @dev These contracts contain the actual logic but are never called directly
     *      They're only used via delegatecall through BeaconProxy instances
     * 
     * DEPLOYED CONTRACTS:
     * - FootballBetting: Logic for football match betting (1X2 outcomes)
     * - UFCBetting: Logic for UFC/MMA betting (2-3 outcomes)
     * - StreamWallet: Logic for streamer wallets (subscriptions/donations)
     */
    function _deployImplementations() internal {
        console.log("STEP 1: Deploying Implementation Contracts");
        console.log("-------------------------------------------");
        
        // Deploy FootballBetting implementation
        // This contract handles 1X2 betting (HOME/DRAW/AWAY)
        footballBettingImpl = new FootballBetting();
        console.log("FootballBetting Implementation:", address(footballBettingImpl));
        
        // Deploy UFCBetting implementation
        // This contract handles MMA betting (RED/BLUE/DRAW optional)
        ufcBettingImpl = new UFCBetting();
        console.log("UFCBetting Implementation:", address(ufcBettingImpl));
        
        // Deploy StreamWallet implementation
        // This contract manages streamer revenue (subscriptions/donations)
        streamWalletImpl = new StreamWallet();
        console.log("StreamWallet Implementation:", address(streamWalletImpl));
        
        console.log("");
    }
    
    
    // ============================================================================
    // STEP 2: DEPLOY REGISTRY CONTRACTS
    // ============================================================================
    
    /**
     * @notice Deploys registry contracts that manage UpgradeableBeacons
     * @dev Registries are the ONLY contracts that can upgrade implementations
     *      They MUST be owned by a Gnosis Safe multisig for security
     * 
     * BEACON PATTERN EXPLANATION:
     * ---------------------------
     * Registry → Creates & manages Beacon → Points to Implementation
     *                                      ↓
     * Factory → Deploys BeaconProxy -------→ Delegates to Implementation
     * 
     * UPGRADING:
     * ----------
     * Registry.setImplementation(newImpl) → Beacon.upgradeTo(newImpl)
     *                                     ↓
     * All existing proxies automatically use new implementation!
     * 
     * DEPLOYED CONTRACTS:
     * - SportBeaconRegistry: Manages beacons for sports (Football, UFC, etc.)
     * - StreamBeaconRegistry: Manages beacon for StreamWallet
     */
    function _deployRegistries() internal {
        console.log("STEP 2: Deploying Registry Contracts (Beacon Managers)");
        console.log("------------------------------------------------------");
        
        // Deploy SportBeaconRegistry
        // Temporarily owned by deployer, will transfer to Safe later
        // Manages multiple beacons (one per sport: FOOTBALL, UFC, etc.)
        sportRegistry = new SportBeaconRegistry(deployer);
        console.log("SportBeaconRegistry:", address(sportRegistry));
        console.log("  Initial Owner:", deployer);
        console.log("  Purpose: Manages beacons for different sports");
        console.log("  Sports Supported: FOOTBALL, UFC (more can be added)");
        
        // Deploy StreamBeaconRegistry
        // Temporarily owned by deployer, will transfer to Safe later
        // Manages single beacon for all StreamWallet instances
        streamRegistry = new StreamBeaconRegistry(deployer);
        console.log("StreamBeaconRegistry:", address(streamRegistry));
        console.log("  Initial Owner:", deployer);
        console.log("  Purpose: Manages beacon for StreamWallet");
        
        console.log("");
    }
    
    
    // ============================================================================
    // STEP 3: DEPLOY FACTORY CONTRACTS
    // ============================================================================
    
    /**
     * @notice Deploys factory contracts that create proxy instances
     * @dev Factories use registries to get beacon addresses
     *      They deploy BeaconProxy instances for each match/streamer
     *      Factories can be owned by backend service (they only create, not upgrade)
     * 
     * FACTORY PATTERN EXPLANATION:
     * ----------------------------
     * User/Backend → Factory.createFootballMatch(params)
     *                Factory.createUFCMatch(params)
     *                Factory.subscribeToStream(streamer)
     *                  ↓
     *                Factory queries Registry for beacon address
     *                  ↓
     *                Factory deploys new BeaconProxy(beacon, initData)
     *                  ↓
     *                BeaconProxy initialized with match/streamer parameters
     * 
     * DEPLOYED CONTRACTS:
     * - MatchHubBeaconFactory: Creates betting match proxies (Football/UFC)
     * - StreamWalletFactory: Creates streamer wallet proxies
     */
    function _deployFactories() internal {
        console.log("STEP 3: Deploying Factory Contracts (Proxy Deployers)");
        console.log("-----------------------------------------------------");
        
        // Deploy MatchHubBeaconFactory
        // This factory creates BeaconProxy instances for betting matches
        // Owner can create matches but cannot upgrade implementations
        matchHubFactory = new MatchHubBeaconFactory(
            deployer,                    // Initial owner (can create matches)
            address(sportRegistry)       // Reference to SportBeaconRegistry
        );
        console.log("MatchHubBeaconFactory:", address(matchHubFactory));
        console.log("  Owner:", deployer);
        console.log("  Registry:", address(sportRegistry));
        console.log("  Purpose: Deploys betting match proxies");
        console.log("  Functions: createFootballMatch(), createUFCMatch()");
        
        // Deploy StreamWalletFactory
        // This factory creates BeaconProxy instances for streamer wallets
        // Also handles subscription/donation logic
        streamFactory = new StreamWalletFactory(
            deployer,                    // Initial owner
            address(streamRegistry),     // Reference to StreamBeaconRegistry
            treasury,                    // Platform treasury address (Safe multisig)
            DEFAULT_PLATFORM_FEE_BPS     // Default 5% platform fee
        );
        console.log("StreamWalletFactory:", address(streamFactory));
        console.log("  Owner:", deployer);
        console.log("  Registry:", address(streamRegistry));
        console.log("  Treasury:", treasury);
        console.log("  Platform Fee:", DEFAULT_PLATFORM_FEE_BPS, "bps (5%)");
        console.log("  Purpose: Deploys streamer wallet proxies");
        console.log("  Functions: subscribeToStream(), donateToStream()");
        
        console.log("");
    }
    
    
    // ============================================================================
    // STEP 4: CONFIGURE REGISTRIES WITH IMPLEMENTATIONS
    // ============================================================================
    
    /**
     * @notice Configures registries by creating beacons pointing to implementations
     * @dev This is where the magic happens - registries create UpgradeableBeacons
     *      Each beacon points to an implementation contract
     *      All future proxies will reference these beacons
     * 
     * BEACON CREATION FLOW:
     * ---------------------
     * 1. Registry.setSportImplementation(FOOTBALL, footballImpl)
     *    → Registry checks if beacon exists for FOOTBALL
     *    → If not, creates new UpgradeableBeacon(footballImpl, deployer)
     *    → Stores beacon in mapping: beacons[FOOTBALL] = beacon
     * 
     * 2. Registry.setSportImplementation(UFC, ufcImpl)
     *    → Same process for UFC sport
     * 
     * 3. StreamRegistry.setImplementation(streamWalletImpl)
     *    → Creates single beacon for StreamWallet
     * 
     * RESULT:
     * -------
     * - SportBeaconRegistry has 2 beacons (FOOTBALL, UFC)
     * - StreamBeaconRegistry has 1 beacon (StreamWallet)
     * - Factories can now deploy proxies using these beacons
     */
    function _configureRegistries() internal {
        console.log("STEP 4: Configuring Registries (Creating Beacons)");
        console.log("--------------------------------------------------");
        
        // Configure SportBeaconRegistry with Football implementation
        // Creates beacon: SPORT_FOOTBALL → FootballBetting implementation
        console.log("Creating Football beacon...");
        sportRegistry.setSportImplementation(SPORT_FOOTBALL, address(footballBettingImpl));
        address footballBeacon = sportRegistry.getBeacon(SPORT_FOOTBALL);
        console.log("  Sport:", "FOOTBALL");
        console.log("  Beacon Address:", footballBeacon);
        console.log("  Implementation:", address(footballBettingImpl));
        console.log("  Status: Football beacon created ✓");
        
        // Configure SportBeaconRegistry with UFC implementation
        // Creates beacon: SPORT_UFC → UFCBetting implementation
        console.log("Creating UFC beacon...");
        sportRegistry.setSportImplementation(SPORT_UFC, address(ufcBettingImpl));
        address ufcBeacon = sportRegistry.getBeacon(SPORT_UFC);
        console.log("  Sport:", "UFC");
        console.log("  Beacon Address:", ufcBeacon);
        console.log("  Implementation:", address(ufcBettingImpl));
        console.log("  Status: UFC beacon created ✓");
        
        // Configure StreamBeaconRegistry with StreamWallet implementation
        // Creates beacon: StreamWallet beacon → StreamWallet implementation
        console.log("Creating StreamWallet beacon...");
        streamRegistry.setImplementation(address(streamWalletImpl));
        address streamBeacon = streamRegistry.getBeacon();
        console.log("  Beacon Address:", streamBeacon);
        console.log("  Implementation:", address(streamWalletImpl));
        console.log("  Status: StreamWallet beacon created ✓");
        
        console.log("");
    }
    
    
    // ============================================================================
    // STEP 5: TRANSFER OWNERSHIP TO SAFE MULTISIG
    // ============================================================================
    
    /**
     * @notice Transfers registry ownership to Gnosis Safe multisig
     * @dev CRITICAL SECURITY STEP - Registries control upgrades!
     *      Only registries can upgrade implementations
     *      Must be owned by trusted multisig, not EOA
     * 
     * The Safe multisig serves dual purposes:
     * 1. TREASURY: Receives all platform fees
     * 2. REGISTRY OWNER: Controls implementation upgrades
     * 
     * SECURITY EXPLANATION:
     * --------------------
     * Without this step:
     *   - Deployer (single private key) can upgrade all contracts
     *   - Single point of failure / compromise risk
     * 
     * After this step:
     *   - Only Safe multisig can upgrade implementations
     *   - Safe receives all platform fees (treasury)
     *   - Requires multiple signers to approve upgrades
     *   - Much more secure for production
     * 
     * IMPORTANT:
     * ----------
     * - Factories remain owned by deployer (they only create, not upgrade)
     * - Registries MUST be transferred to Safe
     * - After transfer, deployer cannot upgrade implementations anymore
     * - Safe multisig must approve all future upgrades
     */
    function _transferOwnership() internal {
        console.log("STEP 5: Transferring Ownership to Safe Multisig");
        console.log("------------------------------------------------");
        
        // Check if Safe address is configured
        if (treasury == address(0)) {
            console.log("WARNING: SAFE_ADDRESS not set!");
            console.log("Registries remain owned by deployer:", deployer);
            console.log("This is INSECURE for production!");
            console.log("Please set SAFE_ADDRESS env variable and re-deploy");
            console.log("");
            return;
        }
        
        // Transfer SportBeaconRegistry ownership to Safe
        console.log("Transferring SportBeaconRegistry ownership...");
        console.log("  From:", deployer);
        console.log("  To:", treasury);
        sportRegistry.transferOwnership(treasury);
        console.log("  Status: Ownership transferred ✓");
        
        // Transfer StreamBeaconRegistry ownership to Safe
        console.log("Transferring StreamBeaconRegistry ownership...");
        console.log("  From:", deployer);
        console.log("  To:", treasury);
        streamRegistry.transferOwnership(treasury);
        console.log("  Status: Ownership transferred ✓");
        
        console.log("");
        console.log("CRITICAL: Registries now owned by Safe multisig:", treasury);
        console.log("Safe receives all platform fees (treasury)");
        console.log("Only Safe can upgrade implementations from now on.");
        console.log("Deployer can still create matches/wallets via factories.");
        console.log("");
    }
    
    
    // ============================================================================
    // HELPER FUNCTIONS
    // ============================================================================
    
    /**
     * @notice Loads configuration from environment variables
     * @dev Reads SAFE_ADDRESS from environment
     *      Falls back to zero address if not set (will trigger warnings)
     */
    function _loadConfig() internal {
        deployer = msg.sender;
        
        // Try to load Safe address from environment - serves as both treasury and registry owner
        try vm.envAddress("SAFE_ADDRESS") returns (address addr) {
            treasury = addr;
        } catch {
            console.log("SAFE_ADDRESS not set - will skip ownership transfer");
            console.log("Safe address is required for:");
            console.log("  1. Treasury (receives platform fees)");
            console.log("  2. Registry ownership (controls upgrades)");
            treasury = address(0);
        }
    }
    
    /**
     * @notice Prints comprehensive deployment summary
     * @dev Shows all deployed addresses and next steps
     */
    function _printSummary() internal view {
        console.log("=====================================");
        console.log("DEPLOYMENT COMPLETE!");
        console.log("=====================================\n");
        
        console.log("IMPLEMENTATION CONTRACTS (Logic):");
        console.log("  FootballBetting:", address(footballBettingImpl));
        console.log("  UFCBetting:", address(ufcBettingImpl));
        console.log("  StreamWallet:", address(streamWalletImpl));
        console.log("");
        
        console.log("REGISTRY CONTRACTS (Beacon Managers):");
        console.log("  SportBeaconRegistry:", address(sportRegistry));
        console.log("    Owner:", treasury != address(0) ? treasury : deployer);
        console.log("    Football Beacon:", sportRegistry.getBeacon(SPORT_FOOTBALL));
        console.log("    UFC Beacon:", sportRegistry.getBeacon(SPORT_UFC));
        console.log("  StreamBeaconRegistry:", address(streamRegistry));
        console.log("    Owner:", treasury != address(0) ? treasury : deployer);
        console.log("    StreamWallet Beacon:", streamRegistry.getBeacon());
        console.log("");
        
        console.log("FACTORY CONTRACTS (Proxy Deployers):");
        console.log("  MatchHubBeaconFactory:", address(matchHubFactory));
        console.log("    Owner:", deployer);
        console.log("  StreamWalletFactory:", address(streamFactory));
        console.log("    Owner:", deployer);
        console.log("    Treasury:", treasury);
        console.log("");
        
        console.log("NEXT STEPS:");
        console.log("----------");
        console.log("1. Verify contracts on block explorer");
        console.log("2. Test creating a football match:");
        console.log("   matchHubFactory.createFootballMatch(...)");
        console.log("3. Test creating a UFC match:");
        console.log("   matchHubFactory.createUFCMatch(...)");
        console.log("4. Test subscribing to a stream:");
        console.log("   streamFactory.subscribeToStream(...)");
        console.log("");
        
        if (treasury == address(0)) {
            console.log("WARNING: Registries not transferred to Safe!");
            console.log("Set SAFE_ADDRESS env variable and transfer ownership manually:");
            console.log("  sportRegistry.transferOwnership(treasuryAddress)");
            console.log("  streamRegistry.transferOwnership(treasuryAddress)");
            console.log("");
        }
        
        console.log("UPGRADING IMPLEMENTATIONS (Safe multisig only):");
        console.log("-----------------------------------------------");
        console.log("To upgrade Football implementation:");
        console.log("  1. Deploy new FootballBetting implementation");
        console.log("  2. Via Safe: sportRegistry.setSportImplementation(SPORT_FOOTBALL, newImpl)");
        console.log("  3. All existing match proxies automatically use new implementation!");
        console.log("");
        console.log("To upgrade UFC implementation:");
        console.log("  1. Deploy new UFCBetting implementation");
        console.log("  2. Via Safe: sportRegistry.setSportImplementation(SPORT_UFC, newImpl)");
        console.log("");
        console.log("To upgrade StreamWallet implementation:");
        console.log("  1. Deploy new StreamWallet implementation");
        console.log("  2. Via Safe: streamRegistry.setImplementation(newImpl)");
        console.log("  3. All existing streamer wallets automatically use new implementation!");
        console.log("");
        
        console.log("=====================================");
        console.log("Thank you for using ChilizTV!");
        console.log("=====================================");
    }
}
