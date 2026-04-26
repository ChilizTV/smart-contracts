// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BettingMatchFactory} from "../src/betting/BettingMatchFactory.sol";
import {FootballMatch} from "../src/betting/FootballMatch.sol";
import {BasketballMatch} from "../src/betting/BasketballMatch.sol";

/**
 * @title UpgradeBetting
 * @author ChilizTV
 * @notice Upgrade the betting system implementations.
 *
 *   1. Deploys a new FootballMatch implementation.
 *   2. Deploys a new BasketballMatch implementation.
 *   3. Updates the factory pointers (affects all FUTURE match deployments).
 *   4. Optionally upgrades every existing proxy listed in MATCH_PROXIES to the
 *      new implementation (UUPS upgradeToAndCall, requires DEFAULT_ADMIN_ROLE).
 *
 * ENVIRONMENT VARIABLES (required):
 *   PRIVATE_KEY        - Deployer private key (must hold DEFAULT_ADMIN_ROLE on proxies)
 *   FACTORY_ADDRESS    - Deployed BettingMatchFactory address
 *
 * OPTIONAL:
 *   MATCH_PROXIES      - Comma-separated list of proxy addresses to upgrade, e.g.
 *                        "0xABC...,0xDEF..."
 *                        If not set, only the factory pointers are updated.
 *   UPGRADE_FOOTBALL   - Set to "false" to skip deploying a new FootballMatch impl
 *   UPGRADE_BASKETBALL - Set to "false" to skip deploying a new BasketballMatch impl
 *
 * USAGE:
 *   forge script script/UpgradeBetting.s.sol \
 *     --rpc-url $RPC_URL --broadcast --verify -vvvv
 */
contract UpgradeBetting is Script {

    BettingMatchFactory public factory;

    address public deployer;
    address public newFootballImpl;
    address public newBasketballImpl;

    bool public upgradeFootball;
    bool public upgradeBasketball;

    function run() external {
        deployer = msg.sender;

        address factoryAddr = vm.envAddress("FACTORY_ADDRESS");
        factory = BettingMatchFactory(factoryAddr);

        // Flags — default true unless explicitly disabled
        upgradeFootball   = _envBool("UPGRADE_FOOTBALL",   true);
        upgradeBasketball = _envBool("UPGRADE_BASKETBALL", true);

        vm.startBroadcast();

        _printHeader();
        _deployNewImplementations();
        _updateFactory();
        _upgradeExistingProxies();
        _printSummary();

        vm.stopBroadcast();
    }

    // ══════════════════════════════════════════════════════════════════════════

    function _deployNewImplementations() internal {
        console.log("[1/3] Deploying new implementations");
        console.log("====================================");

        if (upgradeFootball) {
            newFootballImpl = address(new FootballMatch());
            console.log("New FootballMatch impl:   ", newFootballImpl);
        } else {
            newFootballImpl = factory.footballImplementation();
            console.log("FootballMatch impl:        unchanged (", newFootballImpl, ")");
        }

        if (upgradeBasketball) {
            newBasketballImpl = address(new BasketballMatch());
            console.log("New BasketballMatch impl: ", newBasketballImpl);
        } else {
            newBasketballImpl = factory.basketballImplementation();
            console.log("BasketballMatch impl:      unchanged (", newBasketballImpl, ")");
        }
        console.log("");
    }

    function _updateFactory() internal {
        console.log("[2/3] Updating factory implementation pointers");
        console.log("===============================================");

        if (upgradeFootball) {
            factory.setFootballImplementation(newFootballImpl);
            console.log("factory.setFootballImplementation ->", newFootballImpl);
        }
        if (upgradeBasketball) {
            factory.setBasketballImplementation(newBasketballImpl);
            console.log("factory.setBasketballImplementation ->", newBasketballImpl);
        }
        console.log("");
    }

    function _upgradeExistingProxies() internal {
        console.log("[3/3] Upgrading existing proxies");
        console.log("=================================");

        // Read comma-separated proxy list from env (optional)
        string memory raw;
        try vm.envString("MATCH_PROXIES") returns (string memory v) {
            raw = v;
        } catch {
            console.log("MATCH_PROXIES not set - skipping proxy upgrades.");
            console.log("To upgrade existing proxies, set MATCH_PROXIES=0xABC...,0xDEF...");
            console.log("");
            return;
        }

        address[] memory proxies = _parseAddresses(raw);
        console.log("Proxies to upgrade:", proxies.length);

        for (uint256 i = 0; i < proxies.length; i++) {
            address proxy = proxies[i];
            BettingMatchFactory.SportType sport = factory.matchSportType(proxy);

            address impl = (sport == BettingMatchFactory.SportType.FOOTBALL)
                ? newFootballImpl
                : newBasketballImpl;

            if (sport == BettingMatchFactory.SportType.FOOTBALL && !upgradeFootball) {
                console.log("  [skip] Football proxy (impl unchanged):", proxy);
                continue;
            }
            if (sport == BettingMatchFactory.SportType.BASKETBALL && !upgradeBasketball) {
                console.log("  [skip] Basketball proxy (impl unchanged):", proxy);
                continue;
            }

            // UUPS upgrade — caller must hold DEFAULT_ADMIN_ROLE on the proxy
            (bool ok,) = proxy.call(
                abi.encodeWithSignature("upgradeToAndCall(address,bytes)", impl, "")
            );
            if (ok) {
                console.log("  [ok]   upgraded proxy:", proxy, "->", impl);
            } else {
                console.log("  [FAIL] upgrade failed for proxy:", proxy);
                console.log("         Ensure deployer holds DEFAULT_ADMIN_ROLE on this proxy.");
            }
        }
        console.log("");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // HELPERS
    // ══════════════════════════════════════════════════════════════════════════

    function _printHeader() internal view {
        console.log("=========================================");
        console.log("CHILIZ-TV BETTING SYSTEM UPGRADE");
        console.log("=========================================");
        console.log("Deployer:", deployer);
        console.log("Factory: ", address(factory));
        console.log("  Current Football impl:   ", factory.footballImplementation());
        console.log("  Current Basketball impl: ", factory.basketballImplementation());
        console.log("=========================================");
        console.log("");
    }

    function _printSummary() internal view {
        console.log("=========================================");
        console.log("UPGRADE COMPLETE");
        console.log("=========================================");
        console.log("Factory Football impl:   ", factory.footballImplementation());
        console.log("Factory Basketball impl: ", factory.basketballImplementation());
        console.log("");
        console.log("POST-UPGRADE CHECKS:");
        console.log("  1. Verify new impl code is correct on-chain.");
        console.log("  2. For each upgraded proxy, call getMarketInfo() or a view");
        console.log("     function to confirm state is intact.");
        console.log("  3. Run your test suite against the new implementation.");
        console.log("=========================================");
    }

    /// @dev Parse a comma-separated string of addresses into an array
    function _parseAddresses(string memory raw) internal pure returns (address[] memory) {
        // Count commas to size the array
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
        // Skip leading "0x" if present
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

    function _envBool(string memory key, bool defaultVal) internal view returns (bool) {
        try vm.envString(key) returns (string memory v) {
            return keccak256(bytes(v)) != keccak256(bytes("false"));
        } catch {
            return defaultVal;
        }
    }
}
