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
 *   2. Configure USDC on each BettingMatch proxy via setUSDCToken()
 *
 * ENVIRONMENT VARIABLES (required):
 * =================================
 *   PRIVATE_KEY      - Deployer private key
 *   KAYEN_ROUTER     - Kayen DEX MasterRouterV2 address
 *   WCHZ_ADDRESS     - Wrapped CHZ (WCHZ) token address
 *   USDC_ADDRESS     - USDC token address
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
    address public usdcAddress;
    address public treasury;
    uint16 public platformFeeBps;

    function run() external {
        deployer = msg.sender;

        // â”€â”€ Load required env vars â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
        kayenRouter = vm.envAddress("KAYEN_ROUTER");
        wchz = vm.envAddress("WCHZ_ADDRESS");
        usdcAddress = vm.envAddress("USDC_ADDRESS");
        treasury = vm.envAddress("SAFE_ADDRESS");

        // â”€â”€ Load optional env vars (with defaults) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
        try vm.envUint("PLATFORM_FEE_BPS") returns (uint256 fee) {
            platformFeeBps = uint16(fee);
        } catch {
            platformFeeBps = 500; // Default 5%
        }

        // â”€â”€ Validation â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
        require(kayenRouter != address(0), "KAYEN_ROUTER required");
        require(wchz != address(0), "WCHZ_ADDRESS required");
        require(usdcAddress != address(0), "USDC_ADDRESS required");
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
            usdcAddress,
            wchz,
            treasury,
            platformFeeBps
        );

        console.log("ChilizSwapRouter:", address(swapRouter));
        console.log("  Kayen Master Router:", kayenRouter);
        console.log("  Kayen Token Router:", kayenRouter);
        console.log("  USDC:", usdcAddress);
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
        console.log("USDC:", usdcAddress);
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
        console.log("   a) Set USDC token:");
        console.log("      cast send <MATCH_ADDRESS> 'setUSDCToken(address)'", usdcAddress);
        console.log("");
        console.log("   b) Grant SWAP_ROUTER_ROLE to ChilizSwapRouter:");
        console.log("      cast send <MATCH_ADDRESS> 'grantRole(bytes32,address)'");
        console.log("        $(cast keccak 'SWAP_ROUTER_ROLE')");
        console.log("       ", address(swapRouter));
        console.log("");
        console.log("2. ChilizSwapRouter streaming functions are ready to use immediately.");
        console.log("   Users call:");
        console.log("     donateWithCHZ{value: X}(streamer, message, minUSDCOut, deadline)");
        console.log("     donateWithToken(token, amount, streamer, message, minUSDCOut, deadline)");
        console.log("     donateWithUSDC(streamer, message, amount)");
        console.log("     subscribeWithCHZ{value: X}(streamer, duration, minUSDCOut, deadline)");
        console.log("     subscribeWithToken(token, amount, streamer, duration, minUSDCOut, deadline)");
        console.log("     subscribeWithUSDC(streamer, duration, amount)");
        console.log("");
        console.log("3. Betting functions:");
        console.log("   placeBetWithCHZ{value: X}(matchAddr, marketId, selection, minUSDCOut, deadline)");
        console.log("   placeBetWithToken(token, amount, matchAddr, marketId, selection, minUSDCOut, deadline)");
        console.log("   placeBetWithUSDC(matchAddr, marketId, selection, amount)");
        console.log("");
        console.log("=========================================");
    }
}
