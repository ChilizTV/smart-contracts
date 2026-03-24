// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {PayoutEscrow} from "../src/betting/PayoutEscrow.sol";

/**
 * @title DeployPayout
 * @author ChilizTV
 * @notice Deploy a dedicated PayoutEscrow for a single BettingMatch proxy.
 *         Each match gets its own escrow — no shared pool, no whitelist.
 *
 * ENVIRONMENT VARIABLES (required):
 *   PRIVATE_KEY     - Deployer private key
 *   SAFE_ADDRESS    - Gnosis Safe multisig (becomes escrow owner, can fund/withdraw)
 *   USDC_ADDRESS    - USDC token address on this network
 *   MATCH_ADDRESS   - BettingMatch proxy address this escrow will serve
 *
 * USAGE:
 *   forge script script/DeployPayout.s.sol --rpc-url $RPC_URL --broadcast --verify -vvvv
 */
contract DeployPayout is Script {
    PayoutEscrow public escrow;

    address public deployer;
    address public safeAddress;
    address public usdcAddress;
    address public matchAddress;

    function run() external {
        deployer = msg.sender;
        _loadConfig();

        vm.startBroadcast();

        _printHeader();
        _deployEscrow();
        _printInstructions();

        vm.stopBroadcast();
    }

    function _loadConfig() internal {
        safeAddress  = vm.envAddress("SAFE_ADDRESS");
        usdcAddress  = vm.envAddress("USDC_ADDRESS");
        matchAddress = vm.envAddress("MATCH_ADDRESS");
        require(safeAddress  != address(0), "SAFE_ADDRESS required");
        require(usdcAddress  != address(0), "USDC_ADDRESS required");
        require(matchAddress != address(0), "MATCH_ADDRESS required");
    }

    function _deployEscrow() internal {
        escrow = new PayoutEscrow(usdcAddress, matchAddress, safeAddress);
        console.log("PayoutEscrow:", address(escrow));
        console.log("  USDC:", usdcAddress);
        console.log("  Authorized match:", matchAddress);
        console.log("  Owner (Safe):", safeAddress);
        console.log("");
    }

    function _printInstructions() internal view {
        console.log("==============================================");
        console.log("NEXT STEPS");
        console.log("==============================================");
        console.log("");
        console.log("1. Wire escrow to the match (match owner):");
        console.log("   cast send", matchAddress, "'setPayoutEscrow(address)'", address(escrow));
        console.log("");
        console.log("2. Fund the escrow with USDC (from Safe):");
        console.log("   Step A - approve USDC for escrow, then:");
        console.log("     cast send <ESCROW> 'fund(uint256)' <AMOUNT>");
        console.log("");
        console.log("3. Monitor funding deficit:");
        console.log("   cast call", matchAddress, "'getFundingDeficit()'");
        console.log("   cast call", address(escrow), "'availableBalance()'");
        console.log("==============================================");
    }

    function _printHeader() internal view {
        console.log("==============================================");
        console.log("CHILIZ-TV PAYOUT ESCROW DEPLOYMENT");
        console.log("==============================================");
        console.log("Deployer:     ", deployer);
        console.log("Safe (Owner): ", safeAddress);
        console.log("USDC:         ", usdcAddress);
        console.log("Match (auth): ", matchAddress);
        console.log("==============================================");
        console.log("");
    }
}
