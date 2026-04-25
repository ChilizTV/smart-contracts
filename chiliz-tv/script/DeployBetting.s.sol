// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";

import {BettingMatchFactory} from "../src/betting/BettingMatchFactory.sol";

/**
 * @title DeployBetting
 * @author ChilizTV
 * @notice Deployment script for the UUPS-based Multi-Sport Betting System.
 *         Deploys the `BettingMatchFactory` (which itself deploys the initial
 *         FootballMatch + BasketballMatch implementations in its constructor).
 *
 * POST-DEPLOY (required before any match is created):
 * ===================================================
 *  1. From factory OWNER:
 *       factory.setWiring(<LIQUIDITY_POOL>, <USDC>, <CHILIZ_SWAP_ROUTER>)
 *     Until this is called, `createFootballMatch` / `createBasketballMatch`
 *     revert with `WiringNotConfigured`.
 *
 *  2. From pool DEFAULT_ADMIN_ROLE holder:
 *       pool.grantRole(MATCH_AUTHORIZER_ROLE, <FACTORY>)
 *     The factory calls `pool.authorizeMatch(proxy)` atomically when it
 *     creates a match — without this role the whole match-creation tx
 *     reverts.
 *
 *  3. From ChilizSwapRouter owner (if not already set):
 *       swapRouter.setMatchFactory(<FACTORY>)
 *     Without this, every `placeBetWith*` reverts with
 *     `BettingMatchFactoryNotSet` (C-1 hardening — no silent forwards).
 *
 * USAGE:
 * ======
 *   export PRIVATE_KEY=0x...
 *   export RPC_URL=https://spicy-rpc.chiliz.com
 *   forge script script/DeployBetting.s.sol --rpc-url $RPC_URL --broadcast --verify
 */
contract DeployBetting is Script {

    BettingMatchFactory public factory;
    address public deployer;

    function run() external {
        deployer = msg.sender;

        vm.startBroadcast();
        _printHeader();
        _deployFactory();
        _printSummary();
        vm.stopBroadcast();
    }

    /**
     * @notice Deploy `BettingMatchFactory`. Football + basketball implementations
     *         are deployed internally by the factory's constructor.
     */
    function _deployFactory() internal {
        console.log("Deploying BettingMatchFactory");
        console.log("------------------------------");
        factory = new BettingMatchFactory();
        console.log("BettingMatchFactory:      ", address(factory));
        console.log("  Owner:                  ", deployer);
        console.log("  Football impl:          ", factory.footballImplementation());
        console.log("  Basketball impl:        ", factory.basketballImplementation());
        console.log("");
    }

    function _printHeader() internal view {
        console.log("=========================================");
        console.log("CHILIZ-TV MULTI-SPORT BETTING DEPLOYMENT");
        console.log("=========================================");
        console.log("Deployer:", deployer);
        console.log("");
    }

    function _printSummary() internal view {
        console.log("=========================================");
        console.log("DEPLOYMENT COMPLETE");
        console.log("=========================================");
        console.log("BettingMatchFactory:", address(factory));
        console.log("");

        console.log("POST-DEPLOYMENT WIRING (MANDATORY):");
        console.log("-----------------------------------");
        console.log("1) Configure the factory (factory owner):");
        console.log("   cast send", address(factory));
        console.log("     'setWiring(address,address,address)'");
        console.log("     <LIQUIDITY_POOL> <USDC> <CHILIZ_SWAP_ROUTER>");
        console.log("");
        console.log("2) Grant MATCH_AUTHORIZER_ROLE on the pool (pool admin):");
        console.log("   cast send <LIQUIDITY_POOL>");
        console.log("     'grantRole(bytes32,address)'");
        console.log("     $(cast keccak 'MATCH_AUTHORIZER_ROLE')", address(factory));
        console.log("");
        console.log("3) Register the factory on the swap router (router owner):");
        console.log("   cast send <CHILIZ_SWAP_ROUTER>");
        console.log("     'setMatchFactory(address)'", address(factory));
        console.log("");

        console.log("CREATE A FOOTBALL MATCH (atomic - wires pool + roles):");
        console.log("------------------------------------------------------");
        console.log("cast send", address(factory));
        console.log("  'createFootballMatch(string,address,address)'");
        console.log("  'Barcelona vs Real Madrid'  # match name");
        console.log("  <MATCH_OWNER>               # DEFAULT_ADMIN / ADMIN / PAUSER / ODDS_SETTER");
        console.log("  <ORACLE>                    # RESOLVER_ROLE holder");
        console.log("");

        console.log("CREATE A BASKETBALL MATCH:");
        console.log("--------------------------");
        console.log("cast send", address(factory));
        console.log("  'createBasketballMatch(string,address,address)'");
        console.log("  'Lakers vs Celtics'");
        console.log("  <MATCH_OWNER>");
        console.log("  <ORACLE>");
        console.log("");

        console.log("UPGRADING:");
        console.log("----------");
        console.log("Each match proxy is UUPS. Upgrade individually from DEFAULT_ADMIN:");
        console.log("  1. Deploy the new FootballMatch / BasketballMatch implementation.");
        console.log("  2. proxy.upgradeToAndCall(newImpl, '') from the match admin.");
        console.log("");
    }
}
