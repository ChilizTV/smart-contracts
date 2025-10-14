// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {MatchHub} from "../src/MatchHub.sol";

contract MatchTest is Test {
    MatchHub public matchHub;

    function setUp() public {
        matchHub = new MatchHub();
    }


}
