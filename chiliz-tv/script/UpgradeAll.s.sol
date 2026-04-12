// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {BettingMatchFactory} from "../src/betting/BettingMatchFactory.sol";
import {FootballMatch} from "../src/betting/FootballMatch.sol";
import {BasketballMatch} from "../src/betting/BasketballMatch.sol";
import {StreamWalletFactory} from "../src/streamer/StreamWalletFactory.sol";
import {StreamWallet} from "../src/streamer/StreamWallet.sol";

/**
 * @title UpgradeAll
 * @author ChilizTV
 * @notice Combined upgrade script for the entire ChilizTV platform.
 *         Upgrades both the betting system (FootballMatch / BasketballMatch) and
 *         the streaming system (StreamWallet) in a single broadcast.
 *
 * ENVIRONMENT VARIABLES (required):
 *   PRIVATE_KEY              - Deployer private key
 *                              (must be factory owner AND hold DEFAULT_ADMIN_ROLE on match proxies)
 *   BETTING_FACTORY_ADDRESS  - Deployed BettingMatchFactory address
 *   STREAM_FACTORY_ADDRESS   - Deployed StreamWalletFactory address
 *
 * OPTIONAL:
 *   MATCH_PROXIES      - Comma-separated BettingMatch proxy addresses to upgrade
 *   STREAMER_WALLETS   - Comma-separated streamer addresses whose wallets to upgrade
 *   UPGRADE_FOOTBALL   - Set to "false" to skip new FootballMatch impl
 *   UPGRADE_BASKETBALL - Set to "false" to skip new BasketballMatch impl
 *
 * USAGE:
 *   forge script script/UpgradeAll.s.sol \
 *     --rpc-url $RPC_URL --broadcast --verify -vvvv
 */
