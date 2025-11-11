// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

// Import betting system contracts
import {SportBeaconRegistry} from "../src/SportBeaconRegistry.sol";
import {FootballBetting} from "../src/betting/FootballBetting.sol";
import {UFCBetting} from "../src/betting/UFCBetting.sol";
import {MatchHubBeaconFactory} from "../src/matchhub/MatchHubBeaconFactory.sol";

/**
 * @title DeployBetting
 * @author ChilizTV
 * @notice Focused deployment script for the Betting System only
 * @dev Deploys SportBeaconRegistry, betting implementations, and MatchHubBeaconFactory
 * 
 * SAFE MULTISIG: Acts as both Treasury AND Registry Owner
 * =========================================================
 * The Safe multisig address serves dual purposes:
 * 1. TREASURY: Receives platform fees from all betting activity
 * 2. REGISTRY OWNER: Controls upgrades to betting implementations
 * 
 * DEPLOYMENT PROCESS:
 * ==================
 * - Deployer uses PRIVATE_KEY to deploy contracts (pays gas)
 * - After deployment, registry ownership transfers to SAFE_ADDRESS
 * - Safe then controls both fee collection and upgrade authority
 * 
 * WHAT THIS SCRIPT DEPLOYS:
 * ========================
 * 1. FootballBetting Implementation (1X2 betting: HOME/DRAW/AWAY)
 * 2. UFCBetting Implementation (MMA betting: RED/BLUE/DRAW)
 * 3. SportBeaconRegistry (manages beacons per sport, owned by Safe)
 * 4. MatchHubBeaconFactory (deploys match proxies)
 * 5. Configures beacons for each sport
 * 6. Transfers registry ownership to Safe multisig
 * 
 * BEACON PROXY PATTERN FOR SPORTS:
 * ================================
 * 
 * SportBeaconRegistry (owned by Safe)
 *    ↓ manages multiple beacons
 * Beacon[FOOTBALL] → FootballBetting Implementation
 * Beacon[UFC] → UFCBetting Implementation
 * Beacon[BASKETBALL] → (future sport)
 *    ↑ delegates to
 * BeaconProxy (per match)
 *    ↑ deployed by
 * MatchHubBeaconFactory
 * 
 * KEY BENEFITS:
 * - Each sport has its own beacon & implementation
 * - Upgrade all Football matches with 1 transaction
 * - Upgrade all UFC matches independently with 1 transaction
 * - Factory can only create matches, not upgrade them
 * - Safe multisig controls all upgrades
 * 
 * SPORT IDENTIFIERS:
 * - FOOTBALL: keccak256("FOOTBALL") - 1X2 betting (3 outcomes)
 * - UFC: keccak256("UFC") - MMA betting (2-3 outcomes)
 * - More sports can be added by deploying new implementations
 * 
 * USAGE:
 * =====
 * Set environment variables:
 *   export PRIVATE_KEY=0x...           # Deployer private key (pays gas only)
 *   export RPC_URL=https://...         # Network RPC endpoint
 *   export SAFE_ADDRESS=0x...          # Safe multisig (Treasury + Registry Owner)
 * 
 * Run:
 *   forge script script/DeployBetting.s.sol --rpc-url $RPC_URL --broadcast --verify
 * 
 * POST-DEPLOYMENT:
 * ===============
 * 1. Verify contracts on block explorer
 * 2. Create a football match:
 *    matchHubFactory.createFootballMatch(
 *      owner, token, matchId, cutoffTimestamp, feeBps, treasury
 *    )
 * 3. Users can bet with native CHZ:
 *    - Send CHZ with betHome{value: amount}(), betDraw{value: amount}(), or betAway{value: amount}()
 * 4. Oracle settles match: match.settle(winningOutcome)
 * 5. Winners claim: match.claim()
 */
