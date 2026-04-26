// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LiquidityPool} from "../src/liquidity/LiquidityPool.sol";

/**
 * @title DeployLiquidityPool
 * @author ChilizTV
 * @notice Deploys the ERC-4626 LiquidityPool as a UUPS proxy.
 *
 * ROLE SEPARATION (critical):
 * ===========================
 * The pool enforces a hard split between two authorities:
 *
 *   - ADMIN_ADDRESS: holds DEFAULT_ADMIN_ROLE + PAUSER_ROLE. Runs operational
 *                    setters (authorizeMatch, fees, caps, pause, UUPS upgrades).
 *                    Can NOT touch accruedTreasury or rotate `treasury`.
 *   - SAFE_ADDRESS:  stored in `treasury` state. Only address that can call
 *                    proposeTreasury / acceptTreasury / cancelTreasuryProposal
 *                    and withdrawTreasury. Can NOT authorize matches, set fees,
 *                    pause, or upgrade.
 *
 * These MUST be different addresses. The script reverts if you pass the same.
 *
 * ENVIRONMENT VARIABLES (required):
 * =================================
 *   PRIVATE_KEY               - Deployer private key
 *   RPC_URL                   - Network RPC endpoint
 *   SAFE_ADDRESS              - Treasury Safe multisig (will hold `treasury` state)
 *   ADMIN_ADDRESS             - Admin key (DEFAULT_ADMIN_ROLE + PAUSER_ROLE).
 *                               MUST be distinct from SAFE_ADDRESS.
 *   USDC_ADDRESS              - USDC token address (vault asset)
 *
 * OPTIONAL (have sensible defaults):
 * ==================================
 *   PROTOCOL_FEE_BPS          - Stake skim at bet placement (default 200 = 2%, max 1000)
 *   MAX_MARKET_LIAB_BPS       - Per-market liability cap (default 500  = 5%)
 *   MAX_MATCH_LIAB_BPS        - Per-match liability cap  (default 2000 = 20%)
 *   DEPOSIT_COOLDOWN_SECS     - LP withdrawal cooldown (default 3600 = 1h)
 *   MAX_BET_AMOUNT            - Pool-wide per-bet cap in USDC atomic units
 *                               (default 10_000e6 = 10k USDC; 0 disables).
 *                               Set via post-init setMaxBetAmount call.
 *
 * USAGE:
 * ======
 *   forge script script/DeployLiquidityPool.s.sol \
 *     --rpc-url $RPC_URL --broadcast --verify -vvvv
 */
