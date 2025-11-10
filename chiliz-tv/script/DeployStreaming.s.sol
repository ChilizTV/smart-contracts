// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

// Import streaming system contracts
import {StreamBeaconRegistry} from "../src/streamer/StreamBeaconRegistry.sol";
import {StreamWallet} from "../src/streamer/StreamWallet.sol";
import {StreamWalletFactory} from "../src/streamer/StreamWalletFactory.sol";
import {MockERC20} from "../src/MockERC20.sol";

/**
 * @title DeployStreaming
 * @author ChilizTV
 * @notice Focused deployment script for the Streaming System only
 * @dev Deploys StreamBeaconRegistry, StreamWallet implementation, and StreamWalletFactory
 * 
 * TREASURY ADDRESS: 0x74E2653e4e0Adf2cb9a56C879d4C28ad0294D677
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
 *   export PRIVATE_KEY=0x...           # Deployer private key
 *   export RPC_URL=https://...         # Network RPC endpoint
 *   export SAFE_ADDRESS=0x...          # Gnosis Safe multisig (REQUIRED)
 *   export TOKEN_ADDRESS=0x...         # ERC20 token (optional, will deploy mock)
 * 
 * Run:
 *   forge script script/DeployStreaming.s.sol --rpc-url $RPC_URL --broadcast --verify
 * 
 * POST-DEPLOYMENT:
 * ===============
 * 1. Verify contracts on block explorer
 * 2. Test subscription flow:
 *    - User approves token to factory
 *    - User calls factory.subscribeToStream(streamerAddress, amount, duration)
 *    - Factory deploys wallet (if first time) and records subscription
 * 3. Streamer can withdraw: wallet.withdrawRevenue(amount)
 */
