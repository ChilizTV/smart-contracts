// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";

// Betting system
import {BettingMatchFactory} from "../src/betting/BettingMatchFactory.sol";

// Streaming system
import {StreamWalletFactory} from "../src/streamer/StreamWalletFactory.sol";

// Unified swap router
import {ChilizSwapRouter} from "../src/swap/ChilizSwapRouter.sol";

// Payout escrow (treasury-backed payout fallback)
import {PayoutEscrow} from "../src/betting/PayoutEscrow.sol";

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
 *   USDT_ADDRESS     - USDT token address
 *
 * OPTIONAL:
 *   FAN_TOKEN        - Fan token address for StreamWalletFactory (default: address(0))
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
    PayoutEscrow public payoutEscrow;

    address public deployer;
    address public treasury;
    address public kayenRouter;
    address public wchz;
    address public usdtAddress;
    address public fanToken;
    uint16 public platformFeeBps;

    function run() external {
        deployer = msg.sender;
        _loadConfig();

        vm.startBroadcast();

        _printHeader();
        _deployBettingSystem();
        _deployStreamingSystem();
        _deploySwapRouter();
        _deployPayoutEscrow();
        _transferOwnership();
        _printSummary();
        _printPostDeploymentSteps();

        vm.stopBroadcast();
    }

    function _loadConfig() internal {
        treasury = vm.envAddress("SAFE_ADDRESS");
        kayenRouter = vm.envAddress("KAYEN_ROUTER");
        wchz = vm.envAddress("WCHZ_ADDRESS");
        usdtAddress = vm.envAddress("USDT_ADDRESS");

        require(treasury != address(0), "SAFE_ADDRESS required");
        require(kayenRouter != address(0), "KAYEN_ROUTER required");
        require(wchz != address(0), "WCHZ_ADDRESS required");
        require(usdtAddress != address(0), "USDT_ADDRESS required");

        try vm.envAddress("FAN_TOKEN") returns (address addr) {
            fanToken = addr;
        } catch {
            fanToken = address(0);
        }

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
            deployer, treasury, platformFeeBps, kayenRouter, fanToken, usdtAddress
        );
        console.log("StreamWalletFactory:", address(streamFactory));
        console.log("  Treasury:", treasury);
        console.log("  Platform Fee:", platformFeeBps, "bps");
        console.log("");
    }

    function _deploySwapRouter() internal {
        console.log("[3/4] CHILIZ SWAP ROUTER (unified)");
        console.log("===================================");
        swapRouter = new ChilizSwapRouter(
            kayenRouter, kayenRouter, usdtAddress, wchz, treasury, platformFeeBps
        );
        console.log("ChilizSwapRouter:", address(swapRouter));
        console.log("  USDT:", usdtAddress);
        console.log("  WCHZ:", wchz);
        console.log("  Treasury:", treasury);
        console.log("  Platform Fee:", platformFeeBps, "bps");
        console.log("");
    }

    function _deployPayoutEscrow() internal {
        console.log("[4/4] PAYOUT ESCROW");
        console.log("====================");
        payoutEscrow = new PayoutEscrow(usdtAddress, treasury);
        console.log("PayoutEscrow:", address(payoutEscrow));
        console.log("  USDT:", usdtAddress);
        console.log("  Owner (Safe):", treasury);
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
        console.log("USDT:", usdtAddress);
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
        console.log("PayoutEscrow:       ", address(payoutEscrow));
        console.log("=========================================");
        console.log("");
    }

    function _printPostDeploymentSteps() internal view {
        console.log("POST-DEPLOYMENT STEPS:");
        console.log("======================");
        console.log("1. For each BettingMatch proxy:");
        console.log("   a) cast send <MATCH> 'setUSDTToken(address)'", usdtAddress);
        console.log("   b) cast send <MATCH> 'grantRole(bytes32,address)' $(cast keccak 'SWAP_ROUTER_ROLE')", address(swapRouter));
        console.log("   c) cast send <MATCH> 'setPayoutEscrow(address)'", address(payoutEscrow));
        console.log("2. Authorize each match in the escrow (from Safe):");
        console.log("   cast send", address(payoutEscrow), "'authorizeMatch(address)' <MATCH>");
        console.log("3. Fund escrow with USDT (from Safe):");
        console.log("   Step A: cast send <USDT> 'approve(address,uint256)' <ESCROW> <AMOUNT>");
        console.log("   Escrow address:", address(payoutEscrow));
        console.log("   Step B: cast send", address(payoutEscrow), "'fund(uint256)' <AMOUNT>");
        console.log("4. Set fan token if needed:");
        console.log("   cast send", address(streamFactory), "'setFanToken(address)' <FAN_TOKEN>");
        console.log("=========================================");
    }
}
