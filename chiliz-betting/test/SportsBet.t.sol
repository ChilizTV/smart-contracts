// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {SportsBet} from "../src/SportsBet.sol";

contract SportsBetTest is Test {
    SportsBet public sportsBet;
    
    function setUp() public {
        sportsBet = new SportsBet();
    }
}