contract DeployStreaming is Script {
    
    // ============================================================================
    // CONFIGURATION
    // ============================================================================
    
    /// @notice ChilizTV treasury address for receiving platform fees
    /// @dev This is DIFFERENT from the deployer address
    ///      Foundry doesn't support multisig deployment, so we use this address
    address public constant TREASURY = 0x74E2653e4e0Adf2cb9a56C879d4C28ad0294D677;
    
    /// @notice Default platform fee (5% = 500 basis points)
    /// @dev Can be changed later by factory owner via setPlatformFee()
    uint16 public constant DEFAULT_PLATFORM_FEE_BPS = 500;
    
    
    // ============================================================================
    // DEPLOYED CONTRACTS
    // ============================================================================
    
    StreamWallet public streamWalletImpl;
    StreamBeaconRegistry public streamRegistry;
    StreamWalletFactory public streamFactory;
    MockERC20 public mockToken;
    
    address public deployer;
    address public safeAddress;
    address public tokenAddress;
    
    
    // ============================================================================
    // MAIN DEPLOYMENT
    // ============================================================================
    
    function run() external {
        // Load configuration from environment
        _loadConfig();
        
        // Validate configuration
        require(safeAddress != address(0), "SAFE_ADDRESS must be set");
        
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
        
        // Deploy mock token if needed
        if (tokenAddress == address(0)) {
            mockToken = new MockERC20("ChilizTV Token", "CHTV");
            tokenAddress = address(mockToken);
            console.log("MockERC20 Token deployed (TEST ONLY):", tokenAddress);
            console.log("WARNING: Using mock token. Use real token in production!");
            console.log("");
        }
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
        console.log("Final Owner (will transfer):", safeAddress);
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
            tokenAddress,                // Payment token
            TREASURY,                    // Platform treasury
            DEFAULT_PLATFORM_FEE_BPS     // Platform fee (5%)
        );
        console.log("StreamWalletFactory:", address(streamFactory));
        console.log("Owner:", deployer);
        console.log("Registry (immutable):", address(streamRegistry));
        console.log("Token:", tokenAddress);
        console.log("Treasury:", TREASURY);
        console.log("Platform Fee:", DEFAULT_PLATFORM_FEE_BPS, "bps (5%)");
        console.log("");
        
        console.log("Factory functions:");
        console.log("  - subscribeToStream(streamer, amount, duration)");
        console.log("  - subscribeToStreamWithPermit(...) [EIP-2612]");
        console.log("  - donateToStream(streamer, amount, message)");
        console.log("  - donateToStreamWithPermit(...) [EIP-2612]");
        console.log("  - deployWalletFor(streamer) [admin only]");
        console.log("");
        
        console.log("How it works:");
        console.log("  1. User calls subscribeToStream(streamerA, 100, 30days)");
        console.log("  2. Factory checks if streamerA has wallet → No");
        console.log("  3. Factory queries registry.getBeacon() → beacon address");
        console.log("  4. Factory deploys: new BeaconProxy(beacon, initData)");
        console.log("  5. Proxy initializes with streamer, token, treasury, fee");
        console.log("  6. Factory transfers tokens to proxy");
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
     *      After this:
     *      - Only Safe multisig can upgrade implementation
     *      - Deployer cannot upgrade anymore (security!)
     *      - Factory owner can still create wallets (safe operation)
     */
    function _transferOwnership() internal {
        console.log("STEP 5: Transferring Ownership to Safe");
        console.log("---------------------------------------");
        
        console.log("Transferring StreamBeaconRegistry...");
        console.log("  From:", deployer);
        console.log("  To:", safeAddress);
        
        // Transfer ownership to Safe
        streamRegistry.transferOwnership(safeAddress);
        
        console.log("Status: Ownership transferred ✓");
        console.log("");
        
        console.log("IMPORTANT:");
        console.log("  ✓ Registry owned by Safe multisig");
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
        
        // Load Safe address (REQUIRED)
        try vm.envAddress("SAFE_ADDRESS") returns (address addr) {
            safeAddress = addr;
        } catch {
            console.log("ERROR: SAFE_ADDRESS environment variable not set!");
            console.log("Registry ownership cannot be transferred.");
            console.log("Please set SAFE_ADDRESS and re-run.");
            revert("SAFE_ADDRESS required");
        }
        
        // Load token address (optional)
        try vm.envAddress("TOKEN_ADDRESS") returns (address addr) {
            tokenAddress = addr;
        } catch {
            tokenAddress = address(0); // Will deploy mock
        }
    }
    
    function _printHeader() internal view {
        console.log("=====================================");
        console.log("CHILIZ-TV STREAMING SYSTEM DEPLOYMENT");
        console.log("=====================================");
        console.log("");
        console.log("Deployer:", deployer);
        console.log("Safe Address:", safeAddress);
        console.log("Treasury:", TREASURY);
        console.log("Token:", tokenAddress != address(0) ? tokenAddress : "Will deploy mock");
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
        console.log("  Owner:", safeAddress);
        console.log("  Beacon:", streamRegistry.getBeacon());
        console.log("StreamWalletFactory:", address(streamFactory));
        console.log("  Owner:", deployer);
        if (address(mockToken) != address(0)) {
            console.log("MockERC20 (TEST):", address(mockToken));
        }
        console.log("");
        
        console.log("NEXT STEPS:");
        console.log("----------");
        console.log("1. Verify contracts on block explorer");
        console.log("");
        console.log("2. Test creating a streamer wallet:");
        console.log("   # Subscribe to a stream");
        console.log("   cast send", address(streamFactory));
        console.log("     'subscribeToStream(address,uint256,uint256)'");
        console.log("     <STREAMER_ADDRESS> <AMOUNT> <DURATION_SECONDS>");
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
        
        console.log("USING EIP-2612 PERMIT (Better UX):");
        console.log("----------------------------------");
        console.log("Instead of approve + subscribe (2 tx):");
        console.log("  Use subscribeToStreamWithPermit (1 tx with signature)");
        console.log("  Same for donations: donateToStreamWithPermit");
        console.log("");
        
        console.log("=====================================");
    }
}
