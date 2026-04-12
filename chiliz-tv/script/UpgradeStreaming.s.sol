// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {StreamWalletFactory} from "../src/streamer/StreamWalletFactory.sol";
import {StreamWallet} from "../src/streamer/StreamWallet.sol";

/**
 * @title UpgradeStreaming
 * @author ChilizTV
 * @notice Upgrade the StreamWallet implementation for the streaming system.
 *
 *   1. Deploys a new StreamWallet implementation.
 *   2. Updates the factory pointer (affects all FUTURE wallet deployments).
 *   3. Optionally upgrades every existing streamer wallet listed in STREAMER_WALLETS
 *      via StreamWalletFactory.upgradeWallet() (factory owner must call this).
 *
 * ENVIRONMENT VARIABLES (required):
 *   PRIVATE_KEY        - Deployer private key (must be factory owner)
 *   FACTORY_ADDRESS    - Deployed StreamWalletFactory address
 *
 * OPTIONAL:
 *   STREAMER_WALLETS   - Comma-separated list of STREAMER addresses (not wallet addresses)
 *                        whose wallets should be upgraded, e.g. "0xABC...,0xDEF..."
 *                        If not set, only the factory pointer is updated.
 *
 * USAGE:
 *   forge script script/UpgradeStreaming.s.sol \
 *     --rpc-url $RPC_URL --broadcast --verify -vvvv
 */
contract UpgradeStreaming is Script {

    StreamWalletFactory public factory;

    address public deployer;
    address public newStreamWalletImpl;

    function run() external {
        deployer = msg.sender;

        address factoryAddr = vm.envAddress("FACTORY_ADDRESS");
        factory = StreamWalletFactory(factoryAddr);

        vm.startBroadcast();

        _printHeader();
        _deployNewImplementation();
        _updateFactory();
        _upgradeExistingWallets();
        _printSummary();

        vm.stopBroadcast();
    }

    // ══════════════════════════════════════════════════════════════════════════

    function _deployNewImplementation() internal {
        console.log("[1/3] Deploying new StreamWallet implementation");
        console.log("================================================");
        newStreamWalletImpl = address(new StreamWallet());
        console.log("New StreamWallet impl:", newStreamWalletImpl);
        console.log("");
    }

    function _updateFactory() internal {
        console.log("[2/3] Updating factory implementation pointer");
        console.log("=============================================");
        factory.setImplementation(newStreamWalletImpl);
        console.log("factory.setImplementation ->", newStreamWalletImpl);
        console.log("");
    }

    function _upgradeExistingWallets() internal {
        console.log("[3/3] Upgrading existing streamer wallets");
        console.log("=========================================");

        string memory raw;
        try vm.envString("STREAMER_WALLETS") returns (string memory v) {
            raw = v;
        } catch {
            console.log("STREAMER_WALLETS not set - skipping wallet upgrades.");
            console.log("To upgrade existing wallets, set STREAMER_WALLETS=0xSTREAMER1,0xSTREAMER2");
            console.log("");
            return;
        }

        address[] memory streamers = _parseAddresses(raw);
        console.log("Wallets to upgrade:", streamers.length);

        for (uint256 i = 0; i < streamers.length; i++) {
            address streamer = streamers[i];
            address wallet = factory.getWallet(streamer);

            if (wallet == address(0)) {
                console.log("  [skip] No wallet found for streamer:", streamer);
                continue;
            }

            // upgradeWallet calls upgradeToAndCall on the proxy via the factory
            // (factory is the authorized upgrader per _authorizeUpgrade in StreamWallet)
            try factory.upgradeWallet(streamer, newStreamWalletImpl) {
                console.log("  [ok]   upgraded wallet:", wallet);
                console.log("         streamer:", streamer);
            } catch {
                console.log("  [FAIL] upgrade failed for streamer:", streamer);
                console.log("         Ensure deployer is factory owner.");
            }
        }
        console.log("");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // HELPERS
    // ══════════════════════════════════════════════════════════════════════════

    function _printHeader() internal view {
        console.log("=========================================");
        console.log("CHILIZ-TV STREAMING SYSTEM UPGRADE");
        console.log("=========================================");
        console.log("Deployer:", deployer);
        console.log("Factory: ", address(factory));
        console.log("  Current StreamWallet impl:", factory.streamWalletImplementation());
        console.log("=========================================");
        console.log("");
    }

    function _printSummary() internal view {
        console.log("=========================================");
        console.log("UPGRADE COMPLETE");
        console.log("=========================================");
        console.log("Factory StreamWallet impl:", factory.streamWalletImplementation());
        console.log("");
        console.log("POST-UPGRADE CHECKS:");
        console.log("  1. Verify new impl code is correct on-chain.");
        console.log("  2. Call getWallet(streamer) and check wallet.totalRevenue()");
        console.log("     to confirm state is intact on upgraded wallets.");
        console.log("  3. Run your test suite against the new implementation.");
        console.log("=========================================");
    }

    function _parseAddresses(string memory raw) internal pure returns (address[] memory) {
        uint256 count = 1;
        bytes memory b = bytes(raw);
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == ",") count++;
        }

        address[] memory addrs = new address[](count);
        uint256 idx;
        uint256 start;
        for (uint256 i = 0; i <= b.length; i++) {
            if (i == b.length || b[i] == ",") {
                bytes memory slice = new bytes(i - start);
                for (uint256 j = 0; j < slice.length; j++) {
                    slice[j] = b[start + j];
                }
                addrs[idx++] = _parseAddr(string(slice));
                start = i + 1;
            }
        }
        return addrs;
    }

    function _parseAddr(string memory s) internal pure returns (address) {
        bytes memory b = bytes(s);
        uint256 result;
        uint256 start = (b.length >= 2 && b[0] == "0" && (b[1] == "x" || b[1] == "X")) ? 2 : 0;
        for (uint256 i = start; i < b.length; i++) {
            result <<= 4;
            uint8 c = uint8(b[i]);
            if (c >= 48 && c <= 57)       result |= c - 48;
            else if (c >= 65 && c <= 70)  result |= c - 55;
            else if (c >= 97 && c <= 102) result |= c - 87;
        }
        return address(uint160(result));
    }
}
