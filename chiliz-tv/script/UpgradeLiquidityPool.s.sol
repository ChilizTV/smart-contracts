// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {LiquidityPool} from "../src/liquidity/LiquidityPool.sol";

/**
 * @title UpgradeLiquidityPool
 * @author ChilizTV
 * @notice Upgrades the LiquidityPool UUPS proxy to a new implementation.
 *
 *   1. Deploys a new LiquidityPool implementation.
 *   2. Calls `upgradeToAndCall(newImpl, "")` on the proxy.
 *      Caller MUST hold DEFAULT_ADMIN_ROLE on the proxy (admin key — NOT
 *      the treasury Safe).
 *
 * STORAGE-LAYOUT SAFETY CHECKLIST — run before every upgrade:
 * ==========================================================
 *   forge inspect src/liquidity/LiquidityPool.sol:LiquidityPool storage-layout
 *
 * Diff the output against the previously deployed layout. Valid changes:
 *   - Appending NEW slots before the `__gap` and shrinking `__gap` by the
 *     same amount.
 *   - Renaming variables (no storage impact).
 *   - Adding public getters / internal functions (no storage impact).
 *
 * Forbidden changes:
 *   - Reordering existing named slots.
 *   - Deleting named slots.
 *   - Changing the type of an existing named slot.
 *   - Growing `__gap` without shrinking other storage (changes total footprint).
 *
 * ENVIRONMENT VARIABLES (required):
 *   PRIVATE_KEY      - Admin key (holds DEFAULT_ADMIN_ROLE on proxy)
 *   RPC_URL          - Network RPC endpoint
 *   POOL_ADDRESS     - Deployed LiquidityPool proxy address
 *
 * OPTIONAL:
 *   DRY_RUN          - Set to "true" to deploy new impl + print the upgrade
 *                      tx, but skip the upgradeToAndCall call. Useful to
 *                      verify implementation address before the Safe signs.
 *
 * USAGE:
 *   forge script script/UpgradeLiquidityPool.s.sol \
 *     --rpc-url $RPC_URL --broadcast --verify -vvvv
 */
contract UpgradeLiquidityPool is Script {

    LiquidityPool public pool;
    address public newImpl;
    bool    public dryRun;

    function run() external {
        address poolAddr = vm.envAddress("POOL_ADDRESS");
        pool = LiquidityPool(poolAddr);
        dryRun = _envBool("DRY_RUN", false);

        vm.startBroadcast();

        _printHeader();
        _deployNewImplementation();
        if (!dryRun) _upgrade();
        _printSummary();

        vm.stopBroadcast();
    }

    // ══════════════════════════════════════════════════════════════════════════

    function _deployNewImplementation() internal {
        console.log("[1/2] Deploying new LiquidityPool implementation");
        console.log("=================================================");
        newImpl = address(new LiquidityPool());
        console.log("  New implementation:", newImpl);
        console.log("");
    }

    function _upgrade() internal {
        console.log("[2/2] Calling upgradeToAndCall on proxy");
        console.log("========================================");
        pool.upgradeToAndCall(newImpl, "");
        console.log("  upgraded", address(pool), "->", newImpl);
        console.log("");
    }

    function _printHeader() internal view {
        console.log("=========================================");
        console.log("CHILIZ-TV LIQUIDITY POOL UPGRADE");
        console.log("=========================================");
        console.log("Proxy:          ", address(pool));
        console.log("Caller:         ", msg.sender);
        console.log("Dry run:        ", dryRun ? "YES (upgradeToAndCall skipped)" : "no");
        console.log("Current treasury:", pool.treasury());
        console.log("=========================================");
        console.log("");
        console.log("Before broadcasting, verify storage-layout compatibility:");
        console.log("  forge inspect src/liquidity/LiquidityPool.sol:LiquidityPool storage-layout");
        console.log("");
    }

    function _printSummary() internal view {
        console.log("=========================================");
        console.log("UPGRADE COMPLETE");
        console.log("=========================================");
        console.log("Proxy:              ", address(pool));
        console.log("New implementation: ", newImpl);
        console.log("");
        console.log("POST-UPGRADE SANITY CHECKS:");
        console.log("  1. View function still returns sensible value:");
        console.log("     cast call <pool> 'totalAssets()(uint256)'");
        console.log("     cast call <pool> 'accruedTreasury()(uint256)'");
        console.log("  2. Role invariants intact:");
        console.log("     cast call <pool> 'treasury()(address)'");
        console.log("     cast call <pool> 'hasRole(bytes32,address)(bool)' \\");
        console.log("        $(cast --to-bytes32 0x0) <expected admin>");
        console.log("  3. Run the full forge test suite against a fork.");
        console.log("=========================================");
    }

    function _envBool(string memory key, bool defaultVal) internal view returns (bool) {
        try vm.envString(key) returns (string memory v) {
            return keccak256(bytes(v)) == keccak256(bytes("true"));
        } catch {
            return defaultVal;
        }
    }
}
