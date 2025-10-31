// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/matchhub/MatchHubBeaconFactory.sol";
import "../src/SportBeaconRegistry.sol";
import "../src/betting/UFCBetting.sol";
import "./mocks/MockV3Aggregator.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract UFCBeaconRegistryTest is Test {

    SportBeaconRegistry public registry;
    MatchHubBeaconFactory public factory;

    UFCBetting public ufcImpl;

    bytes32 public constant SPORT_UFC = keccak256("UFC");

    address admin = makeAddr("ADMIN");
    address treasury = makeAddr("TREASURY");
    address public user1 = makeAddr("USER1");
    address public user2 = makeAddr("USER2");

    MockV3Aggregator public priceFeed;
    uint256 constant MIN_BET_USD = 5e8;

    function setUp() public {
        // Reset timestamp to a known value for consistent testing
        vm.warp(1000000); // Start at a reasonable timestamp
        
        vm.startPrank(admin);
        
        // Deploy mock price feed first: CHZ/USD = $0.10 (10 cents per CHZ)
        priceFeed = new MockV3Aggregator(8, 10e6); // 8 decimals, $0.10
        
        // Fund test users with native CHZ
        vm.deal(user1, 10000 ether);
        vm.deal(user2, 10000 ether);
        
        // Deploy registry and implementation, register beacon and deploy factory
        registry = new SportBeaconRegistry(admin);

        ufcImpl = new UFCBetting();
        registry.setSportImplementation(SPORT_UFC, address(ufcImpl));

        factory = new MatchHubBeaconFactory(admin, address(registry), address(priceFeed), treasury, MIN_BET_USD);

        vm.stopPrank();
    }

    function testCreateUFCMatch() public {
        vm.startPrank(admin);

        bytes32 matchId = keccak256(abi.encodePacked("UFC_MATCH_1"));
        uint64 cutoff = uint64(block.timestamp + 1 days);
        uint16 feeBps = 300; // 3%
        bool allowDraw = true;

        address proxy = factory.createUFCMatch(
            admin,
            address(0), // use factory default priceFeed
            matchId,
            cutoff,
            feeBps,
            address(0), // use factory default treasury
            0, // use factory default minBetUsd
            allowDraw
        );

        assertTrue(proxy != address(0), "proxy should be non-zero");
        assertTrue(address(proxy).code.length > 0, "proxy must have code");

        // check ADMIN_ROLE granted
        bytes32 ADMIN_ROLE = ufcImpl.ADMIN_ROLE();
        assertTrue(UFCBetting(payable(proxy)).hasRole(ADMIN_ROLE, admin), "proxy admin must be admin");

        // check treasury set
        assertEq(UFCBetting(payable(proxy)).treasury(), treasury, "proxy treasury must be treasury safe");

        address beacon = registry.getBeacon(SPORT_UFC);
        assertTrue(beacon != address(0), "ufc beacon must be set");

        vm.stopPrank();
    }

    function testCreateUFCMatchWithoutDraw() public {
        vm.startPrank(admin);

        bytes32 matchId = keccak256("UFC_NO_DRAW");
        uint64 cutoff = uint64(block.timestamp + 1 days);
        (address proxy, UFCBetting ufc) = _createUFCMatch(admin, matchId, cutoff, 200, treasury, false);

        assertFalse(ufc.allowDraw());
        assertEq(ufc.outcomesCount(), 2); // Only RED and BLUE
        vm.stopPrank();
    }

    function testCreateUFCMatchWithDraw() public {
        vm.startPrank(admin);

        bytes32 matchId = keccak256("UFC_WITH_DRAW");
        uint64 cutoff = uint64(block.timestamp + 1 days);
        (address proxy, UFCBetting ufc) = _createUFCMatch(admin, matchId, cutoff, 200, treasury, true);

        assertTrue(ufc.allowDraw());
        assertEq(ufc.outcomesCount(), 3); // RED, BLUE, DRAW
        vm.stopPrank();
    }

    function testBetRed() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256("BET_RED");
        uint64 cutoff = uint64(block.timestamp + 1 days);
        (address proxy, UFCBetting ufc) = _createUFCMatch(admin, matchId, cutoff, 200, treasury, false);
        vm.stopPrank();

        vm.startPrank(user1);
        ufc.betRed{value: 100 ether}();
        vm.stopPrank();

        assertEq(ufc.pool(ufc.RED()), 100 ether);
        assertEq(ufc.bets(user1, ufc.RED()), 100 ether);
    }

    function testBetBlue() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256("BET_BLUE");
        uint64 cutoff = uint64(block.timestamp + 1 days);
        (address proxy, UFCBetting ufc) = _createUFCMatch(admin, matchId, cutoff, 200, treasury, false);
        vm.stopPrank();

        vm.startPrank(user1);
        ufc.betBlue{value: 150 ether}();
        vm.stopPrank();

        assertEq(ufc.pool(ufc.BLUE()), 150 ether);
        assertEq(ufc.bets(user1, ufc.BLUE()), 150 ether);
    }

    function testBetDrawWhenAllowed() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256("BET_DRAW_ALLOWED");
        uint64 cutoff = uint64(block.timestamp + 1 days);
        (address proxy, UFCBetting ufc) = _createUFCMatch(admin, matchId, cutoff, 200, treasury, true);
        vm.stopPrank();

        vm.startPrank(user1);
        ufc.betDraw{value: 50 ether}();
        vm.stopPrank();

        assertEq(ufc.pool(ufc.DRAW()), 50 ether);
    }

    function testRevertBetDrawWhenDisabled() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256("BET_DRAW_DISABLED");
        uint64 cutoff = uint64(block.timestamp + 1 days);
        (address proxy, UFCBetting ufc) = _createUFCMatch(admin, matchId, cutoff, 200, treasury, false);
        vm.stopPrank();

        vm.startPrank(user1);
        vm.expectRevert("DRAW_DISABLED");
        ufc.betDraw{value: 50 ether}();
        vm.stopPrank();
    }

    function testMultipleBetsFromMultipleUsers() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256("MULTI_USERS_UFC");
        uint64 cutoff = uint64(block.timestamp + 1 days);
        (address proxy, UFCBetting ufc) = _createUFCMatch(admin, matchId, cutoff, 200, treasury, true);
        vm.stopPrank();

        // user1 bets on RED
        vm.startPrank(user1);
        ufc.betRed{value: 100 ether}();
        vm.stopPrank();

        // user2 bets on BLUE
        vm.startPrank(user2);
        ufc.betBlue{value: 200 ether}();
        vm.stopPrank();

        assertEq(ufc.pool(ufc.RED()), 100 ether);
        assertEq(ufc.pool(ufc.BLUE()), 200 ether);
        assertEq(ufc.totalPoolAmount(), 300 ether);
    }

    function testSettleRedWins() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256("SETTLE_RED");
        uint64 cutoff = uint64(block.timestamp + 1 days);
        (address proxy, UFCBetting ufc) = _createUFCMatch(admin, matchId, cutoff, 200, treasury, false);
        vm.stopPrank();

        // Place bets

        vm.startPrank(user1);
        ufc.betRed{value: 100 ether}();
        vm.stopPrank();

        vm.startPrank(user2);
        ufc.betBlue{value: 100 ether}();
        vm.stopPrank();

        // Settle
        vm.warp(cutoff + 1);
        uint8 redOutcome = ufc.RED();
        vm.prank(admin);
        ufc.settle(redOutcome);

        assertTrue(ufc.settled());
        assertEq(ufc.winningOutcome(), redOutcome);
    }

    function testClaimRedWinner() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256("CLAIM_RED");
        uint64 cutoff = uint64(block.timestamp + 1 days);
        (address proxy, UFCBetting ufc) = _createUFCMatch(admin, matchId, cutoff, 200, treasury, false);
        vm.stopPrank();

        // user1 bets on RED, user2 bets on BLUE

        vm.startPrank(user1);
        ufc.betRed{value: 100 ether}();
        vm.stopPrank();

        vm.startPrank(user2);
        ufc.betBlue{value: 100 ether}();
        vm.stopPrank();

        // Settle with RED winning
        vm.warp(cutoff + 1);
        uint8 redOutcome = ufc.RED();
        vm.prank(admin);
        ufc.settle(redOutcome);

        // user1 claims
        uint256 balanceBefore = user1.balance;
        vm.prank(user1);
        ufc.claim();
        uint256 balanceAfter = user1.balance;

        // user1 gets total pool minus fee (200 - 2% = 196)
        assertEq(balanceAfter - balanceBefore, 196 ether);
    }

    function testClaimDrawWinner() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256("CLAIM_DRAW_UFC");
        uint64 cutoff = uint64(block.timestamp + 1 days);
        (address proxy, UFCBetting ufc) = _createUFCMatch(admin, matchId, cutoff, 200, treasury, true);
        vm.stopPrank();

        // Multiple bets on different outcomes
        vm.startPrank(user1);
        ufc.betRed{value: 100 ether}();
        ufc.betBlue{value: 100 ether}();
        ufc.betDraw{value: 100 ether}();
        vm.stopPrank();

        // Settle with DRAW
        vm.warp(cutoff + 1);
        uint8 drawOutcome = ufc.DRAW();
        vm.prank(admin);
        ufc.settle(drawOutcome);

        // user1 claims (only gets payout for DRAW bet)
        uint256 balanceBefore = user1.balance;
        vm.prank(user1);
        ufc.claim();
        uint256 balanceAfter = user1.balance;

        // Total pool is 300, fee is 6 (2%), distributable is 294
        // user1 has 100% of DRAW pool, so gets all 294
        assertEq(balanceAfter - balanceBefore, 294 ether);
    }

    function testRevertBetAfterCutoff() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256("BET_AFTER_CUTOFF_UFC");
        uint64 cutoff = uint64(block.timestamp + 1 days);
        (address proxy, UFCBetting ufc) = _createUFCMatch(admin, matchId, cutoff, 200, treasury, false);
        vm.stopPrank();

        // Warp past cutoff
        vm.warp(cutoff + 1);

        vm.startPrank(user1);
        vm.expectRevert();
        ufc.betRed{value: 100 ether}();
        vm.stopPrank();
    }

    function testRevertBetZeroAmount() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256("BET_ZERO_UFC");
        uint64 cutoff = uint64(block.timestamp + 1 days);
        (address proxy, UFCBetting ufc) = _createUFCMatch(admin, matchId, cutoff, 200, treasury, false);
        vm.stopPrank();

        vm.startPrank(user1);
        vm.expectRevert();
        ufc.betRed{value: 0}();
        vm.stopPrank();
    }

    function testRevertSettleByNonSettler() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256("SETTLE_NON_SETTLER_UFC");
        uint64 cutoff = uint64(block.timestamp + 1 days);
        (address proxy, UFCBetting ufc) = _createUFCMatch(admin, matchId, cutoff, 200, treasury, false);
        vm.stopPrank();

        vm.warp(cutoff + 1);

        bytes32 SETTLER_ROLE = ufc.SETTLER_ROLE();
        uint8 redOutcome = ufc.RED();
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, SETTLER_ROLE));
        ufc.settle(redOutcome);
        vm.stopPrank();
    }

    function testRevertSettleAlreadySettled() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256("DOUBLE_SETTLE_UFC");
        uint64 cutoff = uint64(block.timestamp + 1 days);
        (address proxy, UFCBetting ufc) = _createUFCMatch(admin, matchId, cutoff, 200, treasury, false);

        vm.warp(cutoff + 1);
        uint8 redOutcome = ufc.RED();
        uint8 blueOutcome = ufc.BLUE();
        ufc.settle(redOutcome);

        vm.expectRevert();
        ufc.settle(blueOutcome);
        vm.stopPrank();
    }

    function testRevertClaimBeforeSettlement() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256("CLAIM_BEFORE_SETTLE_UFC");
        uint64 cutoff = uint64(block.timestamp + 1 days);
        (address proxy, UFCBetting ufc) = _createUFCMatch(admin, matchId, cutoff, 200, treasury, false);
        vm.stopPrank();

        vm.startPrank(user1);
        ufc.betRed{value: 100 ether}();

        vm.expectRevert();
        ufc.claim();
        vm.stopPrank();
    }

    function testRevertClaimTwice() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256("DOUBLE_CLAIM_UFC");
        uint64 cutoff = uint64(block.timestamp + 1 days);
        (address proxy, UFCBetting ufc) = _createUFCMatch(admin, matchId, cutoff, 200, treasury, false);
        vm.stopPrank();

        vm.startPrank(user1);
        ufc.betRed{value: 100 ether}();
        vm.stopPrank();

        vm.warp(cutoff + 1);
        uint8 redOutcome = ufc.RED();
        vm.prank(admin);
        ufc.settle(redOutcome);

        vm.startPrank(user1);
        ufc.claim();
        vm.expectRevert();
        ufc.claim();
        vm.stopPrank();
    }

    function testPauseUnpause() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256("PAUSE_UFC");
        uint64 cutoff = uint64(block.timestamp + 1 days);
        (address proxy, UFCBetting ufc) = _createUFCMatch(admin, matchId, cutoff, 200, treasury, false);

        ufc.pause();
        assertTrue(ufc.paused());

        ufc.unpause();
        assertFalse(ufc.paused());
        vm.stopPrank();
    }

    function testRevertBetWhenPaused() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256("BET_PAUSED_UFC");
        uint64 cutoff = uint64(block.timestamp + 1 days);
        (address proxy, UFCBetting ufc) = _createUFCMatch(admin, matchId, cutoff, 200, treasury, false);

        ufc.pause();
        vm.stopPrank();

        vm.startPrank(user1);
        vm.expectRevert();
        ufc.betRed{value: 100 ether}();
        vm.stopPrank();
    }

    function testSweepIfNoWinners() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256("SWEEP_UFC");
        uint64 cutoff = uint64(block.timestamp + 1 days);
        (address proxy, UFCBetting ufc) = _createUFCMatch(admin, matchId, cutoff, 200, treasury, false);
        vm.stopPrank();

        // Only bet on BLUE
        vm.startPrank(user1);
        ufc.betBlue{value: 100 ether}();
        vm.stopPrank();

        // Settle with RED (no winners)
        vm.warp(cutoff + 1);
        uint8 redOutcome = ufc.RED();
        vm.prank(admin);
        ufc.settle(redOutcome);

        // Sweep should work
        uint256 treasuryBefore = treasury.balance;
        vm.prank(admin);
        ufc.sweepIfNoWinners();
        uint256 treasuryAfter = treasury.balance;

        assertEq(treasuryAfter - treasuryBefore, 100 ether);
    }

    function testRevertSweepWithWinners() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256("SWEEP_WITH_WINNERS_UFC");
        uint64 cutoff = uint64(block.timestamp + 1 days);
        (address proxy, UFCBetting ufc) = _createUFCMatch(admin, matchId, cutoff, 200, treasury, false);
        vm.stopPrank();

        // Bet on RED
        vm.startPrank(user1);
        ufc.betRed{value: 100 ether}();
        vm.stopPrank();

        // Settle with RED (has winners)
        vm.warp(cutoff + 1);
        uint8 redOutcome = ufc.RED();
        vm.prank(admin);
        ufc.settle(redOutcome);

        // Sweep should revert
        vm.prank(admin);
        vm.expectRevert();
        ufc.sweepIfNoWinners();
    }

    function testUpdateCutoff() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256("UPDATE_CUTOFF_UFC");
        uint64 cutoff = uint64(block.timestamp + 1 days);
        (address proxy, UFCBetting ufc) = _createUFCMatch(admin, matchId, cutoff, 200, treasury, false);

        uint64 newCutoff = uint64(block.timestamp + 2 days);
        ufc.setCutoff(newCutoff);
        assertEq(ufc.cutoffTs(), newCutoff);
        vm.stopPrank();
    }

    function testUpdateTreasury() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256("UPDATE_TREASURY_UFC");
        uint64 cutoff = uint64(block.timestamp + 1 days);
        (address proxy, UFCBetting ufc) = _createUFCMatch(admin, matchId, cutoff, 200, treasury, false);

        address newTreasury = makeAddr("NEW_TREASURY_UFC");
        ufc.setTreasury(newTreasury);
        assertEq(ufc.treasury(), newTreasury);
        vm.stopPrank();
    }

    function testUpdateFeeBps() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256("UPDATE_FEE_UFC");
        uint64 cutoff = uint64(block.timestamp + 1 days);
        (address proxy, UFCBetting ufc) = _createUFCMatch(admin, matchId, cutoff, 200, treasury, false);

        uint16 newFee = 500; // 5%
        ufc.setFeeBps(newFee);
        assertEq(ufc.feeBps(), newFee);
        vm.stopPrank();
    }

    function testPendingPayout() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256("PENDING_PAYOUT_UFC");
        uint64 cutoff = uint64(block.timestamp + 1 days);
        (address proxy, UFCBetting ufc) = _createUFCMatch(admin, matchId, cutoff, 200, treasury, false);
        vm.stopPrank();

        vm.startPrank(user1);
        ufc.betRed{value: 100 ether}();
        vm.stopPrank();

        // Before settlement
        assertEq(ufc.pendingPayout(user1), 0);

        // After settlement
        vm.warp(cutoff + 1);
        uint8 redOutcome = ufc.RED();
        vm.prank(admin);
        ufc.settle(redOutcome);

        uint256 pending = ufc.pendingPayout(user1);
        assertGt(pending, 0);
        assertEq(pending, 98 ether); // 100 - 2%
    }

    function _createUFCMatch(
        address owner_,
        bytes32 matchId_,
        uint64 cutoffTs_,
        uint16 feeBps_,
        address treasury_,
        bool allowDraw_
    ) internal returns (address proxy, UFCBetting fb) {
        proxy = factory.createUFCMatch(owner_, address(0), matchId_, cutoffTs_, feeBps_, treasury_, 0, allowDraw_);
        fb = UFCBetting(payable(proxy));
    }
}
