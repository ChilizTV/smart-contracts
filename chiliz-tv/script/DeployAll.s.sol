// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Betting system
import {BettingMatchFactory} from "../src/betting/BettingMatchFactory.sol";

// Streaming system
import {StreamWalletFactory} from "../src/streamer/StreamWalletFactory.sol";

// Unified swap router
import {ChilizSwapRouter} from "../src/swap/ChilizSwapRouter.sol";

// Liquidity pool (USDC custody)
import {LiquidityPool} from "../src/liquidity/LiquidityPool.sol";

/**
 * @title DeployAll
 * @author ChilizTV
 * @notice One-shot deployment for the entire ChilizTV platform:
 *
 *           1. BettingMatchFactory  — Ownable factory that deploys ERC1967 UUPS
 *                                     proxies of FootballMatch / BasketballMatch.
 *           2. StreamWalletFactory  — Ownable factory that deploys ERC1967 UUPS
 *                                     proxies of StreamWallet.
 *           3. ChilizSwapRouter     — Stateless swap adapter (Ownable).
 *           4. LiquidityPool        — UUPS ERC-4626 vault behind ERC1967Proxy.
 *
 *         Plus all the wiring required to leave the system bet-ready in a single run:
 *           - swapRouter.setStreamWalletFactory(streamFactory)
 *           - swapRouter.setMatchFactory(bettingFactory)
 *           - streamFactory.setSwapRouter(swapRouter)
 *           - bettingFactory.setWiring(pool, usdc, swapRouter)
 *           - pool.grantRole(MATCH_AUTHORIZER_ROLE, bettingFactory)
 *
 *         After this script succeeds, the only steps left are (a) creating
 *         the first match via `bettingFactory.createFootballMatch(...)` and
 *         (b) seeding LP capital via `pool.deposit(usdc, lp)`.
 *
 * ROLE SEPARATION (critical):
 * ===========================
 * The pool enforces a hard split between admin and treasury:
 *
 *   - ADMIN_ADDRESS: holds DEFAULT_ADMIN_ROLE + PAUSER_ROLE on the pool.
 *                    Authorizes matches, sets caps/fees, can pause, can upgrade.
 *                    Cannot touch `accruedTreasury` or rotate the treasury.
 *   - SAFE_ADDRESS:  stored in `treasury` state. Sole address that can rotate
 *                    the treasury or pull `withdrawTreasury`. No operational
 *                    powers on the pool.
 *
 * These MUST be different addresses. The script reverts if you pass the same.
 *
 * The deployer briefly holds DEFAULT_ADMIN_ROLE on the pool during the wiring
 * phase (so it can grant MATCH_AUTHORIZER_ROLE to the factory), then transfers
 * admin to ADMIN_ADDRESS and renounces its own grants before exiting.
 *
 * ENVIRONMENT VARIABLES (required):
 * =================================
 *   PRIVATE_KEY      - Deployer private key
 *   RPC_URL          - Network RPC endpoint
 *   SAFE_ADDRESS     - Treasury Safe multisig (treasury on pool + streaming/router)
 *   ADMIN_ADDRESS    - Admin key for the LiquidityPool. MUST be != SAFE_ADDRESS.
 *   KAYEN_ROUTER     - Kayen DEX MasterRouterV2 address
 *   WCHZ_ADDRESS     - Wrapped CHZ (WCHZ) token address
 *   USDC_ADDRESS     - USDC token address
 *
 * OPTIONAL (sensible defaults):
 * =============================
 *   PLATFORM_FEE_BPS      - Streaming/router platform fee (default 500 = 5%)
 *   PROTOCOL_FEE_BPS      - Pool stake skim at bet placement (default 200 = 2%)
 *   MAX_MARKET_LIAB_BPS   - Per-market liability cap (default 500  = 5%  of NAV)
 *   MAX_MATCH_LIAB_BPS    - Per-match liability cap  (default 2000 = 20% of NAV)
 *   DEPOSIT_COOLDOWN_SECS - LP withdrawal cooldown (default 3600 = 1h)
 *   MAX_BET_AMOUNT        - Pool-wide per-bet cap, USDC atomic units
 *                           (default 10_000e6 = 10k USDC; 0 disables the cap)
 *
 * USAGE:
 * ======
 *   forge script script/DeployAll.s.sol --rpc-url $RPC_URL --broadcast --verify -vvvv
 */
