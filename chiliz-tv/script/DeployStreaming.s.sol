// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

// Import streaming system contracts
import {StreamBeaconRegistry} from "../src/streamer/StreamBeaconRegistry.sol";
import {StreamWallet} from "../src/streamer/StreamWallet.sol";
import {StreamWalletFactory} from "../src/streamer/StreamWalletFactory.sol";

/**
 * @title DeployStreaming
 * @author ChilizTV
 * @notice Focused deployment script for the Streaming System only
 * @dev Deploys StreamBeaconRegistry, StreamWallet implementation, and StreamWalletFactory
 * 
 * SAFE MULTISIG: Acts as both Treasury AND Registry Owner
 * =========================================================
 * The Safe multisig address serves dual purposes:
 * 1. TREASURY: Receives platform fees from all streaming activity
 * 2. REGISTRY OWNER: Controls upgrades to StreamWallet implementation
 * 
 * DEPLOYMENT PROCESS:
 * ==================
 * - Deployer uses PRIVATE_KEY to deploy contracts (pays gas)
 * - After deployment, registry ownership transfers to SAFE_ADDRESS
 * - Safe then controls both fee collection and upgrade authority
 * 
 * WHAT THIS SCRIPT DEPLOYS:
 * ========================
 * 1. StreamWallet Implementation (logic contract)
 * 2. StreamBeaconRegistry (beacon manager, owned by Safe)
 * 3. StreamWalletFactory (proxy deployer)
 * 4. Configures beacon to point to implementation
 * 5. Transfers registry ownership to Safe multisig
 * 
 * BEACON PROXY PATTERN EXPLAINED:
 * ===============================
 * 
 * StreamBeaconRegistry (owned by Safe)
 *    ↓ creates & owns
 * UpgradeableBeacon
 *    ↓ points to
 * StreamWallet Implementation (logic)
 *    ↑ delegates calls to
 * BeaconProxy (per streamer)
 *    ↑ deployed by
 * StreamWalletFactory
 * 
 * KEY BENEFITS:
 * - Single transaction upgrades ALL streamer wallets
 * - Factory cannot upgrade (only Safe can via Registry)
 * - Each streamer gets isolated proxy with own storage
 * - All proxies share same logic (gas efficient)
 * 
 * USAGE:
 * =====
 * Set environment variables:
 *   export PRIVATE_KEY=0x...           # Deployer private key (pays gas only)
 *   export RPC_URL=https://...         # Network RPC endpoint
 *   export SAFE_ADDRESS=0x...          # Safe multisig (Treasury + Registry Owner)
 * 
 * Run:
 *   forge script script/DeployStreaming.s.sol --rpc-url $RPC_URL --broadcast --verify
 * 
 * POST-DEPLOYMENT:
 * ===============
 * 1. Verify contracts on block explorer
 * 2. Test subscription flow:
 *    - User sends CHZ with factory.subscribeToStream{value: amount}(streamerAddress, duration)
 *    - Factory deploys wallet (if first time) and records subscription
 * 3. Streamer can withdraw: wallet.withdrawRevenue(amount)
 */
