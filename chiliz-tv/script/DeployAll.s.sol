// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";

// Betting system
import {BettingMatchFactory} from "../src/betting/BettingMatchFactory.sol";

// Streaming system
import {StreamWalletFactory} from "../src/streamer/StreamWalletFactory.sol";

// Unified swap router
import {ChilizSwapRouter} from "../src/swap/ChilizSwapRouter.sol";

// NOTE (2026-04-22): USDC custody lives in `LiquidityPool` (single shared
// ERC-4626 vault). Deploy it separately via `script/DeployLiquidityPool.s.sol`
// — it requires distinct admin and treasury addresses and is intentionally
// kept out of this all-in-one script. After pool + factory are deployed,
// wire each match via `pool.authorizeMatch(matchProxy)` from the admin key
// and `match.setLiquidityPool(pool)` from the match admin.

/**
 * @title DeployAll
 * @author ChilizTV
 * @notice Complete deployment script for the entire ChilizTV platform:
 *         Multi-Sport Betting + Streaming + Unified Swap Router
 *
 * DEPLOYED CONTRACTS:
 * ===================
 * 1. BettingMatchFactory  - Factory that deploys UUPS proxies for Football/Basketball matches
 * 2. StreamWalletFactory  - Factory that deploys UUPS StreamWallet proxies per streamer
 * 3. ChilizSwapRouter     - Unified swap router for betting + streaming
 *
 * ENVIRONMENT VARIABLES (required):
 * =================================
 *   PRIVATE_KEY      - Deployer private key
 *   RPC_URL          - Network RPC endpoint
 *   SAFE_ADDRESS     - Safe multisig address (treasury)
 *   KAYEN_ROUTER     - Kayen DEX MasterRouterV2 address
 *   WCHZ_ADDRESS     - Wrapped CHZ (WCHZ) token address
 *   USDC_ADDRESS     - USDC token address
 *
 * OPTIONAL:
 *   PLATFORM_FEE_BPS - Platform fee in basis points (default: 500 = 5%)
 *
 * USAGE:
 * ======
 *   forge script script/DeployAll.s.sol --rpc-url $RPC_URL --broadcast --verify -vvvv
 */