contract DeployLiquidityPool is Script {

    LiquidityPool public pool;

    address public deployer;
    address public safeAddress;
    address public adminAddress;
    address public usdcAddress;

    uint16 public protocolFeeBps;
    uint16 public maxMarketLiabBps;
    uint16 public maxMatchLiabBps;
    uint48 public depositCooldownSecs;
    uint256 public maxBetAmount;

    function run() external {
        deployer = msg.sender;
        _loadConfig();

        vm.startBroadcast();

        _printHeader();
        _deployPool();
        _postInitSetters();
        _printSummary();

        vm.stopBroadcast();
    }

    // ══════════════════════════════════════════════════════════════════════════

    function _loadConfig() internal {
        safeAddress  = vm.envAddress("SAFE_ADDRESS");
        adminAddress = vm.envAddress("ADMIN_ADDRESS");
        usdcAddress  = vm.envAddress("USDC_ADDRESS");

        require(safeAddress  != address(0), "SAFE_ADDRESS required");
        require(adminAddress != address(0), "ADMIN_ADDRESS required");
        require(usdcAddress  != address(0), "USDC_ADDRESS required");
        require(
            safeAddress != adminAddress,
            "SAFE_ADDRESS and ADMIN_ADDRESS MUST be distinct"
        );

        protocolFeeBps      = uint16(_envUintOr("PROTOCOL_FEE_BPS",        200));
        maxMarketLiabBps    = uint16(_envUintOr("MAX_MARKET_LIAB_BPS",     500));
        maxMatchLiabBps     = uint16(_envUintOr("MAX_MATCH_LIAB_BPS",     2000));
        depositCooldownSecs = uint48(_envUintOr("DEPOSIT_COOLDOWN_SECS", 3_600));
        maxBetAmount        =        _envUintOr("MAX_BET_AMOUNT",     10_000e6);
    }

    function _deployPool() internal {
        console.log("[1/2] Deploying LiquidityPool");
        console.log("==============================");

        LiquidityPool impl = new LiquidityPool();
        console.log("  Implementation:", address(impl));

        bytes memory initData = abi.encodeWithSelector(
            LiquidityPool.initialize.selector,
            IERC20(usdcAddress),
            adminAddress,
            safeAddress,
            protocolFeeBps,
            maxMarketLiabBps,
            maxMatchLiabBps,
            depositCooldownSecs
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        pool = LiquidityPool(address(proxy));
        console.log("  Proxy:         ", address(pool));
        console.log("  Admin (DEFAULT_ADMIN_ROLE):", adminAddress);
        console.log("  Treasury (state var):      ", safeAddress);
        console.log("");
    }

    function _postInitSetters() internal view {
        console.log("[2/2] Post-init configuration");
        console.log("==============================");

        if (maxBetAmount != 0) {
            // setMaxBetAmount is DEFAULT_ADMIN_ROLE-gated — deployer will NOT
            // hold it; the admin address does. Emit a reminder instead of
            // attempting the call from the wrong key.
            console.log("  NOTE: `maxBetAmount` is DEFAULT_ADMIN_ROLE-gated.");
            console.log("  After deployment, call from ADMIN_ADDRESS:");
            console.log("    cast send <pool> 'setMaxBetAmount(uint256)'", maxBetAmount);
        } else {
            console.log("  maxBetAmount disabled (0)");
        }
        console.log("");
    }

    function _printHeader() internal view {
        console.log("=========================================");
        console.log("CHILIZ-TV LIQUIDITY POOL DEPLOYMENT");
        console.log("=========================================");
        console.log("Deployer:            ", deployer);
        console.log("USDC:                ", usdcAddress);
        console.log("Admin address:       ", adminAddress);
        console.log("Treasury (Safe):     ", safeAddress);
        console.log("Protocol fee (bps):  ", protocolFeeBps);
        console.log("Max market liab bps: ", maxMarketLiabBps);
        console.log("Max match liab bps:  ", maxMatchLiabBps);
        console.log("Withdraw cooldown s: ", depositCooldownSecs);
        console.log("Max bet amount:      ", maxBetAmount);
        console.log("=========================================");
        console.log("");
    }

    function _printSummary() internal view {
        console.log("=========================================");
        console.log("DEPLOYMENT COMPLETE");
        console.log("=========================================");
        console.log("LiquidityPool proxy:", address(pool));
        console.log("");
        console.log("POST-DEPLOYMENT STEPS:");
        console.log("======================");
        console.log("1. For each existing BettingMatch proxy, from ADMIN_ADDRESS:");
        console.log("   cast send <pool> 'authorizeMatch(address)' <matchProxy>");
        console.log("");
        console.log("2. On each BettingMatch, from match ADMIN_ROLE:");
        console.log("   cast send <match> 'setLiquidityPool(address)' <pool>");
        console.log("   cast send <match> 'setUSDCToken(address)'     <usdc>");
        console.log("   cast send <match> 'setMaxAllowedOdds(uint32)' <cap>  # recommended");
        console.log("");
        console.log("3. Optional: set per-bet cap from ADMIN_ADDRESS:");
        console.log("   cast send <pool> 'setMaxBetAmount(uint256)'", maxBetAmount);
        console.log("");
        console.log("4. Seed initial LP capital (can be Safe itself):");
        console.log("   cast send <usdc> 'approve(address,uint256)' <pool> <amount>");
        console.log("   cast send <pool> 'deposit(uint256,address)' <amount> <receiver>");
        console.log("=========================================");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // HELPERS
    // ══════════════════════════════════════════════════════════════════════════

    function _envUintOr(string memory key, uint256 defaultVal)
        internal
        view
        returns (uint256)
    {
        try vm.envUint(key) returns (uint256 v) { return v; }
        catch { return defaultVal; }
    }
}
