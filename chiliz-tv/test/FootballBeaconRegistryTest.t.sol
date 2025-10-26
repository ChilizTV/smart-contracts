// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/MatchHubBeaconFactory.sol"; // adapte le chemin si besoin
import "../src/SportBeaconRegistry.sol"; // adapte le chemin si besoin
import "../src/betting/FootballBetting.sol";
import "../src/MockERC20.sol";
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

    MockERC20 public token;

    function setUp() public {
        vm.startPrank(admin);
        // deploy registry and implementations, register beacons and deploy factory
        registry = new SportBeaconRegistry(admin);

    // deploy sport implementation (logic contract) for football and register in registry
    footballImpl = new FootballBetting();
    registry.setSportImplementation(SPORT_FOOTBALL, address(footballImpl));

        // deploy factory with this test contract as owner
        factory = new MatchHubBeaconFactory(admin, address(registry));

    // minimal ERC20 token for betting interactions in tests
        token = new MockERC20();

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
            address(token),
            matchId,
            cutoff,
            feeBps,
            treasury
        );

        // basic assertions
        assertTrue(proxy != address(0), "proxy should be non-zero");
        // proxy must contain runtime code
        assertTrue(proxy.code.length > 0, "proxy must have code");

        // The implementation uses AccessControlUpgradeable: check ADMIN_ROLE was granted to admin
        bytes32 ADMIN_ROLE = footballImpl.ADMIN_ROLE();
        assertTrue(FootballBetting(proxy).hasRole(ADMIN_ROLE, admin), "proxy admin must be admin");

        // Treasury should be set correctly on the proxied contract
        assertEq(FootballBetting(proxy).treasury(), treasury, "proxy treasury must be treasury safe");
        
    // beacon should exist for football
    address beacon = registry.getBeacon(SPORT_FOOTBALL);
    assertTrue(beacon != address(0), "football beacon must be set");

        vm.stopPrank();
    }


    function testPlaceBet() public {
        vm.startPrank(admin);

        // Create football match proxy
        bytes32 matchId = keccak256(abi.encodePacked("MATCH_2"));
        uint64 cutoff = uint64(block.timestamp + 1 days);
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
        token.mint(user1, betAmount);
        token.mint(user1, betAmount);
        token.mint(user1, betAmount);
        vm.stopPrank();

        vm.startPrank(user1);
        token.approve(proxy, betAmount * 3);

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
        token.mint(user1, a);
        token.mint(user2, b);

        // user1 bets HOME, user2 bets AWAY
        vm.startPrank(user1);
        token.approve(proxy, a);
        _betOnOutcome(fb, fb.HOME(), a);
        vm.stopPrank();

        vm.startPrank(user2);
        token.approve(proxy, b);
        _betOnOutcome(fb, fb.AWAY(), b);
        vm.stopPrank();

        // check pool
        assertEq(fb.totalPoolAmount(), a + b);

        // settle as admin to HOME
        vm.startPrank(admin);
        fb.settle(fb.HOME());
        // snapshot treasury balance before claim
        uint256 treasuryBefore = token.balanceOf(treasury);
        vm.stopPrank();

        // user1 claims
        vm.startPrank(user1);
        uint256 balBefore = token.balanceOf(user1);
        fb.claim();
        uint256 balAfter = token.balanceOf(user1);
        // fee = (a+b) * feeBps / 10000
        uint256 fee = ((a + b) * feeBps) / 10000;
        // user1 should receive distributable = total - fee
        assertEq(balAfter - balBefore, (a + b) - fee);
        vm.stopPrank();

        // treasury received fee
        assertEq(token.balanceOf(treasury) - treasuryBefore, fee);
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
        token.mint(user1, amt);
        vm.startPrank(user1);
        token.approve(proxy, amt);
        _betOnOutcome(fb, fb.HOME(), amt);
        vm.stopPrank();

        // settle to AWAY (no winners)
        vm.startPrank(admin);
        fb.settle(fb.AWAY());
        // call sweepIfNoWinners
        uint256 treasuryBefore = token.balanceOf(treasury);
        fb.sweepIfNoWinners();
        vm.stopPrank();

        // treasury should receive the entire contract balance
        assertEq(token.balanceOf(treasury) - treasuryBefore, amt);
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
        token.mint(user1, amt);
        vm.startPrank(user1);
        token.approve(proxy, amt);
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
        token.mint(user1, 1e18);
        token.approve(proxy, 1e18);
        vm.expectRevert(MatchBettingBase.BettingClosed.selector);
        _betOnOutcome(fb, fb.HOME(), 1e18);
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
        token.mint(user1, amt);
        vm.startPrank(user1);
        token.approve(proxy, amt);
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

        uint256 amt = 10 * 1e18;
        token.mint(user1, amt);
        vm.startPrank(user1);
        token.approve(proxy, amt);
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
                         Test helpers: create matches via factory
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Create a football match proxy via the factory and return the proxy and typed interface
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

    /// @notice Helper to place a bet on a given outcome using the sport-specific wrappers
    /// @param fb proxied FootballBetting instance
    /// @param outcome the outcome index (use fb.HOME()/fb.DRAW()/fb.AWAY())
    /// @param amount stake amount
    function _betOnOutcome(FootballBetting fb, uint8 outcome, uint256 amount) internal {
        if (outcome == fb.HOME()) {
            fb.betHome(amount);
            return;
        }
        if (outcome == fb.DRAW()) {
            fb.betDraw(amount);
            return;
        }
        if (outcome == fb.AWAY()) {
            fb.betAway(amount);
            return;
        }
        revert("INVALID_OUTCOME");
    }
    

}
