// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {PayoutEscrow} from "../src/betting/PayoutEscrow.sol";

/**
 * @title DeployPayout
 * @author ChilizTV
 * @notice Deploy the PayoutEscrow contract and output Safe funding instructions
 *
 * ENVIRONMENT VARIABLES (required):
 *   PRIVATE_KEY   - Deployer private key
 *   SAFE_ADDRESS  - Gnosis Safe multisig (becomes escrow owner)
 *   USDC_ADDRESS  - USDC token address on this network
 *
 * OPTIONAL:
 *   MATCH_ADDRESSES - Comma-separated list of BettingMatch proxy addresses to authorize
 *
 * USAGE:
 *   forge script script/DeployPayout.s.sol --rpc-url $RPC_URL --broadcast --verify -vvvv
 */
contract DeployPayout is Script {
    PayoutEscrow public escrow;

    address public deployer;
    address public safeAddress;
    address public usdcAddress;

    function run() external {
        deployer = msg.sender;
        _loadConfig();

        vm.startBroadcast();

        _printHeader();
        _deployEscrow();
        _authorizeMatches();
        _printSafeFundingInstructions();

        vm.stopBroadcast();
    }

    function _loadConfig() internal {
        safeAddress = vm.envAddress("SAFE_ADDRESS");
        usdcAddress = vm.envAddress("USDC_ADDRESS");
        require(safeAddress != address(0), "SAFE_ADDRESS required");
        require(usdcAddress != address(0), "USDC_ADDRESS required");
    }

    function _deployEscrow() internal {
        console.log("[1/2] PAYOUT ESCROW");
        console.log("====================");
        escrow = new PayoutEscrow(usdcAddress, safeAddress);
        console.log("PayoutEscrow:", address(escrow));
        console.log("  USDC:", usdcAddress);
        console.log("  Owner (Safe):", safeAddress);
        console.log("");
    }

    function _authorizeMatches() internal view {
        console.log("[2/2] AUTHORIZE MATCHES");
        console.log("========================");

        // Try to read MATCH_ADDRESSES env var (comma-separated)
        try vm.envString("MATCH_ADDRESSES") returns (string memory matchList) {
            if (bytes(matchList).length > 0) {
                console.log("Note: MATCH_ADDRESSES provided but must be authorized by Safe owner.");
                console.log("The deployer is NOT the escrow owner (Safe is).");
                console.log("Use the Safe to call: escrow.authorizeMatch(matchAddress)");
                console.log("  Escrow:", address(escrow));
                console.log("  Matches to authorize:", matchList);
            }
        } catch {
            console.log("No MATCH_ADDRESSES provided.");
            console.log("After deployment, use Safe to authorize each BettingMatch proxy:");
            console.log("  escrow.authorizeMatch(<MATCH_PROXY_ADDRESS>)");
        }
        console.log("");
    }

    function _printSafeFundingInstructions() internal view {
        console.log("==============================================");
        console.log("SAFE FUNDING INSTRUCTIONS");
        console.log("==============================================");
        console.log("");
        console.log("Step 1: Authorize BettingMatch proxies (from Safe UI):");
        console.log("  Target:", address(escrow));
        console.log("  Function: authorizeMatch(address)");
        console.log("  Param: <BettingMatch proxy address>");
        console.log("");
        console.log("Step 2: Set escrow on each BettingMatch proxy:");
        console.log("  Target: <BettingMatch proxy address>");
        console.log("  Function: setPayoutEscrow(address)");
        console.log("  Param:", address(escrow));
        console.log("");
        console.log("Step 3: Fund the escrow with USDC (from Safe UI):");
        console.log("  Transaction 1 - Approve:");
        console.log("    Target:", usdcAddress);
        console.log("    Function: approve(address,uint256)");
        console.log("    Params:", address(escrow), "<FUNDING_AMOUNT>");
        console.log("");
        console.log("  Transaction 2 - Fund:");
        console.log("    Target:", address(escrow));
        console.log("    Function: fund(uint256)");
        console.log("    Param: <FUNDING_AMOUNT>");
        console.log("");
        console.log("Step 4: Monitor funding deficit:");
        console.log("  Call on each BettingMatch: getFundingDeficit() -> uint256");
        console.log("  Call on escrow: availableBalance() -> uint256");
        console.log("  Ensure: escrow.availableBalance() >= sum(match.getFundingDeficit())");
        console.log("==============================================");
    }

    function _printHeader() internal view {
        console.log("==============================================");
        console.log("CHILIZ-TV PAYOUT ESCROW DEPLOYMENT");
        console.log("==============================================");
        console.log("Deployer:", deployer);
        console.log("Safe (Owner):", safeAddress);
        console.log("USDC:", usdcAddress);
        console.log("==============================================");
        console.log("");
    }
}
