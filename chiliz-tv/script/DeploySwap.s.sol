// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {BettingSwapRouter} from "../src/betting/BettingSwapRouter.sol";
import {StreamSwapRouter} from "../src/streamer/StreamSwapRouter.sol";

/**
 * @title DeploySwap
 * @author ChilizTV
 * @notice Deployment script for swap routers (BettingSwapRouter + StreamSwapRouter)
 *
 * @dev Deploys:
 *   - BettingSwapRouter: Swaps native CHZ → USDC via Kayen DEX and places USDC bets
 *   - StreamSwapRouter:  Swaps native CHZ → USDC via Kayen DEX for donations/subscriptions
 *
 * PREREQUISITES:
 * ==============
 * These contracts must be deployed first:
 *   - BettingMatchFactory + at least one match proxy (for BettingSwapRouter)
 *   - StreamWalletFactory (for StreamSwapRouter, optional)
 *
 * After deploying BettingSwapRouter, you MUST:
 *   1. Grant SWAP_ROUTER_ROLE on each BettingMatch proxy
 *   2. Configure USDC on each BettingMatch proxy via setUSDCToken()
 *
 * NETWORK ADDRESSES:
 * ==================
 * Chiliz Spicy Testnet (88882):
 *   - Kayen MasterRouterV2: set KAYEN_ROUTER in .env
 *   - WCHZ:                 set WCHZ_ADDRESS in .env
 *   - USDC:                 set USDC_ADDRESS in .env
 *
 * Chiliz Mainnet (88888):
 *   - Kayen MasterRouterV2: set KAYEN_ROUTER in .env
 *   - WCHZ:                 set WCHZ_ADDRESS in .env
 *   - USDC:                 set USDC_ADDRESS in .env
 *
 * USAGE:
 * ======
 * Set environment variables:
 *   export PRIVATE_KEY=0x...
 *   export KAYEN_ROUTER=0x...       # Kayen MasterRouterV2 address
 *   export WCHZ_ADDRESS=0x...       # Wrapped CHZ address
 *   export USDC_ADDRESS=0x...       # USDC token address
 *   export SAFE_ADDRESS=0x...       # Treasury/Safe multisig
 *   export PLATFORM_FEE_BPS=500     # Platform fee (500 = 5%), for StreamSwapRouter
 *
 * Run:
 *   forge script script/DeploySwap.s.sol --rpc-url $RPC_URL --broadcast -vvvv
 */
