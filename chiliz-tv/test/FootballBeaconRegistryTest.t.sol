// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/matchhub/MatchHubBeaconFactory.sol";
import "../src/SportBeaconRegistry.sol";
import "../src/betting/FootballBetting.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract FootballBeaconRegistryTest is Test {

    SportBeaconRegistry public registry;
    MatchHubBeaconFactory public factory;

    FootballBetting public footballImpl;
    bytes32 public constant SPORT_FOOTBALL = keccak256("FOOTBALL");

    address admin = makeAddr("ADMIN");
    address treasury = makeAddr("TREASURY");
    address public user1 = makeAddr("USER1");
    address public user2 = makeAddr("USER2");

    uint256 public constant MIN_BET_CHZ = 5e18; // 5 CHZ minimum bet

    function setUp() public {
        // Reset timestamp to a known value for consistent testing
        vm.warp(1000000); // Start at a reasonable timestamp
        
        vm.startPrank(admin);
        
        // Fund test users with native CHZ
        vm.deal(user1, 10000 ether);
        vm.deal(user2, 10000 ether);
        
        // Deploy registry and implementations, register beacons and deploy factory
        registry = new SportBeaconRegistry(admin);

        // Deploy sport implementation (logic contract) for football and register in registry
        footballImpl = new FootballBetting();
        registry.setSportImplementation(SPORT_FOOTBALL, address(footballImpl));

        // Deploy factory with this test contract as owner
        factory = new MatchHubBeaconFactory(admin, address(registry), treasury, MIN_BET_CHZ);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/


    // (UFC tests moved to test/UFCBeaconRegistryTest.t.sol)

    function testCreateFootballMatch() public {
        vm.startPrank(admin);

        bytes32 matchId = keccak256(abi.encodePacked("MATCH_1"));
        uint64 cutoff = uint64(block.timestamp + 1 days);
        uint16 feeBps = 300; // 3%

        address proxy = factory.createFootballMatch(
            admin,
            matchId,
            cutoff,
            feeBps,
            address(0), // use factory default treasury
            0 // use factory default minBetChz
        );
        address proxyPayable = payable(proxy);

        // basic assertions
        assertTrue(proxy != address(0), "proxy should be non-zero");
        // proxy must contain runtime code
        assertTrue(proxy.code.length > 0, "proxy must have code");

        // The implementation uses AccessControlUpgradeable: check ADMIN_ROLE was granted to admin
        bytes32 ADMIN_ROLE = footballImpl.ADMIN_ROLE();
        assertTrue(FootballBetting(payable(proxy)).hasRole(ADMIN_ROLE, admin), "proxy admin must be admin");

        // Treasury should be set correctly on the proxied contract
        assertEq(FootballBetting(payable(proxy)).treasury(), treasury, "proxy treasury must be treasury safe");
        
    // beacon should exist for football
    address beacon = registry.getBeacon(SPORT_FOOTBALL);
    assertTrue(beacon != address(0), "football beacon must be set");

        vm.stopPrank();
    }


    function testPlaceBet() public {
        vm.startPrank(admin);

        // Create football match proxy
        bytes32 matchId = keccak256(abi.encodePacked("MATCH_2"));
        uint64 cutoff = uint64(block.timestamp + 7 days); // Use 7 days to avoid any timing issues
        uint16 feeBps = 200; // 2%

        (address proxy, FootballBetting fb) = _createFootballMatch(
            admin,
            matchId,
            cutoff,
            feeBps,
            treasury
        );

        // Mint tokens to user and approve
    
        uint256 betAmount = 1000 * 10**18;
        vm.stopPrank();

        vm.startPrank(user1);

        // Place a bet on outcome DRAW (1) using the sport-specific wrapper
        _betOnOutcome(fb, fb.DRAW(), betAmount);
        _betOnOutcome(fb, fb.HOME(), betAmount);
        _betOnOutcome(fb, fb.AWAY(), betAmount);
        // Verify total pool amount updated
        assertEq(fb.totalPoolAmount(), betAmount * 3, "total pool amount should equal bet amount");

        vm.stopPrank();
    }

    function testResolveMatch() public {
        vm.startPrank(admin);

        // Create football match proxy
        bytes32 matchId = keccak256(abi.encodePacked("MATCH_3"));
        uint64 cutoff = uint64(block.timestamp + 1 days);
        uint16 feeBps = 200; // 2%

        (address proxy, FootballBetting fb) = _createFootballMatch(
            admin,
            matchId,
            cutoff,
            feeBps,
            treasury
        );

    // Resolve match as admin (settle uses SETTLER_ROLE)
    fb.settle(fb.HOME());

    // Verify match is resolved
    assertTrue(fb.settled(), "match should be resolved");
    assertEq(fb.winningOutcome(), fb.HOME(), "winning outcome should be HOME");

        vm.stopPrank();
    }

    function testPayoutFlow() public {
        vm.startPrank(admin);
        // create match
        bytes32 matchId = keccak256(abi.encodePacked("MATCH_PAYOUT"));
        uint64 cutoff = uint64(block.timestamp + 1 days);
        uint16 feeBps = 500; // 5%
        (address proxy, FootballBetting fb) = _createFootballMatch(admin, matchId, cutoff, feeBps, treasury);
        vm.stopPrank();

        // bettors
        uint256 a = 100 * 1e18;
        uint256 b = 50 * 1e18;

        // user1 bets HOME, user2 bets AWAY
        vm.startPrank(user1);
        _betOnOutcome(fb, fb.HOME(), a);
        vm.stopPrank();

        vm.startPrank(user2);
        _betOnOutcome(fb, fb.AWAY(), b);
        vm.stopPrank();

        // check pool
        assertEq(fb.totalPoolAmount(), a + b);

        // settle as admin to HOME
        vm.startPrank(admin);
        fb.settle(fb.HOME());
        // snapshot treasury balance before claim
        uint256 treasuryBefore = treasury.balance;
        vm.stopPrank();

        // user1 claims
        vm.startPrank(user1);
        uint256 balBefore = user1.balance;
        fb.claim();
        uint256 balAfter = user1.balance;
        // fee = (a+b) * feeBps / 10000
        uint256 fee = ((a + b) * feeBps) / 10000;
        // user1 should receive distributable = total - fee
        assertEq(balAfter - balBefore, (a + b) - fee);
        vm.stopPrank();

        // treasury received fee
        assertEq(treasury.balance - treasuryBefore, fee);
    }

    function testSweepIfNoWinners() public {
        vm.startPrank(admin);
        // create match
        bytes32 matchId = keccak256(abi.encodePacked("MATCH_SWEEP"));
        uint64 cutoff = uint64(block.timestamp + 1 days);
        uint16 feeBps = 200; // 2%
        (address proxy, FootballBetting fb) = _createFootballMatch(admin, matchId, cutoff, feeBps, treasury);
        vm.stopPrank();

        // user1 bets HOME only
        uint256 amt = 100 * 1e18;
        vm.startPrank(user1);
        _betOnOutcome(fb, fb.HOME(), amt);
        vm.stopPrank();

        // settle to AWAY (no winners)
        vm.startPrank(admin);
        fb.settle(fb.AWAY());
        // call sweepIfNoWinners
        uint256 treasuryBefore = treasury.balance;
        fb.sweepIfNoWinners();
        vm.stopPrank();

        // treasury should receive the entire contract balance
        assertEq(treasury.balance - treasuryBefore, amt);
    }

    function testSetCutoffAfterSettledReverts() public {
        vm.startPrank(admin);
        // create and settle
        bytes32 matchId = keccak256(abi.encodePacked("MATCH_SETTLE"));
        uint64 cutoff = uint64(block.timestamp + 1 days);
        uint16 feeBps = 100;
        (address proxy, FootballBetting fb) = _createFootballMatch(admin, matchId, cutoff, feeBps, treasury);
        fb.settle(fb.HOME());
        // attempt to set cutoff should revert
        vm.expectRevert();
        fb.setCutoff(uint64(block.timestamp + 2 days));
        vm.stopPrank();
    }

    function testFeeBpsZeroAfterFirstClaim() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256(abi.encodePacked("MATCH_FEE_RESET"));
        uint64 cutoff = uint64(block.timestamp + 1 days);
        uint16 feeBps = 300; // 3%
        (address proxy, FootballBetting fb) = _createFootballMatch(admin, matchId, cutoff, feeBps, treasury);
        vm.stopPrank();

        // single bettor
        uint256 amt = 100 * 1e18;
        vm.startPrank(user1);
        _betOnOutcome(fb, fb.HOME(), amt);
        vm.stopPrank();

        // settle and claim
        vm.startPrank(admin);
        fb.settle(fb.HOME());
        vm.stopPrank();

        vm.startPrank(user1);
        fb.claim();
        vm.stopPrank();

        // feeBps should be reset to 0 after claim (MVP behavior)
        assertEq(fb.feeBps(), 0);
    }

    function testBetAfterCutoffReverts() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256(abi.encodePacked("MATCH_CUTOFF"));
        uint64 cutoff = uint64(block.timestamp + 100);
        uint16 feeBps = 100;
        (address proxy, FootballBetting fb) = _createFootballMatch(admin, matchId, cutoff, feeBps, treasury);
        vm.stopPrank();

        // Warp time past the cutoff
        vm.warp(cutoff + 1);

        vm.startPrank(user1);
        vm.expectRevert(MatchBettingBase.BettingClosed.selector);
        fb.betHome{value: 1e18}();
        vm.stopPrank();
    }

    function testDoubleClaimReverts() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256(abi.encodePacked("MATCH_DOUBLE_CLAIM"));
        uint64 cutoff = uint64(block.timestamp + 1 days);
        uint16 feeBps = 100;
        (address proxy, FootballBetting fb) = _createFootballMatch(admin, matchId, cutoff, feeBps, treasury);
        vm.stopPrank();

        uint256 amt = 100 * 1e18;
        vm.startPrank(user1);
        _betOnOutcome(fb, fb.HOME(), amt);
        vm.stopPrank();

        vm.startPrank(admin);
        fb.settle(fb.HOME());
        vm.stopPrank();

        vm.startPrank(user1);
        fb.claim();
        vm.expectRevert();
        fb.claim();
        vm.stopPrank();
    }

    function testRevert_SettleByNonSettlerReverts() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256(abi.encodePacked("MATCH_SETTLER"));
        uint64 cutoff = uint64(block.timestamp + 1 days);
        uint16 feeBps = 100;
        (address proxy, FootballBetting fb) = _createFootballMatch(admin, matchId, cutoff, feeBps, treasury);
        
        // Verify user1 does not have settler role
        bytes32 SETTLER = fb.SETTLER_ROLE();
        assertTrue(!fb.hasRole(SETTLER, user1), "user1 must not have SETTLER_ROLE");
        
        // Get outcome value before expectRevert
        uint8 homeOutcome = fb.HOME();
        vm.stopPrank();

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, SETTLER));
        fb.settle(homeOutcome);
        vm.stopPrank();
    }

    function testSweepRevertsWhenWinnersExist() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256(abi.encodePacked("MATCH_SWEEP_NEG"));
        uint64 cutoff = uint64(block.timestamp + 1 days);
        uint16 feeBps = 100;
        (address proxy, FootballBetting fb) = _createFootballMatch(admin, matchId, cutoff, feeBps, treasury);
        vm.stopPrank();

        uint256 amt = 100 * 1e18; // Must be >= 50 CHZ ($5 at $0.10/CHZ)
        vm.startPrank(user1);
        _betOnOutcome(fb, fb.HOME(), amt);
        vm.stopPrank();

        vm.startPrank(admin);
        fb.settle(fb.HOME());
        vm.expectRevert();
        fb.sweepIfNoWinners();
        vm.stopPrank();
    }

    function testSetFeeBpsValidationReverts() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256(abi.encodePacked("MATCH_FEE_VALID"));
        uint64 cutoff = uint64(block.timestamp + 1 days);
        uint16 feeBps = 100;
        (address proxy, FootballBetting fb) = _createFootballMatch(admin, matchId, cutoff, feeBps, treasury);
        vm.expectRevert();
        fb.setFeeBps(2000); // > 1000 (10%) should revert
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////////////////
                    ADDITIONAL COMPREHENSIVE TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function testMultipleBetsMultipleUsers() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256("MULTI_USERS");
        uint64 cutoff = uint64(block.timestamp + 1 days);
        (address proxy, FootballBetting fb) = _createFootballMatch(admin, matchId, cutoff, 200, treasury);
        vm.stopPrank();

        // Mint tokens and bet for user1 (HOME)
        vm.startPrank(user1);
        fb.betHome{value: 100 ether}();
        vm.stopPrank();

        // Mint tokens and bet for user2 (AWAY)
        vm.startPrank(user2);
        fb.betAway{value: 200 ether}();
        vm.stopPrank();

        // Check pool amounts
        assertEq(fb.pool(fb.HOME()), 100 ether);
        assertEq(fb.pool(fb.AWAY()), 200 ether);
        assertEq(fb.totalPoolAmount(), 300 ether);
    }

    function testBetDraw() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256("BET_DRAW");
        uint64 cutoff = uint64(block.timestamp + 1 days);
        (address proxy, FootballBetting fb) = _createFootballMatch(admin, matchId, cutoff, 200, treasury);
        vm.stopPrank();

        vm.startPrank(user1);
        fb.betDraw{value: 50 ether}();
        vm.stopPrank();

        assertEq(fb.pool(fb.DRAW()), 50 ether);
    }

    function testSettleDraw() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256("SETTLE_DRAW");
        uint64 cutoff = uint64(block.timestamp + 1 days);
        (address proxy, FootballBetting fb) = _createFootballMatch(admin, matchId, cutoff, 200, treasury);
        vm.stopPrank();

        // Place bets on all outcomes
        vm.startPrank(user1);
        fb.betHome{value: 100 ether}();
        fb.betDraw{value: 100 ether}();
        fb.betAway{value: 100 ether}();
        vm.stopPrank();

        // Warp past cutoff
        vm.warp(cutoff + 1);

        // Settle with draw outcome
        uint8 drawOutcome = fb.DRAW();
        vm.prank(admin);
        fb.settle(drawOutcome);

        assertTrue(fb.settled());
        assertEq(fb.winningOutcome(), drawOutcome);
    }

    function testClaimDrawWinner() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256("CLAIM_DRAW");
        uint64 cutoff = uint64(block.timestamp + 1 days);
        (address proxy, FootballBetting fb) = _createFootballMatch(admin, matchId, cutoff, 200, treasury);
        vm.stopPrank();

        // user1 bets on draw, user2 bets on home

        vm.startPrank(user1);
        fb.betDraw{value: 100 ether}();
        vm.stopPrank();

        vm.startPrank(user2);
        fb.betHome{value: 100 ether}();
        vm.stopPrank();

        // Settle with draw
        vm.warp(cutoff + 1);
        uint8 drawOutcome = fb.DRAW();
        vm.prank(admin);
        fb.settle(drawOutcome);

        // user1 should be able to claim
        uint256 balanceBefore = user1.balance;
        vm.prank(user1);
        fb.claim();
        uint256 balanceAfter = user1.balance;

        // user1 should receive payout (200 ether total - 2% fee = 196 ether)
        assertGt(balanceAfter, balanceBefore);
        assertEq(balanceAfter - balanceBefore, 196 ether);
    }

    function testRevertBetAfterSettlement() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256("BET_AFTER_SETTLE");
        uint64 cutoff = uint64(block.timestamp + 1 days);
        (address proxy, FootballBetting fb) = _createFootballMatch(admin, matchId, cutoff, 200, treasury);
        
        // Settle immediately
        vm.warp(cutoff + 1);
        fb.settle(fb.HOME());
        vm.stopPrank();

        // Try to bet after settlement
        vm.startPrank(user1);
        vm.expectRevert();
        fb.betHome{value: 100 ether}();
        vm.stopPrank();
    }

    function testPauseUnpauseBetting() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256("PAUSE_TEST");
        uint64 cutoff = uint64(block.timestamp + 1 days);
        (address proxy, FootballBetting fb) = _createFootballMatch(admin, matchId, cutoff, 200, treasury);

        // Pause the contract
        fb.pause();
        assertTrue(fb.paused());
        vm.stopPrank();

        // Try to bet while paused (should revert)
        vm.startPrank(user1);
        vm.expectRevert();
        fb.betHome{value: 100 ether}();
        vm.stopPrank();

        // Unpause
        vm.prank(admin);
        fb.unpause();
        assertFalse(fb.paused());

        // Now bet should work
        vm.prank(user1);
        fb.betHome{value: 100 ether}();
        assertEq(fb.pool(fb.HOME()), 100 ether);
    }

    function testUpdateCutoffBeforeSettlement() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256("UPDATE_CUTOFF");
        uint64 cutoff = uint64(block.timestamp + 1 days);
        (address proxy, FootballBetting fb) = _createFootballMatch(admin, matchId, cutoff, 200, treasury);

        uint64 newCutoff = uint64(block.timestamp + 2 days);
        fb.setCutoff(newCutoff);
        assertEq(fb.cutoffTs(), newCutoff);
        vm.stopPrank();
    }

    function testRevertUpdateCutoffAfterSettlement() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256("CUTOFF_AFTER_SETTLE");
        uint64 cutoff = uint64(block.timestamp + 1 days);
        (address proxy, FootballBetting fb) = _createFootballMatch(admin, matchId, cutoff, 200, treasury);

        vm.warp(cutoff + 1);
        fb.settle(fb.HOME());

        vm.expectRevert();
        fb.setCutoff(uint64(block.timestamp + 3 days));
        vm.stopPrank();
    }

    function testUpdateTreasury() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256("UPDATE_TREASURY");
        uint64 cutoff = uint64(block.timestamp + 1 days);
        (address proxy, FootballBetting fb) = _createFootballMatch(admin, matchId, cutoff, 200, treasury);

        address newTreasury = makeAddr("NEW_TREASURY");
        fb.setTreasury(newTreasury);
        assertEq(fb.treasury(), newTreasury);
        vm.stopPrank();
    }

    function testRevertUpdateTreasuryZeroAddress() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256("TREASURY_ZERO");
        uint64 cutoff = uint64(block.timestamp + 1 days);
        (address proxy, FootballBetting fb) = _createFootballMatch(admin, matchId, cutoff, 200, treasury);

        vm.expectRevert();
        fb.setTreasury(address(0));
        vm.stopPrank();
    }

    function testUpdateFeeBps() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256("UPDATE_FEE");
        uint64 cutoff = uint64(block.timestamp + 1 days);
        (address proxy, FootballBetting fb) = _createFootballMatch(admin, matchId, cutoff, 200, treasury);

        uint16 newFee = 500; // 5%
        fb.setFeeBps(newFee);
        assertEq(fb.feeBps(), newFee);
        vm.stopPrank();
    }

    function testPendingPayoutBeforeAndAfterSettlement() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256("PENDING_PAYOUT");
        uint64 cutoff = uint64(block.timestamp + 1 days);
        (address proxy, FootballBetting fb) = _createFootballMatch(admin, matchId, cutoff, 200, treasury);
        vm.stopPrank();

        vm.startPrank(user1);
        fb.betHome{value: 100 ether}();
        vm.stopPrank();

        // Before settlement, pending payout should be 0
        assertEq(fb.pendingPayout(user1), 0);

        // After settlement
        vm.warp(cutoff + 1);
        uint8 homeOutcome = fb.HOME();
        vm.prank(admin);
        fb.settle(homeOutcome);

        // Now pending payout should be > 0
        uint256 pending = fb.pendingPayout(user1);
        assertGt(pending, 0);
        // Should be 98 ether (100 - 2% fee)
        assertEq(pending, 98 ether);
    }

    function testRevertClaimBeforeSettlement() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256("CLAIM_BEFORE_SETTLE");
        uint64 cutoff = uint64(block.timestamp + 1 days);
        (address proxy, FootballBetting fb) = _createFootballMatch(admin, matchId, cutoff, 200, treasury);
        vm.stopPrank();

        vm.startPrank(user1);
        fb.betHome{value: 100 ether}();

        vm.expectRevert();
        fb.claim();
        vm.stopPrank();
    }

    function testRevertClaimNoWinningBet() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256("NO_WIN_BET");
        uint64 cutoff = uint64(block.timestamp + 1 days);
        (address proxy, FootballBetting fb) = _createFootballMatch(admin, matchId, cutoff, 200, treasury);
        vm.stopPrank();

        // user1 bets on away
        vm.startPrank(user1);
        fb.betAway{value: 100 ether}();
        vm.stopPrank();

        // Settle with home win
        vm.warp(cutoff + 1);
        uint8 homeOutcome = fb.HOME();
        vm.prank(admin);
        fb.settle(homeOutcome);

        // user1 should not be able to claim (bet on wrong outcome)
        vm.prank(user1);
        vm.expectRevert();
        fb.claim();
    }

    function testRevertNonAdminActions() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256("NON_ADMIN");
        uint64 cutoff = uint64(block.timestamp + 1 days);
        (address proxy, FootballBetting fb) = _createFootballMatch(admin, matchId, cutoff, 200, treasury);
        vm.stopPrank();

        bytes32 ADMIN_ROLE = fb.ADMIN_ROLE();

        vm.startPrank(user1);
        // Try to pause (should fail)
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, fb.PAUSER_ROLE()));
        fb.pause();

        // Try to set fee (should fail)
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, ADMIN_ROLE));
        fb.setFeeBps(300);

        // Try to set treasury (should fail)
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, ADMIN_ROLE));
        fb.setTreasury(makeAddr("NEW"));

        // Try to set cutoff (should fail)
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, ADMIN_ROLE));
        fb.setCutoff(uint64(block.timestamp + 2 days));

        vm.stopPrank();
    }

    function testGetBetAmount() public {
        vm.startPrank(admin);
        bytes32 matchId = keccak256("GET_BET");
        uint64 cutoff = uint64(block.timestamp + 1 days);
        (address proxy, FootballBetting fb) = _createFootballMatch(admin, matchId, cutoff, 200, treasury);
        vm.stopPrank();

        vm.startPrank(user1);
        fb.betHome{value: 50 ether}();
        fb.betHome{value: 60 ether}(); // Must be >= 50 CHZ ($5 at $0.10/CHZ)
        vm.stopPrank();

        // Check user1's total bet on HOME
        assertEq(fb.bets(user1, fb.HOME()), 110 ether);
    }

    /*//////////////////////////////////////////////////////////////////////////
                         Test helpers: create matches via factory
    //////////////////////////////////////////////////////////////**/

    /// @notice Create a football match proxy via the factory and return the proxy and typed interface
    function _createFootballMatch(
        address owner_,
        bytes32 matchId_,
        uint64 cutoffTs_,
        uint16 feeBps_,
        address treasury_
    ) internal returns (address proxy, FootballBetting fb) {
        proxy = factory.createFootballMatch(owner_, matchId_, cutoffTs_, feeBps_, treasury_, 0);
        fb = FootballBetting(payable(proxy));
    }

    /// @notice Helper to place a bet on a given outcome using the sport-specific wrappers
    /// @param fb proxied FootballBetting instance
    /// @param outcome the outcome index (use fb.HOME()/fb.DRAW()/fb.AWAY())
    /// @param amount stake amount
    function _betOnOutcome(FootballBetting fb, uint8 outcome, uint256 amount) internal {
        if (outcome == fb.HOME()) {
            fb.betHome{value: amount}();
            return;
        }
        if (outcome == fb.DRAW()) {
            fb.betDraw{value: amount}();
            return;
        }
        if (outcome == fb.AWAY()) {
            fb.betAway{value: amount}();
            return;
        }
        revert("INVALID_OUTCOME");
    }
    

}
