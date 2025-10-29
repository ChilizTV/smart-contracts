// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {MatchHub} from "../src/matchhub/MatchHub.sol";

contract MatchHubScript is Script {
    MatchHub public matchHub;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        matchHub = new MatchHub();

        vm.stopBroadcast();
    }
}