contract UpgradeAll is Script {

    // ── Betting ───────────────────────────────────────────────────────────────
    BettingMatchFactory public bettingFactory;
    address public newFootballImpl;
    address public newBasketballImpl;
    bool public upgradeFootball;
    bool public upgradeBasketball;

    // ── Streaming ─────────────────────────────────────────────────────────────
    StreamWalletFactory public streamFactory;
    address public newStreamWalletImpl;

    address public deployer;

    function run() external {
        deployer = msg.sender;

        bettingFactory = BettingMatchFactory(vm.envAddress("BETTING_FACTORY_ADDRESS"));
        streamFactory  = StreamWalletFactory(vm.envAddress("STREAM_FACTORY_ADDRESS"));

        upgradeFootball   = _envBool("UPGRADE_FOOTBALL",   true);
        upgradeBasketball = _envBool("UPGRADE_BASKETBALL", true);

        vm.startBroadcast();

        _printHeader();

        // ── Betting upgrades ─────────────────────────────────────────────────
        _deployBettingImpls();
        _updateBettingFactory();
        _upgradeBettingProxies();

        // ── Streaming upgrades ───────────────────────────────────────────────
        _deployStreamingImpl();
        _updateStreamingFactory();
        _upgradeStreamingWallets();

        _printSummary();

        vm.stopBroadcast();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // BETTING
    // ══════════════════════════════════════════════════════════════════════════

    function _deployBettingImpls() internal {
        console.log("[1/6] Deploying betting implementations");
        console.log("========================================");

        if (upgradeFootball) {
            newFootballImpl = address(new FootballMatch());
            console.log("New FootballMatch impl:   ", newFootballImpl);
        } else {
            newFootballImpl = bettingFactory.footballImplementation();
            console.log("FootballMatch impl:        unchanged");
        }

        if (upgradeBasketball) {
            newBasketballImpl = address(new BasketballMatch());
            console.log("New BasketballMatch impl: ", newBasketballImpl);
        } else {
            newBasketballImpl = bettingFactory.basketballImplementation();
            console.log("BasketballMatch impl:      unchanged");
        }
        console.log("");
    }

    function _updateBettingFactory() internal {
        console.log("[2/6] Updating betting factory pointers");
        console.log("========================================");
        if (upgradeFootball) {
            bettingFactory.setFootballImplementation(newFootballImpl);
            console.log("bettingFactory.setFootballImplementation ->", newFootballImpl);
        }
        if (upgradeBasketball) {
            bettingFactory.setBasketballImplementation(newBasketballImpl);
            console.log("bettingFactory.setBasketballImplementation ->", newBasketballImpl);
        }
        console.log("");
    }

    function _upgradeBettingProxies() internal {
        console.log("[3/6] Upgrading existing betting proxies");
        console.log("=========================================");

        string memory raw;
        try vm.envString("MATCH_PROXIES") returns (string memory v) {
            raw = v;
        } catch {
            console.log("MATCH_PROXIES not set - skipping proxy upgrades.");
            console.log("");
            return;
        }

        address[] memory proxies = _parseAddresses(raw);
        console.log("Proxies:", proxies.length);

        for (uint256 i = 0; i < proxies.length; i++) {
            address proxy = proxies[i];
            BettingMatchFactory.SportType sport = bettingFactory.matchSportType(proxy);

            address impl = (sport == BettingMatchFactory.SportType.FOOTBALL)
                ? newFootballImpl
                : newBasketballImpl;

            if (sport == BettingMatchFactory.SportType.FOOTBALL && !upgradeFootball) {
                console.log("  [skip]", proxy);
                continue;
            }
            if (sport == BettingMatchFactory.SportType.BASKETBALL && !upgradeBasketball) {
                console.log("  [skip]", proxy);
                continue;
            }

            (bool ok,) = proxy.call(
                abi.encodeWithSignature("upgradeToAndCall(address,bytes)", impl, "")
            );
            if (ok) {
                console.log("  [ok]  ", proxy, "->", impl);
            } else {
                console.log("  [FAIL]", proxy, "(check DEFAULT_ADMIN_ROLE)");
            }
        }
        console.log("");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // STREAMING
    // ══════════════════════════════════════════════════════════════════════════

    function _deployStreamingImpl() internal {
        console.log("[4/6] Deploying StreamWallet implementation");
        console.log("============================================");
        newStreamWalletImpl = address(new StreamWallet());
        console.log("New StreamWallet impl:", newStreamWalletImpl);
        console.log("");
    }

    function _updateStreamingFactory() internal {
        console.log("[5/6] Updating streaming factory pointer");
        console.log("=========================================");
        streamFactory.setImplementation(newStreamWalletImpl);
        console.log("streamFactory.setImplementation ->", newStreamWalletImpl);
        console.log("");
    }

    function _upgradeStreamingWallets() internal {
        console.log("[6/6] Upgrading existing streamer wallets");
        console.log("=========================================");

        string memory raw;
        try vm.envString("STREAMER_WALLETS") returns (string memory v) {
            raw = v;
        } catch {
            console.log("STREAMER_WALLETS not set - skipping wallet upgrades.");
            console.log("");
            return;
        }

        address[] memory streamers = _parseAddresses(raw);
        console.log("Wallets:", streamers.length);

        for (uint256 i = 0; i < streamers.length; i++) {
            address streamer = streamers[i];
            address wallet = streamFactory.getWallet(streamer);

            if (wallet == address(0)) {
                console.log("  [skip] no wallet:", streamer);
                continue;
            }

            try streamFactory.upgradeWallet(streamer, newStreamWalletImpl) {
                console.log("  [ok]   wallet", wallet, "for streamer", streamer);
            } catch {
                console.log("  [FAIL] streamer", streamer, "(check factory owner)");
            }
        }
        console.log("");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // HELPERS
    // ══════════════════════════════════════════════════════════════════════════

    function _printHeader() internal view {
        console.log("=========================================");
        console.log("CHILIZ-TV FULL PLATFORM UPGRADE");
        console.log("=========================================");
        console.log("Deployer:", deployer);
        console.log("Betting factory: ", address(bettingFactory));
        console.log("Streaming factory:", address(streamFactory));
        console.log("=========================================");
        console.log("");
    }

    function _printSummary() internal view {
        console.log("=========================================");
        console.log("UPGRADE COMPLETE");
        console.log("=========================================");
        console.log("Betting:");
        console.log("  Football impl:   ", bettingFactory.footballImplementation());
        console.log("  Basketball impl: ", bettingFactory.basketballImplementation());
        console.log("Streaming:");
        console.log("  StreamWallet impl:", streamFactory.streamWalletImplementation());
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

    function _envBool(string memory key, bool defaultVal) internal view returns (bool) {
        try vm.envString(key) returns (string memory v) {
            return keccak256(bytes(v)) != keccak256(bytes("false"));
        } catch {
            return defaultVal;
        }
    }
}
