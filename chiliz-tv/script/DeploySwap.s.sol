// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {ChilizSwapRouter} from "../src/swap/ChilizSwapRouter.sol";

/**
 * @title DeploySwap
 * @author ChilizTV
 * @notice Deployment script for the unified ChilizSwapRouter
 *
 * @dev Deploys a single swap router that handles both betting and streaming swaps.
 *
 * PREREQUISITES:
 * ==============
 * These contracts must be deployed first:
 *   - BettingMatchFactory + at least one match proxy (for betting flows)
 *   - StreamWalletFactory (for streaming flows, optional)
 *
 * After deploying ChilizSwapRouter, you MUST:
 *   1. Grant SWAP_ROUTER_ROLE on each BettingMatch proxy
 *   2. Configure USDT on each BettingMatch proxy via setUSDTToken()
 *
 * ENVIRONMENT VARIABLES (required):
 * =================================
 *   PRIVATE_KEY      - Deployer private key
 *   KAYEN_ROUTER     - Kayen DEX MasterRouterV2 address
 *   WCHZ_ADDRESS     - Wrapped CHZ (WCHZ) token address
 *   USDT_ADDRESS     - USDT token address
 *   SAFE_ADDRESS     - Treasury/Safe multisig
 *
 * OPTIONAL:
 *   PLATFORM_FEE_BPS - Platform fee in basis points (default: 500 = 5%)
 *
 * USAGE:
 * ======
 *   forge script script/DeploySwap.s.sol --rpc-url $RPC_URL --broadcast -vvvv
 */
contract DeploySwap is Script {
    ChilizSwapRouter public swapRouter;

    address public deployer;
    address public kayenRouter;
    address public wchz;
    address public usdtAddress;
    address public treasury;
    uint16 public platformFeeBps;

    function run() external {
        deployer = msg.sender;

        // ── Load required env vars ──────────────────────────────────────────
        kayenRouter = vm.envAddress("KAYEN_ROUTER");
        wchz = vm.envAddress("WCHZ_ADDRESS");
        usdtAddress = vm.envAddress("USDT_ADDRESS");
        treasury = vm.envAddress("SAFE_ADDRESS");

        // ── Load optional env vars (with defaults) ──────────────────────────
        try vm.envUint("PLATFORM_FEE_BPS") returns (uint256 fee) {
            platformFeeBps = uint16(fee);
        } catch {
            platformFeeBps = 500; // Default 5%
        }

        // ── Validation ──────────────────────────────────────────────────────
        require(kayenRouter != address(0), "KAYEN_ROUTER required");
        require(wchz != address(0), "WCHZ_ADDRESS required");
        require(usdtAddress != address(0), "USDT_ADDRESS required");
        require(treasury != address(0), "SAFE_ADDRESS required");

        vm.startBroadcast();

        _printHeader();
        _deploySwapRouter();
        _printSummary();

        vm.stopBroadcast();
    }

    function _deploySwapRouter() internal {
        console.log("Deploying ChilizSwapRouter (unified)");
        console.log("------------------------------------");

        swapRouter = new ChilizSwapRouter(
            kayenRouter,  // masterRouter (native CHZ swaps)
            kayenRouter,  // tokenRouter (ERC20-to-ERC20 swaps)
            usdtAddress,
            wchz,
            treasury,
            platformFeeBps
        );

        console.log("ChilizSwapRouter:", address(swapRouter));
        console.log("  Kayen Master Router:", kayenRouter);
        console.log("  Kayen Token Router:", kayenRouter);
        console.log("  USDT:", usdtAddress);
        console.log("  WCHZ:", wchz);
        console.log("  Treasury:", treasury);
        console.log("  Platform Fee:", platformFeeBps, "bps");
        console.log("");
    }

    function _printHeader() internal view {
        console.log("=========================================");
        console.log("CHILIZ-TV SWAP ROUTER DEPLOYMENT");
        console.log("=========================================");
        console.log("");
        console.log("Deployer:", deployer);
        console.log("Treasury:", treasury);
        console.log("Kayen Router:", kayenRouter);
        console.log("WCHZ:", wchz);
        console.log("USDT:", usdtAddress);
        console.log("Platform Fee:", platformFeeBps, "bps");
        console.log("");
        console.log("=========================================");
        console.log("");
    }

    function _printSummary() internal view {
        console.log("=========================================");
        console.log("DEPLOYMENT COMPLETE!");
        console.log("=========================================");
        console.log("");
        console.log("DEPLOYED:");
        console.log("  ChilizSwapRouter:", address(swapRouter));
        console.log("");
        console.log("=========================================");
        console.log("POST-DEPLOYMENT STEPS (REQUIRED):");
        console.log("=========================================");
        console.log("");
        console.log("1. For EACH BettingMatch proxy that should accept CHZ swap bets:");
        console.log("   a) Set USDT token:");
        console.log("      cast send <MATCH_ADDRESS> 'setUSDTToken(address)'", usdtAddress);
        console.log("");
        console.log("   b) Grant SWAP_ROUTER_ROLE to ChilizSwapRouter:");
        console.log("      cast send <MATCH_ADDRESS> 'grantRole(bytes32,address)'");
        console.log("        $(cast keccak 'SWAP_ROUTER_ROLE')");
        console.log("       ", address(swapRouter));
        console.log("");
        console.log("2. ChilizSwapRouter streaming functions are ready to use immediately.");
        console.log("   Users call:");
        console.log("     donateWithCHZ{value: X}(streamer, message, minUSDTOut, deadline)");
        console.log("     donateWithToken(token, amount, streamer, message, minUSDTOut, deadline)");
        console.log("     donateWithUSDT(streamer, message, amount)");
        console.log("     subscribeWithCHZ{value: X}(streamer, duration, minUSDTOut, deadline)");
        console.log("     subscribeWithToken(token, amount, streamer, duration, minUSDTOut, deadline)");
        console.log("     subscribeWithUSDT(streamer, duration, amount)");
        console.log("");
        console.log("3. Betting functions:");
        console.log("   placeBetWithCHZ{value: X}(matchAddr, marketId, selection, minUSDTOut, deadline)");
        console.log("   placeBetWithToken(token, amount, matchAddr, marketId, selection, minUSDTOut, deadline)");
        console.log("   placeBetWithUSDT(matchAddr, marketId, selection, amount)");
        console.log("");
        console.log("=========================================");
    }
}