contract DeploySwap is Script {
    // ============================================================================
    // DEPLOYED CONTRACTS
    // ============================================================================

    BettingSwapRouter public bettingSwapRouter;
    StreamSwapRouter public streamSwapRouter;

    address public deployer;
    address public kayenRouter;
    address public wchz;
    address public usdcAddress;
    address public treasury;
    uint16 public platformFeeBps;

    // ============================================================================
    // MAIN DEPLOYMENT
    // ============================================================================

    function run() external {
        deployer = msg.sender;

        // ── Load required env vars ──────────────────────────────────────────
        kayenRouter = vm.envAddress("KAYEN_ROUTER");
        wchz = vm.envAddress("WCHZ_ADDRESS");
        usdcAddress = vm.envAddress("USDC_ADDRESS");

        // ── Load optional env vars (with defaults) ──────────────────────────
        treasury = vm.envAddress("SAFE_ADDRESS");

        try vm.envUint("PLATFORM_FEE_BPS") returns (uint256 fee) {
            platformFeeBps = uint16(fee);
        } catch {
            platformFeeBps = 500; // Default 5%
        }

        // ── Validation ──────────────────────────────────────────────────────
        require(kayenRouter != address(0), "KAYEN_ROUTER required");
        require(wchz != address(0), "WCHZ_ADDRESS required");
        require(usdcAddress != address(0), "USDC_ADDRESS required");
        require(treasury != address(0), "SAFE_ADDRESS required");

        vm.startBroadcast();

        _printHeader();
        _deployBettingSwapRouter();
        _deployStreamSwapRouter();
        _printSummary();

        vm.stopBroadcast();
    }

    // ============================================================================
    // DEPLOYMENT STEPS
    // ============================================================================

    function _deployBettingSwapRouter() internal {
        console.log("Deploying BettingSwapRouter");
        console.log("---------------------------");

        bettingSwapRouter = new BettingSwapRouter(
            kayenRouter,
            kayenRouter,
            usdcAddress,
            wchz
        );

        console.log("BettingSwapRouter:", address(bettingSwapRouter));
        console.log("  Kayen Master Router:", kayenRouter);
        console.log("  Kayen Token Router:", kayenRouter);
        console.log("  USDC:", usdcAddress);
        console.log("  WCHZ:", wchz);
        console.log("");
    }

    function _deployStreamSwapRouter() internal {
        console.log("Deploying StreamSwapRouter");
        console.log("--------------------------");

        streamSwapRouter = new StreamSwapRouter(
            kayenRouter,  // masterRouter (native CHZ swaps)
            kayenRouter,  // tokenRouter (ERC20-to-ERC20 swaps)
            usdcAddress,
            wchz,
            treasury,
            platformFeeBps
        );

        console.log("StreamSwapRouter:", address(streamSwapRouter));
        console.log("  Kayen Master Router:", kayenRouter);
        console.log("  Kayen Token Router:", kayenRouter);
        console.log("  USDC:", usdcAddress);
        console.log("  WCHZ:", wchz);
        console.log("  Treasury:", treasury);
        console.log("  Platform Fee:", platformFeeBps, "bps");
        console.log("");
    }

    // ============================================================================
    // HELPERS
    // ============================================================================

    function _printHeader() internal view {
        console.log("=========================================");
        console.log("CHILIZ-TV SWAP ROUTERS DEPLOYMENT");
        console.log("=========================================");
        console.log("");
        console.log("Deployer:", deployer);
        console.log("Treasury:", treasury);
        console.log("Kayen Router:", kayenRouter);
        console.log("WCHZ:", wchz);
        console.log("USDC:", usdcAddress);
        console.log("");
        console.log("=========================================");
        console.log("");
    }

    function _printSummary() internal view {
        console.log("=========================================");
        console.log("DEPLOYMENT COMPLETE!");
        console.log("=========================================");
        console.log("");
        console.log("DEPLOYED CONTRACTS:");
        console.log("--------------------");
        console.log("BettingSwapRouter:", address(bettingSwapRouter));
        console.log("StreamSwapRouter:", address(streamSwapRouter));
        console.log("");
        console.log("=========================================");
        console.log("POST-DEPLOYMENT STEPS (REQUIRED):");
        console.log("=========================================");
        console.log("");
        console.log("1. For EACH BettingMatch proxy that should accept CHZ swaps:");
        console.log("   a) Set USDC token:");
        console.log("      cast send <MATCH_ADDRESS> 'setUSDCToken(address)' \\");
        console.log("        ", usdcAddress);
        console.log("");
        console.log("   b) Grant SWAP_ROUTER_ROLE to BettingSwapRouter:");
        console.log("      cast send <MATCH_ADDRESS> 'grantRole(bytes32,address)' \\");
        console.log("        $(cast keccak 'SWAP_ROUTER_ROLE') \\");
        console.log("        ", address(bettingSwapRouter));
        console.log("");
        console.log("2. StreamSwapRouter is ready to use immediately.");
        console.log("   Users call:");
        console.log("     donateWithCHZ{value: X}(streamer, message, minUSDCOut, deadline)");
        console.log("     donateWithToken(token, amount, streamer, message, minUSDCOut, deadline)");
        console.log("     donateWithUSDC(streamer, message, amount)");
        console.log("     subscribeWithCHZ{value: X}(streamer, duration, minUSDCOut, deadline)");
        console.log("     subscribeWithToken(token, amount, streamer, duration, minUSDCOut, deadline)");
        console.log("     subscribeWithUSDC(streamer, duration, amount)");
        console.log("");
        console.log("3. BettingSwapRouter usage:");
        console.log("   Users call:");
        console.log("     placeBetWithCHZ{value: X}(matchAddr, marketId, selection, minUSDCOut, deadline)");
        console.log("");
        console.log("=========================================");
        console.log("VERIFICATION COMMANDS:");
        console.log("=========================================");
        console.log("");
        console.log("# Verify BettingSwapRouter");
        console.log("cast call", address(bettingSwapRouter), "'router()'");
        console.log("cast call", address(bettingSwapRouter), "'usdc()'");
        console.log("cast call", address(bettingSwapRouter), "'wchz()'");
        console.log("");
        console.log("# Verify StreamSwapRouter");
        console.log("cast call", address(streamSwapRouter), "'masterRouter()'");
        console.log("cast call", address(streamSwapRouter), "'tokenRouter()'");
        console.log("cast call", address(streamSwapRouter), "'treasury()'");
        console.log("cast call", address(streamSwapRouter), "'platformFeeBps()'");
        console.log("");
    }
}