contract DeployStreaming is Script {
    
    // ============================================================================
    // CONFIGURATION
    // ============================================================================
    
    /// @notice Default platform fee (5% = 500 basis points)
    /// @dev Can be changed later by factory owner via setPlatformFee()
    uint16 public constant DEFAULT_PLATFORM_FEE_BPS = 500;
    
    
    // ============================================================================
    // DEPLOYED CONTRACTS
    // ============================================================================
    
    StreamWallet public streamWalletImpl;
    StreamBeaconRegistry public streamRegistry;
    StreamWalletFactory public streamFactory;
    
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
        _deployImplementation();
        _deployRegistry();
        _deployFactory();
        _configureBeacon();
        _transferOwnership();
        _printSummary();
        
        vm.stopBroadcast();
    }
    
    
    // ============================================================================
    // DEPLOYMENT STEPS
    // ============================================================================
    
    /**
     * @notice STEP 1: Deploy StreamWallet implementation
     * @dev This is the logic contract that all proxies will delegate to
     *      It contains the actual business logic for:
     *      - Recording subscriptions (with automatic fee split)
     *      - Processing donations (with platform fee)
     *      - Withdrawing revenue (streamer only)
     *      - Tracking subscription status
     */
    function _deployImplementation() internal {
        console.log("STEP 1: Deploying StreamWallet Implementation");
        console.log("----------------------------------------------");
        
        // Deploy the implementation contract
        streamWalletImpl = new StreamWallet();
        console.log("StreamWallet Implementation:", address(streamWalletImpl));
        console.log("");
        
        console.log("This contract contains the logic for:");
        console.log("  - Subscription management (recordSubscription)");
        console.log("  - Donation processing (donate)");
        console.log("  - Revenue withdrawal (withdrawRevenue)");
        console.log("  - Automatic fee split to treasury");
        console.log("");
    }
    
    /**
     * @notice STEP 2: Deploy StreamBeaconRegistry
     * @dev Registry creates and manages the UpgradeableBeacon
     *      Only the registry owner (Safe multisig) can upgrade the implementation
     *      
     *      SECURITY: This contract MUST be owned by a Gnosis Safe
     *      Why? Because it controls upgrades for ALL streamer wallets!
     */
    function _deployRegistry() internal {
        console.log("STEP 2: Deploying StreamBeaconRegistry");
        console.log("---------------------------------------");
        
        // Deploy registry with deployer as temporary owner
        // We'll transfer to Safe later
        streamRegistry = new StreamBeaconRegistry(deployer);
        console.log("StreamBeaconRegistry:", address(streamRegistry));
        console.log("Temporary Owner:", deployer);
        console.log("Final Owner (will transfer):", treasury);
        console.log("");
        
        console.log("Registry responsibilities:");
        console.log("  - Creates UpgradeableBeacon (once)");
        console.log("  - Upgrades implementation (via Safe multisig)");
        console.log("  - Returns beacon address to factory");
        console.log("");
    }
    
    /**
     * @notice STEP 3: Deploy StreamWalletFactory
     * @dev Factory deploys BeaconProxy instances for each streamer
     *      It queries the registry to get the beacon address
     *      Then deploys proxies that delegate to the beacon's implementation
     *      
     *      Factory ownership: Can remain with deployer/backend
     *      Why? Factory only creates proxies, cannot upgrade implementations
     */
    function _deployFactory() internal {
        console.log("STEP 3: Deploying StreamWalletFactory");
        console.log("-------------------------------------");
        
        // Deploy factory with all required parameters
        streamFactory = new StreamWalletFactory(
            deployer,                    // Factory owner (can create wallets)
            address(streamRegistry),     // Registry reference (immutable)
            treasury,                    // Platform treasury (Safe multisig)
            DEFAULT_PLATFORM_FEE_BPS     // Platform fee (5%)
        );
        console.log("StreamWalletFactory:", address(streamFactory));
        console.log("Owner:", deployer);
        console.log("Registry (immutable):", address(streamRegistry));
        console.log("Treasury:", treasury);
        console.log("Platform Fee:", DEFAULT_PLATFORM_FEE_BPS, "bps (5%)");
        console.log("");
        
        console.log("Factory functions:");
        console.log("  - subscribeToStream(streamer, duration) [payable]");
        console.log("  - donateToStream(streamer, message) [payable]");
        console.log("  - deployWalletFor(streamer) [admin only]");
        console.log("");
        
        console.log("How it works:");
        console.log("  1. User calls subscribeToStream{value: 100 CHZ}(streamerA, 30days)");
        console.log("  2. Factory checks if streamerA has wallet → No");
        console.log("  3. Factory queries registry.getBeacon() → beacon address");
        console.log("  4. Factory deploys: new BeaconProxy(beacon, initData)");
        console.log("  5. Proxy initializes with streamer and treasury");
        console.log("  6. Factory forwards CHZ to proxy");
        console.log("  7. Proxy records subscription & splits payment");
        console.log("  8. Treasury gets 5%, streamer gets 95%");
        console.log("");
    }
    
    /**
     * @notice STEP 4: Configure beacon in registry
     * @dev This creates the UpgradeableBeacon and points it to our implementation
     *      After this step, factory can deploy proxies
     *      
     *      WHAT HAPPENS:
     *      1. Registry checks if beacon exists → No
     *      2. Registry creates: new UpgradeableBeacon(implementation, deployer)
     *      3. Registry stores beacon in state
     *      4. Emits BeaconCreated event
     */
    function _configureBeacon() internal {
        console.log("STEP 4: Configuring Beacon");
        console.log("--------------------------");
        
        // Create beacon pointing to implementation
        streamRegistry.setImplementation(address(streamWalletImpl));
        
        // Verify beacon was created
        address beaconAddr = streamRegistry.getBeacon();
        address currentImpl = streamRegistry.getImplementation();
        
        console.log("Beacon Address:", beaconAddr);
        console.log("Current Implementation:", currentImpl);
        console.log("Status: Beacon configured ✓");
        console.log("");
        
        console.log("Beacon is now ready! Factory can deploy proxies.");
        console.log("All proxies will point to this beacon.");
        console.log("Upgrading the beacon upgrades ALL proxies atomically.");
        console.log("");
    }
    
    /**
     * @notice STEP 5: Transfer registry ownership to Safe
     * @dev CRITICAL SECURITY STEP!
     *      Registry controls upgrades for ALL streamer wallets
     *      Must be owned by multisig, not single EOA
     *      
     *      The Safe multisig serves dual purposes:
     *      1. TREASURY: Receives all platform fees
     *      2. REGISTRY OWNER: Controls implementation upgrades
     *      
     *      After this:
     *      - Only Safe multisig can upgrade implementation
     *      - Safe receives all platform fees (treasury)
     *      - Deployer cannot upgrade anymore (security!)
     *      - Factory owner can still create wallets (safe operation)
     */
    function _transferOwnership() internal {
        console.log("STEP 5: Transferring Ownership to Safe");
        console.log("---------------------------------------");
        
        console.log("Transferring StreamBeaconRegistry...");
        console.log("  From:", deployer);
        console.log("  To:", treasury);
        
        // Transfer ownership to Safe
        streamRegistry.transferOwnership(treasury);
        
        console.log("Status: Ownership transferred ✓");
        console.log("");
        
        console.log("IMPORTANT:");
        console.log("  ✓ Registry owned by Safe multisig:", treasury);
        console.log("  ✓ Safe receives all platform fees (treasury)");
        console.log("  ✓ Only Safe can upgrade implementations");
        console.log("  ✓ Deployer can still create wallets via factory");
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
        console.log("CHILIZ-TV STREAMING SYSTEM DEPLOYMENT");
        console.log("=====================================");
        console.log("");
        console.log("Deployer:", deployer, "(pays gas only)");
        console.log("Safe/Treasury:", treasury, "(receives fees + owns registries)");
        console.log("Platform Fee:", DEFAULT_PLATFORM_FEE_BPS, "bps (5%)");
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
        console.log("StreamBeaconRegistry:", address(streamRegistry));
        console.log("  Owner:", treasury);
        console.log("  Beacon:", streamRegistry.getBeacon());
        console.log("StreamWalletFactory:", address(streamFactory));
        console.log("  Owner:", deployer);
        console.log("");
        
        console.log("NEXT STEPS:");
        console.log("----------");
        console.log("1. Verify contracts on block explorer");
        console.log("");
        console.log("2. Test creating a streamer wallet:");
        console.log("   # Subscribe to a stream with CHZ");
        console.log("   cast send", address(streamFactory));
        console.log("     'subscribeToStream(address,uint256)' --value <AMOUNT_IN_WEI>");
        console.log("     <STREAMER_ADDRESS> <DURATION_SECONDS>");
        console.log("");
        console.log("3. Check wallet was created:");
        console.log("   cast call", address(streamFactory));
        console.log("     'getWallet(address)(address)'");
        console.log("     <STREAMER_ADDRESS>");
        console.log("");
        
        console.log("UPGRADING (Safe multisig only):");
        console.log("-------------------------------");
        console.log("To upgrade StreamWallet implementation:");
        console.log("  1. Deploy new StreamWallet implementation");
        console.log("  2. Via Safe multisig: streamRegistry.setImplementation(newImpl)");
        console.log("  3. All existing streamer wallets upgrade automatically!");
        console.log("");
        
        console.log("=====================================");
    }
}
