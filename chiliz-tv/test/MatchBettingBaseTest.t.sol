// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/MatchHubBeaconFactory.sol"; // adapte le chemin si besoin
import "../src/SportBeaconRegistry.sol"; // adapte le chemin si besoin
import "../src/betting/FootballBetting.sol";
import "../src/MockERC20.sol";

contract MatchBettingBaseTest is Test {
    SportBeaconRegistry public registry;
    MatchHubBeaconFactory public factory;
    FootballBetting public footballImpl;

    bytes32 public constant SPORT_FOOTBALL = keccak256("FOOTBALL");

    address admin = makeAddr("ADMIN");
    address treasury = makeAddr("TREASURY");

    MockERC20 public token;

    function setUp() public {
        vm.startPrank(admin);
        registry = new SportBeaconRegistry(admin);
        footballImpl = new FootballBetting();
        registry.setSportImplementation(SPORT_FOOTBALL, address(footballImpl));
        factory = new MatchHubBeaconFactory(admin, address(registry));
        token = new MockERC20();
        vm.stopPrank();
    }

    function testInitialPoolZero() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256(abi.encodePacked("M_BASE_1"));
        uint64 cutoff = uint64(block.timestamp + 1 days);
        uint16 feeBps = 200;

        (address proxy, FootballBetting fb) = _createFootballMatch(admin, matchId, cutoff, feeBps, treasury);

        // total pool must be 0 before any bets
        assertEq(fb.totalPoolAmount(), 0);

        vm.stopPrank();
    }

    function _createFootballMatch(
        address owner_,
        bytes32 matchId_,
        uint64 cutoffTs_,
        uint16 feeBps_,
        address treasury_
    ) internal returns (address proxy, FootballBetting fb) {
        proxy = factory.createFootballMatch(owner_, address(token), matchId_, cutoffTs_, feeBps_, treasury_);
        fb = FootballBetting(payable(proxy));
    }
}