contract DeployAll is Script {

    // ── Deployed contracts ────────────────────────────────────────────────────
    BettingMatchFactory public bettingFactory;
    StreamWalletFactory public streamFactory;
    ChilizSwapRouter    public swapRouter;
    LiquidityPool       public pool;
    address             public poolImplementation;

    // ── Config (loaded from env) ──────────────────────────────────────────────
    address public deployer;
    address public treasury;     // SAFE_ADDRESS — pool treasury + streaming/router fee sink
    address public adminAddress; // ADMIN_ADDRESS — pool DEFAULT_ADMIN_ROLE + PAUSER_ROLE
    address public kayenRouter;
    address public wchz;
    address public usdcAddress;

    uint16  public platformFeeBps;       // streaming + router
    uint16  public protocolFeeBps;       // pool
    uint16  public maxMarketLiabBps;     // pool
    uint16  public maxMatchLiabBps;      // pool
    uint48  public depositCooldownSecs;  // pool
    uint256 public maxBetAmount;         // pool

    function run() external {
        deployer = msg.sender;
        _loadConfig();

        vm.startBroadcast();

        _printHeader();
        _deployBettingFactory();
        _deployStreamingFactory();
        _deploySwapRouter();
        _deployLiquidityPool();
        _wirePlatform();
        _configurePool();
        _handOffPoolAdmin();
        _printSummary();
        _printPostDeploymentSteps();

        vm.stopBroadcast();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // CONFIG
    // ══════════════════════════════════════════════════════════════════════════

    function _loadConfig() internal {
        treasury     = vm.envAddress("SAFE_ADDRESS");
        adminAddress = vm.envAddress("ADMIN_ADDRESS");
        kayenRouter  = vm.envAddress("KAYEN_ROUTER");
        wchz         = vm.envAddress("WCHZ_ADDRESS");
        usdcAddress  = vm.envAddress("USDC_ADDRESS");

        require(treasury     != address(0),  "SAFE_ADDRESS required");
        require(adminAddress != address(0),  "ADMIN_ADDRESS required");
        require(kayenRouter  != address(0),  "KAYEN_ROUTER required");
        require(wchz         != address(0),  "WCHZ_ADDRESS required");
        require(usdcAddress  != address(0),  "USDC_ADDRESS required");
        require(
            adminAddress != treasury,
            "ADMIN_ADDRESS and SAFE_ADDRESS MUST be distinct (pool role separation)"
        );

        platformFeeBps      = uint16(_envUintOr("PLATFORM_FEE_BPS",        500));
        protocolFeeBps      = uint16(_envUintOr("PROTOCOL_FEE_BPS",        200));
        maxMarketLiabBps    = uint16(_envUintOr("MAX_MARKET_LIAB_BPS",     500));
        maxMatchLiabBps     = uint16(_envUintOr("MAX_MATCH_LIAB_BPS",     2000));
        depositCooldownSecs = uint48(_envUintOr("DEPOSIT_COOLDOWN_SECS", 3_600));
        maxBetAmount        =        _envUintOr("MAX_BET_AMOUNT",     10_000e6);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT
    // ══════════════════════════════════════════════════════════════════════════

    function _deployBettingFactory() internal {
        console.log("[1/4] BETTING MATCH FACTORY");
        console.log("===========================");
        bettingFactory = new BettingMatchFactory();
        console.log("BettingMatchFactory:", address(bettingFactory));
        console.log("  Owner:", deployer);
        console.log("  Football impl:   ", bettingFactory.footballImplementation());
        console.log("  Basketball impl: ", bettingFactory.basketballImplementation());
        console.log("");
    }

    function _deployStreamingFactory() internal {
        console.log("[2/4] STREAM WALLET FACTORY");
        console.log("===========================");
        streamFactory = new StreamWalletFactory(
            deployer, treasury, platformFeeBps, kayenRouter, usdcAddress
        );
        console.log("StreamWalletFactory:", address(streamFactory));
        console.log("  Owner:    ", deployer);
        console.log("  Treasury: ", treasury);
        console.log("  Fee bps:  ", platformFeeBps);
        console.log("  StreamWallet impl:", streamFactory.streamWalletImplementation());
        console.log("");
    }

    function _deploySwapRouter() internal {
        console.log("[3/4] CHILIZ SWAP ROUTER (unified)");
        console.log("===================================");
        swapRouter = new ChilizSwapRouter(
            kayenRouter, kayenRouter, usdcAddress, wchz, treasury, platformFeeBps
        );
        console.log("ChilizSwapRouter:", address(swapRouter));
        console.log("  Owner:    ", deployer);
        console.log("  USDC:     ", usdcAddress);
        console.log("  WCHZ:     ", wchz);
        console.log("  Treasury: ", treasury);
        console.log("  Fee bps:  ", platformFeeBps);
        console.log("");
    }

    /// @dev Deploys the LiquidityPool ERC1967 proxy with the **deployer** as
    ///      temporary DEFAULT_ADMIN_ROLE / PAUSER_ROLE. We need that during
    ///      the wiring phase so the deployer can `grantRole(MATCH_AUTHORIZER_ROLE,
    ///      bettingFactory)` without a separate ADMIN_ADDRESS transaction.
    ///      Admin is handed off to ADMIN_ADDRESS at the end of the script and
    ///      the deployer renounces its grants before exiting.
    function _deployLiquidityPool() internal {
        console.log("[4/4] LIQUIDITY POOL (UUPS / ERC-4626)");
        console.log("=======================================");

        LiquidityPool impl = new LiquidityPool();
        poolImplementation = address(impl);
        console.log("  Implementation:", poolImplementation);

        bytes memory initData = abi.encodeWithSelector(
            LiquidityPool.initialize.selector,
            IERC20(usdcAddress),
            deployer,           // temp admin (handed off below)
            treasury,           // permanent treasury (Safe)
            protocolFeeBps,
            maxMarketLiabBps,
            maxMatchLiabBps,
            depositCooldownSecs
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        pool = LiquidityPool(address(proxy));

        console.log("  Proxy:                     ", address(pool));
        console.log("  Treasury (state, Safe):    ", treasury);
        console.log("  Temp admin (deployer):     ", deployer);
        console.log("  Protocol fee bps:          ", protocolFeeBps);
        console.log("  Max market liab bps:       ", maxMarketLiabBps);
        console.log("  Max match  liab bps:       ", maxMatchLiabBps);
        console.log("  Withdraw cooldown (s):     ", depositCooldownSecs);
        console.log("");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // WIRING
    // ══════════════════════════════════════════════════════════════════════════

    /// @dev All the cross-contract wiring needed for a usable platform.
    ///      Order matters:
    ///        1. swap router learns about the streaming factory and the betting
    ///           factory (router refuses bets/streams until both pointers exist).
    ///        2. streaming factory learns about the swap router (the router
    ///           verifies factory→router back-pointer when it accepts the
    ///           registration; this is the H-1 atomic-wiring fix from the audit).
    ///        3. betting factory is told about pool/usdc/swap-router so every
    ///           future `createFootballMatch` can wire the new proxy in one tx.
    ///        4. pool grants MATCH_AUTHORIZER_ROLE to the betting factory so
    ///           `createFootballMatch` can call `pool.authorizeMatch(proxy)`
    ///           atomically inside the create flow.
    function _wirePlatform() internal {
        console.log("WIRING PLATFORM");
        console.log("===============");

        // Step 1+2: streaming factory <-> swap router
        streamFactory.setSwapRouter(address(swapRouter));
        console.log("  streamFactory.setSwapRouter      ->", address(swapRouter));

        swapRouter.setStreamWalletFactory(address(streamFactory));
        console.log("  swapRouter.setStreamWalletFactory ->", address(streamFactory));

        // Step 3: swap router learns about betting factory.
        // CRITICAL: without this every `placeBetWith*` reverts with
        // `BettingMatchFactoryNotSet`. The router will not silently forward
        // USDC to a match address it can't validate as factory-deployed.
        swapRouter.setMatchFactory(address(bettingFactory));
        console.log("  swapRouter.setMatchFactory       ->", address(bettingFactory));

        // Step 4: betting factory learns about pool / usdc / swap router. After
        // this call, every `createFootballMatch` / `createBasketballMatch` will:
        //   - deploy + initialize the match proxy
        //   - call `pool.authorizeMatch(proxy)`
        //   - call `match.setLiquidityPool(pool)`
        //   - call `match.setUSDCToken(usdc)`
        //   - grant SWAP_ROUTER_ROLE on match to swapRouter
        //   - grant RESOLVER_ROLE on match to oracle
        //   - hand over admin roles to the match owner
        // ...all in a single transaction (H-4 atomic match wiring).
        bettingFactory.setWiring(address(pool), usdcAddress, address(swapRouter));
        console.log("  bettingFactory.setWiring         -> pool/usdc/router");

        // Step 5: pool grants MATCH_AUTHORIZER_ROLE to the betting factory.
        // Without this the factory's in-create `pool.authorizeMatch(proxy)` call
        // reverts and the whole create flow fails. Deployer holds DEFAULT_ADMIN_ROLE
        // on the pool right now (we handed it the temp admin during init), so
        // this grant succeeds from the broadcast key.
        pool.grantRole(pool.MATCH_AUTHORIZER_ROLE(), address(bettingFactory));
        console.log("  pool.grantRole(MATCH_AUTHORIZER_ROLE, bettingFactory) [granted]");

        console.log("");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // POOL POST-INIT CONFIG
    // ══════════════════════════════════════════════════════════════════════════

    function _configurePool() internal {
        console.log("CONFIGURING POOL");
        console.log("================");
        if (maxBetAmount != 0) {
            // setMaxBetAmount is DEFAULT_ADMIN_ROLE-gated. Deployer still holds
            // it at this point (the handoff happens after this call), so it works.
            pool.setMaxBetAmount(maxBetAmount);
            console.log("  pool.setMaxBetAmount ->", maxBetAmount);
        } else {
            console.log("  maxBetAmount disabled (0)");
        }
        console.log("");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ADMIN HANDOFF
    // ══════════════════════════════════════════════════════════════════════════

    /// @dev Grant the real admin (ADMIN_ADDRESS) DEFAULT_ADMIN_ROLE + PAUSER_ROLE
    ///      on the pool, then renounce both from the deployer. After this
    ///      function returns, the deployer has zero permissions on the pool.
    ///      The factory ownerships (BettingMatchFactory / StreamWalletFactory)
    ///      and the swap router are intentionally left with the deployer — those
    ///      are operational keys (createFootballMatch etc. are routine), and
    ///      requiring a Safe multisig per match would break the UX. Transfer
    ///      them to the Safe later if and when you decide to.
    function _handOffPoolAdmin() internal {
        console.log("HANDING OFF POOL ADMIN");
        console.log("======================");

        bytes32 adminRole  = pool.DEFAULT_ADMIN_ROLE();
        bytes32 pauserRole = pool.PAUSER_ROLE();

        // Grant the real admin first — order matters: if we renounced before
        // granting, no one would hold DEFAULT_ADMIN_ROLE and the pool would be
        // permanently uncontrollable.
        pool.grantRole(adminRole,  adminAddress);
        pool.grantRole(pauserRole, adminAddress);
        console.log("  granted DEFAULT_ADMIN_ROLE + PAUSER_ROLE to:", adminAddress);

        // Now renounce the deployer's grants. AccessControl.renounceRole
        // requires `account == _msgSender()`, so this is the only safe path.
        pool.renounceRole(pauserRole, deployer);
        pool.renounceRole(adminRole,  deployer);
        console.log("  renounced deployer's pool roles");

        console.log("");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // OUTPUT
    // ══════════════════════════════════════════════════════════════════════════

    function _printHeader() internal view {
        console.log("=========================================");
        console.log("CHILIZ-TV COMPLETE PLATFORM DEPLOYMENT");
        console.log("=========================================");
        console.log("Deployer:        ", deployer);
        console.log("Treasury (Safe): ", treasury);
        console.log("Admin (pool):    ", adminAddress);
        console.log("Kayen Router:    ", kayenRouter);
        console.log("WCHZ:            ", wchz);
        console.log("USDC:            ", usdcAddress);
        console.log("Platform fee bps:", platformFeeBps);
        console.log("Protocol fee bps:", protocolFeeBps);
        console.log("=========================================");
        console.log("");
    }

    function _printSummary() internal view {
        console.log("=========================================");
        console.log("DEPLOYMENT COMPLETE");
        console.log("=========================================");
        console.log("BettingMatchFactory: ", address(bettingFactory));
        console.log("StreamWalletFactory: ", address(streamFactory));
        console.log("ChilizSwapRouter:    ", address(swapRouter));
        console.log("LiquidityPool (impl):", poolImplementation);
        console.log("LiquidityPool (proxy):", address(pool));
        console.log("=========================================");
        console.log("");
    }

    function _printPostDeploymentSteps() internal view {
        console.log("POST-DEPLOYMENT STEPS:");
        console.log("======================");
        console.log("All cross-contract wiring is done. Remaining work:");
        console.log("");
        console.log("1. Create your first match (factory owner only):");
        console.log("   cast send <BETTING_FACTORY> \\");
        console.log("     'createFootballMatch(string,address,address)' \\");
        console.log("     <NAME> <MATCH_OWNER> <ORACLE>");
        console.log("");
        console.log("   This single tx deploys the proxy, authorizes it on the");
        console.log("   pool, sets USDC/pool/swap-router on the match, grants");
        console.log("   RESOLVER_ROLE to the oracle, and hands match admin to");
        console.log("   <MATCH_OWNER>.");
        console.log("");
        console.log("2. (Optional) cap the per-match odds:");
        console.log("   cast send <MATCH> 'setMaxAllowedOdds(uint32)' <cap>");
        console.log("");
        console.log("3. Seed initial LP capital. Anyone can deposit; the");
        console.log("   treasury Safe is a sensible first depositor:");
        console.log("   cast send <USDC> 'approve(address,uint256)' <POOL> <AMOUNT>");
        console.log("   cast send <POOL> 'deposit(uint256,address)' <AMOUNT> <RECEIVER>");
        console.log("");
        console.log("4. (Optional) transfer factory + router ownership to the Safe");
        console.log("   if you decide operational ownership should live there.");
        console.log("   Leaving them with the deployer is fine for routine ops.");
        console.log("=========================================");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // HELPERS
    // ══════════════════════════════════════════════════════════════════════════

    function _envUintOr(string memory key, uint256 defaultVal)
        internal
        view
        returns (uint256)
    {
        try vm.envUint(key) returns (uint256 v) { return v; }
        catch { return defaultVal; }
    }
}