contract DeployAll is Script {

    BettingMatchFactory public bettingFactory;
    StreamWalletFactory public streamFactory;
    ChilizSwapRouter public swapRouter;

    address public deployer;
    address public treasury;
    address public kayenRouter;
    address public wchz;
    address public usdcAddress;
    uint16 public platformFeeBps;

    function run() external {
        deployer = msg.sender;
        _loadConfig();

        vm.startBroadcast();

        _printHeader();
        _deployBettingSystem();
        _deployStreamingSystem();
        _deploySwapRouter();
        _linkContracts();
        // NOTE: Ownership transfer skipped during deployment.
        // After all post-deployment setup (grantRole, setUSDCToken, etc.),
        // transfer ownership to Safe manually.
        _printSummary();
        _printPostDeploymentSteps();

        vm.stopBroadcast();
    }

    function _loadConfig() internal {
        treasury = vm.envAddress("SAFE_ADDRESS");
        kayenRouter = vm.envAddress("KAYEN_ROUTER");
        wchz = vm.envAddress("WCHZ_ADDRESS");
        usdcAddress = vm.envAddress("USDC_ADDRESS");

        require(treasury != address(0), "SAFE_ADDRESS required");
        require(kayenRouter != address(0), "KAYEN_ROUTER required");
        require(wchz != address(0), "WCHZ_ADDRESS required");
        require(usdcAddress != address(0), "USDC_ADDRESS required");

        try vm.envUint("PLATFORM_FEE_BPS") returns (uint256 fee) {
            platformFeeBps = uint16(fee);
        } catch {
            platformFeeBps = 500;
        }
    }

    function _deployBettingSystem() internal {
        console.log("[1/3] BETTING MATCH FACTORY");
        console.log("===========================");
        bettingFactory = new BettingMatchFactory();
        console.log("BettingMatchFactory:", address(bettingFactory));
        console.log("  Owner:", deployer);
        console.log("");
    }

    function _deployStreamingSystem() internal {
        console.log("[2/3] STREAM WALLET FACTORY");
        console.log("===========================");
        streamFactory = new StreamWalletFactory(
            deployer, treasury, platformFeeBps, kayenRouter, usdcAddress
        );
        console.log("StreamWalletFactory:", address(streamFactory));
        console.log("  Treasury:", treasury);
        console.log("  Platform Fee:", platformFeeBps, "bps");
        console.log("");
    }

    function _deploySwapRouter() internal {
        console.log("[3/3] CHILIZ SWAP ROUTER (unified)");
        console.log("===================================");
        swapRouter = new ChilizSwapRouter(
            kayenRouter, kayenRouter, usdcAddress, wchz, treasury, platformFeeBps
        );
        console.log("ChilizSwapRouter:", address(swapRouter));
        console.log("  USDC:", usdcAddress);
        console.log("  WCHZ:", wchz);
        console.log("  Treasury:", treasury);
        console.log("  Platform Fee:", platformFeeBps, "bps");
        console.log("");
    }

    function _linkContracts() internal {
        console.log("LINKING CONTRACTS");
        console.log("=================");
        streamFactory.setSwapRouter(address(swapRouter));
        console.log("StreamWalletFactory.setSwapRouter ->", address(swapRouter));
        swapRouter.setStreamWalletFactory(address(streamFactory));
        console.log("ChilizSwapRouter.setStreamWalletFactory ->", address(streamFactory));
        console.log("");
    }

    function _transferOwnership() internal {
        console.log("OWNERSHIP TRANSFER");
        console.log("==================");
        bettingFactory.transferOwnership(treasury);
        console.log("BettingMatchFactory -> Safe:", treasury);
        streamFactory.transferOwnership(treasury);
        console.log("StreamWalletFactory -> Safe:", treasury);
        swapRouter.transferOwnership(treasury);
        console.log("ChilizSwapRouter    -> Safe:", treasury);
        console.log("");
    }

    function _printHeader() internal view {
        console.log("=========================================");
        console.log("CHILIZ-TV COMPLETE PLATFORM DEPLOYMENT");
        console.log("=========================================");
        console.log("Deployer:", deployer);
        console.log("Treasury/Safe:", treasury);
        console.log("Kayen Router:", kayenRouter);
        console.log("WCHZ:", wchz);
        console.log("USDC:", usdcAddress);
        console.log("Platform Fee:", platformFeeBps, "bps");
        console.log("=========================================");
        console.log("");
    }

    function _printSummary() internal view {
        console.log("=========================================");
        console.log("DEPLOYMENT COMPLETE!");
        console.log("=========================================");
        console.log("DEPLOYED CONTRACTS:");
        console.log("BettingMatchFactory:", address(bettingFactory));
        console.log("StreamWalletFactory:", address(streamFactory));
        console.log("ChilizSwapRouter:   ", address(swapRouter));
        console.log("");
        console.log("MISSING (deploy separately):");
        console.log("  LiquidityPool    <- script/DeployLiquidityPool.s.sol");
        console.log("=========================================");
        console.log("");
    }

    function _printPostDeploymentSteps() internal view {
        console.log("POST-DEPLOYMENT STEPS:");
        console.log("======================");
        console.log("0. Deploy LiquidityPool (separate script -- requires distinct");
        console.log("   ADMIN_ADDRESS and SAFE_ADDRESS envs):");
        console.log("   forge script script/DeployLiquidityPool.s.sol --rpc-url $RPC_URL --broadcast");
        console.log("");
        console.log("1. For each BettingMatch proxy created by the factory:");
        console.log("   a) cast send <MATCH> 'setUSDCToken(address)'", usdcAddress);
        console.log("   b) cast send <MATCH> 'setLiquidityPool(address)' <LIQUIDITY_POOL>");
        console.log("   c) cast send <LIQUIDITY_POOL> 'authorizeMatch(address)' <MATCH>   # from ADMIN_ADDRESS");
        console.log("   d) cast send <MATCH> 'grantRole(bytes32,address)' $(cast keccak 'SWAP_ROUTER_ROLE')", address(swapRouter));
        console.log("   e) cast send <MATCH> 'grantRole(bytes32,address)' $(cast keccak 'RESOLVER_ROLE') <ORACLE>");
        console.log("   f) cast send <MATCH> 'setMaxAllowedOdds(uint32)' <cap>   # recommended");
        console.log("2. Seed LiquidityPool with USDC:");
        console.log("   Step A: cast send <USDC> 'approve(address,uint256)' <LIQUIDITY_POOL> <AMOUNT>");
        console.log("   Step B: cast send <LIQUIDITY_POOL> 'deposit(uint256,address)' <AMOUNT> <RECEIVER>");
        console.log("=========================================");
    }
}