contract DeployBetting is Script {
    
    // ============================================================================
    // CONFIGURATION
    // ============================================================================
    
    /// @notice Sport identifier for Football (1X2 betting)
    bytes32 public constant SPORT_FOOTBALL = keccak256("FOOTBALL");
    
    /// @notice Sport identifier for UFC/MMA (2-3 outcome betting)
    bytes32 public constant SPORT_UFC = keccak256("UFC");
    
    
    // ============================================================================
    // DEPLOYED CONTRACTS
    // ============================================================================
    
    FootballBetting public footballBettingImpl;
    UFCBetting public ufcBettingImpl;
    SportBeaconRegistry public sportRegistry;
    MatchHubBeaconFactory public matchHubFactory;
    
    address public deployer;
    address public treasury; // Safe multisig - receives fees AND owns registries
    
    
    // ============================================================================
    // MAIN DEPLOYMENT
    // ============================================================================
    
    function run() external {
        // Load configuration from environment
        _loadConfig();
        
        // Validate configuration
        require(treasury != address(0), "SAFE_ADDRESS must be set");
        
        vm.startBroadcast();
        
        _printHeader();
        _deployImplementations();
        _deployRegistry();
        _deployFactory();
        _configureBeacons();
        _transferOwnership();
        _printSummary();
        
        vm.stopBroadcast();
    }
    
    
    // ============================================================================
    // DEPLOYMENT STEPS
    // ============================================================================
    
    /**
     * @notice STEP 1: Deploy betting implementations
     * @dev These are the logic contracts for different sports
     *      
     *      FootballBetting: 1X2 betting (HOME/DRAW/AWAY)
     *      - Extends MatchBettingBase with 3 outcomes
     *      - Parimutuel betting model (pool-based)
     *      - Platform fee deducted on claim
     *      
     *      UFCBetting: MMA betting (RED/BLUE/DRAW optional)
     *      - Extends MatchBettingBase with 2-3 outcomes
     *      - Parimutuel betting model
     *      - Same fee structure as Football
     */
    function _deployImplementations() internal {
        console.log("STEP 1: Deploying Betting Implementations");
        console.log("------------------------------------------");
        
        // Deploy FootballBetting implementation
        footballBettingImpl = new FootballBetting();
        console.log("FootballBetting Implementation:", address(footballBettingImpl));
        console.log("  Sport: Football (Soccer)");
        console.log("  Outcomes: HOME (0), DRAW (1), AWAY (2)");
        console.log("  Betting Model: Parimutuel (pool-based)");
        console.log("  Functions: betHome(), betDraw(), betAway()");
        console.log("");
        
        // Deploy UFCBetting implementation
        ufcBettingImpl = new UFCBetting();
        console.log("UFCBetting Implementation:", address(ufcBettingImpl));
        console.log("  Sport: UFC/MMA");
        console.log("  Outcomes: RED (0), BLUE (1), DRAW (2, optional)");
        console.log("  Betting Model: Parimutuel (pool-based)");
        console.log("  Functions: betRed(), betBlue(), betDraw()");
        console.log("");
        
        console.log("Both implementations inherit from MatchBettingBase:");
        console.log("  - Role-based access control (ADMIN, SETTLER, PAUSER)");
        console.log("  - Betting cutoff timestamp enforcement");
        console.log("  - Parimutuel payout calculation");
        console.log("  - Platform fee handling");
        console.log("  - Settlement by oracle (SETTLER_ROLE)");
        console.log("  - Emergency pause capability");
        console.log("");
    }
    
    /**
     * @notice STEP 2: Deploy SportBeaconRegistry
     * @dev Registry manages multiple beacons (one per sport)
     *      Each sport can be upgraded independently
     *      
     *      SECURITY: Must be owned by Gnosis Safe
     *      Why? It controls upgrades for ALL matches of ALL sports!
     */
    function _deployRegistry() internal {
        console.log("STEP 2: Deploying SportBeaconRegistry");
        console.log("--------------------------------------");
        
        // Deploy registry with deployer as temporary owner
        sportRegistry = new SportBeaconRegistry(deployer);
        console.log("SportBeaconRegistry:", address(sportRegistry));
        console.log("Temporary Owner:", deployer);
        console.log("Final Owner (will transfer):", treasury);
        console.log("");
        
        console.log("Registry manages beacons per sport:");
        console.log("  - FOOTBALL beacon → FootballBetting implementation");
        console.log("  - UFC beacon → UFCBetting implementation");
        console.log("  - Future sports can be added anytime");
        console.log("");
        
        console.log("Registry functions:");
        console.log("  - setSportImplementation(sportHash, impl)");
        console.log("    * Creates beacon if doesn't exist");
        console.log("    * Upgrades beacon if exists");
        console.log("  - getBeacon(sportHash) → beacon address");
        console.log("  - getImplementation(sportHash) → current impl");
        console.log("");
    }
    
    /**
     * @notice STEP 3: Deploy MatchHubBeaconFactory
     * @dev Factory creates BeaconProxy instances for matches
     *      Queries registry to get beacon for each sport
     *      
     *      Factory ownership: Can remain with deployer/backend
     *      Why? Factory only creates matches, cannot upgrade implementations
     */
    function _deployFactory() internal {
        console.log("STEP 3: Deploying MatchHubBeaconFactory");
        console.log("---------------------------------------");
        
        // Deploy factory
        matchHubFactory = new MatchHubBeaconFactory(
            deployer,                    // Factory owner (can create matches)
            address(sportRegistry)       // Registry reference (immutable)
        );
        console.log("MatchHubBeaconFactory:", address(matchHubFactory));
        console.log("Owner:", deployer);
        console.log("Registry (immutable):", address(sportRegistry));
        console.log("");
        
        console.log("Factory functions:");
        console.log("  - createFootballMatch(owner, token, matchId, cutoff, fee, treasury)");
        console.log("  - createUFCMatch(owner, token, matchId, cutoff, fee, treasury, allowDraw)");
        console.log("");
        
        console.log("How createFootballMatch works:");
        console.log("  1. Factory queries: registry.getBeacon(SPORT_FOOTBALL)");
        console.log("  2. Factory gets beacon address");
        console.log("  3. Factory prepares init data with match parameters");
        console.log("  4. Factory deploys: new BeaconProxy(beacon, initData)");
        console.log("  5. Proxy initializes with match-specific config");
        console.log("  6. Proxy grants roles to owner (ADMIN, SETTLER, PAUSER)");
        console.log("  7. Match is ready for betting!");
        console.log("");
        
        console.log("Match lifecycle:");
        console.log("  OPEN → Users bet (before cutoff) → CUTOFF");
        console.log("       → Oracle settles (SETTLER_ROLE)");
        console.log("       → Winners claim payouts");
        console.log("       → Platform fee sent to treasury");
        console.log("");
    }
    
    /**
     * @notice STEP 4: Configure beacons for each sport
     * @dev Creates UpgradeableBeacon for each sport
     *      Points beacon to corresponding implementation
     *      
     *      After this step:
     *      - Factory can create Football matches
     *      - Factory can create UFC matches
     *      - All matches point to correct implementations via beacons
     */
    function _configureBeacons() internal {
        console.log("STEP 4: Configuring Sport Beacons");
        console.log("----------------------------------");
        
        // Configure Football beacon
        console.log("Creating Football beacon...");
        sportRegistry.setSportImplementation(SPORT_FOOTBALL, address(footballBettingImpl));
        address footballBeacon = sportRegistry.getBeacon(SPORT_FOOTBALL);
        address footballImpl = sportRegistry.getImplementation(SPORT_FOOTBALL);
        console.log("  Sport: FOOTBALL");
        console.log("  Beacon:", footballBeacon);
        console.log("  Implementation:", footballImpl);
        console.log("  Status: Football beacon configured ✓");
        console.log("");
        
        // Configure UFC beacon
        console.log("Creating UFC beacon...");
        sportRegistry.setSportImplementation(SPORT_UFC, address(ufcBettingImpl));
        address ufcBeacon = sportRegistry.getBeacon(SPORT_UFC);
        address ufcImpl = sportRegistry.getImplementation(SPORT_UFC);
        console.log("  Sport: UFC");
        console.log("  Beacon:", ufcBeacon);
        console.log("  Implementation:", ufcImpl);
        console.log("  Status: UFC beacon configured ✓");
        console.log("");
        
        console.log("Beacons are ready! Factory can now create matches.");
        console.log("Each sport is independent - can be upgraded separately.");
        console.log("");
    }
    
    /**
     * @notice STEP 5: Transfer registry ownership to Safe
     * @dev CRITICAL SECURITY STEP!
     *      Registry controls upgrades for ALL betting matches
     *      Must be owned by multisig, not single EOA
     *      
     *      The Safe multisig serves dual purposes:
     *      1. TREASURY: Receives all platform fees
     *      2. REGISTRY OWNER: Controls implementation upgrades
     *      
     *      After this:
     *      - Only Safe can upgrade Football implementation
     *      - Only Safe can upgrade UFC implementation
     *      - Only Safe can add new sports
     *      - Safe receives all platform fees
     *      - Deployer cannot upgrade anymore (security!)
     *      - Factory owner can still create matches (safe)
     */
    function _transferOwnership() internal {
        console.log("STEP 5: Transferring Ownership to Safe");
        console.log("---------------------------------------");
        
        console.log("Transferring SportBeaconRegistry...");
        console.log("  From:", deployer);
        console.log("  To:", treasury);
        
        sportRegistry.transferOwnership(treasury);
        
        console.log("Status: Ownership transferred ✓");
        console.log("");
        
        console.log("IMPORTANT:");
        console.log("  ✓ Registry owned by Safe multisig:", treasury);
        console.log("  ✓ Safe receives all platform fees (treasury)");
        console.log("  ✓ Only Safe can upgrade sport implementations");
        console.log("  ✓ Only Safe can add new sports");
        console.log("  ✓ Deployer can still create matches via factory");
        console.log("  ✓ System is now secure for production");
        console.log("");
    }
    
    
    // ============================================================================
    // HELPER FUNCTIONS
    // ============================================================================
    
    function _loadConfig() internal {
        deployer = msg.sender;
        
        // Load Safe address (REQUIRED) - serves as both treasury and registry owner
        try vm.envAddress("SAFE_ADDRESS") returns (address addr) {
            treasury = addr;
        } catch {
            console.log("ERROR: SAFE_ADDRESS environment variable not set!");
            console.log("Safe address is required for:");
            console.log("  1. Treasury (receives platform fees)");
            console.log("  2. Registry ownership (controls upgrades)");
            revert("SAFE_ADDRESS required");
        }
    }
    
    function _printHeader() internal view {
        console.log("=====================================");
        console.log("CHILIZ-TV BETTING SYSTEM DEPLOYMENT");
        console.log("=====================================");
        console.log("");
        console.log("Deployer:", deployer, "(pays gas only)");
        console.log("Safe/Treasury:", treasury, "(receives fees + owns registries)");
        console.log("");
        console.log("Sports to deploy:");
        console.log("  - Football (1X2 betting)");
        console.log("  - UFC (MMA betting)");
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
        console.log("FootballBetting Implementation:", address(footballBettingImpl));
        console.log("UFCBetting Implementation:", address(ufcBettingImpl));
        console.log("SportBeaconRegistry:", address(sportRegistry));
        console.log("  Owner:", treasury);
        console.log("  Football Beacon:", sportRegistry.getBeacon(SPORT_FOOTBALL));
        console.log("  UFC Beacon:", sportRegistry.getBeacon(SPORT_UFC));
        console.log("MatchHubBeaconFactory:", address(matchHubFactory));
        console.log("  Owner:", deployer);
        console.log("");
        
        console.log("CREATE A FOOTBALL MATCH:");
        console.log("-----------------------");
        console.log("cast send", address(matchHubFactory));
        console.log("  'createFootballMatch(address,bytes32,uint64,uint16,address)'");
        console.log("  <OWNER_ADDRESS>        # Admin for the match");
        console.log("  <MATCH_ID>             # Unique ID (bytes32)");
        console.log("  <CUTOFF_TIMESTAMP>     # Betting closes");
        console.log("  <FEE_BPS>              # Platform fee (e.g., 500 = 5%)");
        console.log("  <TREASURY_ADDRESS>     # Fee receiver");
        console.log("");
        
        console.log("CREATE A UFC MATCH:");
        console.log("------------------");
        console.log("cast send", address(matchHubFactory));
        console.log("  'createUFCMatch(address,bytes32,uint64,uint16,address,bool)'");
        console.log("  ... (same params as football)");
        console.log("  <ALLOW_DRAW>           # true/false for draw outcome");
        console.log("");
        
        console.log("BETTING FLOW:");
        console.log("------------");
        console.log("1. User sends CHZ with bet: match.betHome{value: amount}()");
        console.log("2. CHZ transferred from user to match contract");
        console.log("3. Bet recorded in user's account");
        console.log("4. After cutoff, oracle settles: match.settle(winningOutcome)");
        console.log("5. Winners claim: match.claim()");
        console.log("6. Platform fee sent to treasury, payout to winner");
        console.log("");
        
        console.log("UPGRADING SPORTS (Safe multisig only):");
        console.log("--------------------------------------");
        console.log("To upgrade Football:");
        console.log("  1. Deploy new FootballBetting implementation");
        console.log("  2. Via Safe: sportRegistry.setSportImplementation(SPORT_FOOTBALL, newImpl)");
        console.log("  3. All existing football matches upgrade atomically!");
        console.log("");
        console.log("To upgrade UFC:");
        console.log("  1. Deploy new UFCBetting implementation");
        console.log("  2. Via Safe: sportRegistry.setSportImplementation(SPORT_UFC, newImpl)");
        console.log("  3. All existing UFC matches upgrade atomically!");
        console.log("");
        
        console.log("ADDING NEW SPORTS:");
        console.log("-----------------");
        console.log("1. Create new implementation (e.g., BasketballBetting extends MatchBettingBase)");
        console.log("2. Deploy implementation");
        console.log("3. Via Safe: sportRegistry.setSportImplementation(keccak256('BASKETBALL'), impl)");
        console.log("4. Update factory to add createBasketballMatch() function");
        console.log("5. New sport is ready!");
        console.log("");
        
        console.log("=====================================");
    }
}
