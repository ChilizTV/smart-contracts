// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {PayoutEscrow} from "../src/betting/PayoutEscrow.sol";

/**
 * @title DeployPayout
 * @author ChilizTV
 * @notice Deploy the shared PayoutEscrow that backstops ALL BettingMatch contracts.
 *         After deployment, authorize each match proxy individually via:
 *           PayoutEscrow.authorizeMatch(matchProxy, cap)
 *
 * ENVIRONMENT VARIABLES (required):
 *   PRIVATE_KEY     - Deployer private key
 *   SAFE_ADDRESS    - Gnosis Safe multisig (becomes escrow owner — funds/withdraws/whitelists)
 *   USDC_ADDRESS    - USDC token address on this network
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
        _printInstructions();

        vm.stopBroadcast();
    }

    function _loadConfig() internal {
        safeAddress = vm.envAddress("SAFE_ADDRESS");
        usdcAddress = vm.envAddress("USDC_ADDRESS");
        require(safeAddress != address(0), "SAFE_ADDRESS required");
        require(usdcAddress != address(0), "USDC_ADDRESS required");
    }

    function _deployEscrow() internal {
        escrow = new PayoutEscrow(usdcAddress, safeAddress);
        console.log("PayoutEscrow:", address(escrow));
        console.log("  USDC:", usdcAddress);
        console.log("  Owner (Safe):", safeAddress);
        console.log("");
    }

    function _printInstructions() internal view {
        console.log("==============================================");
        console.log("NEXT STEPS");
        console.log("==============================================");
        console.log("");
        console.log("1. Authorize each BettingMatch proxy (Safe owner):");
        console.log("   cast send", address(escrow));
        console.log("     'authorizeMatch(address,uint256)'");
        console.log("     <MATCH_PROXY> <CAP_IN_USDC_6_DECIMALS>");
        console.log("");
        console.log("2. Wire the escrow to each match (match admin):");
        console.log("   cast send <MATCH_PROXY> 'setPayoutEscrow(address)'", address(escrow));
        console.log("");
        console.log("3. Fund the escrow with USDC (from Safe):");
        console.log("   Step A: cast send <USDC> 'approve(address,uint256)' <ESCROW> <AMOUNT>");
        console.log("           escrow address:", address(escrow));
        console.log("   Step B: cast send", address(escrow), "'fund(uint256)' <AMOUNT>");
        console.log("");
        console.log("4. Monitor balances:");
        console.log("   cast call", address(escrow), "'availableBalance()'");
        console.log("   cast call", address(escrow), "'freeBalance()'");
        console.log("   cast call", address(escrow), "'totalAllocated()'");
        console.log("==============================================");
    }

    function _printHeader() internal view {
        console.log("==============================================");
        console.log("CHILIZ-TV PAYOUT ESCROW DEPLOYMENT");
        console.log("==============================================");
        console.log("Deployer:     ", deployer);
        console.log("Safe (Owner): ", safeAddress);
        console.log("USDC:         ", usdcAddress);
        console.log("==============================================");
        console.log("");
    }
}
