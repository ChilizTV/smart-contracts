// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test, console} from "forge-std/Test.sol";
import {BettingMatch} from "../src/betting/BettingMatch.sol";
import {FootballMatch} from "../src/betting/FootballMatch.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockUSDT} from "./mocks/MockUSDT.sol";

/**
 * @title BettingMatchTest
 * @notice Comprehensive tests for USDT-only dynamic odds betting system
 * 
 * Test Coverage:
 * 1. Odds change between bets → each bet uses correct odds at payout
 * 2. Two bets with same odds share same oddsIndex
 * 3. New odds appended and mapping updated
 * 4. Fuzz: random odds updates and bets, ensure correct payout
 * 5. Security: front-running, role abuse, settlement integrity
 */
contract BettingMatchTest is Test {
    FootballMatch public implementation;
    FootballMatch public footballMatch;
    MockUSDT public usdt;
    
    address public owner = address(0x1);
    address public oddsSetter = address(0x2);
    address public resolver = address(0x3);
    address public alice = address(0x100);
    address public bob = address(0x101);
    address public charlie = address(0x102);
    
    bytes32 constant ODDS_SETTER_ROLE = keccak256("ODDS_SETTER_ROLE");
    bytes32 constant RESOLVER_ROLE = keccak256("RESOLVER_ROLE");
    bytes32 constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    
    uint32 constant ODDS_PRECISION = 10000;
    
    // Cached market type constants to avoid consuming vm.prank
    bytes32 constant MARKET_WINNER = keccak256("WINNER");
    bytes32 constant MARKET_GOALS_TOTAL = keccak256("GOALS_TOTAL");
    
    function setUp() public {
        // Deploy mock USDT
        usdt = new MockUSDT();
        
        // Deploy implementation
        implementation = new FootballMatch();
        
        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(
            FootballMatch.initialize.selector,
            "Barcelona vs Real Madrid",
            owner
        );
        
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        footballMatch = FootballMatch(payable(address(proxy)));
        
        // Setup roles and USDT
        vm.startPrank(owner);
        footballMatch.grantRole(ODDS_SETTER_ROLE, oddsSetter);
        footballMatch.grantRole(RESOLVER_ROLE, resolver);
        footballMatch.setUSDTToken(address(usdt));
        vm.stopPrank();

        // Fund test accounts with USDT (100,000 USDT each)
        usdt.mint(alice, 100_000e6);
        usdt.mint(bob, 100_000e6);
        usdt.mint(charlie, 100_000e6);
        
        // Fund contract for payouts (1,000,000 USDT treasury)
        usdt.mint(address(footballMatch), 1_000_000e6);
    }
    
    // Helper: approve and place USDT bet
    function _placeBet(address user, uint256 marketId, uint64 selection, uint256 amount) internal {
        vm.startPrank(user);
        usdt.approve(address(footballMatch), amount);
        footballMatch.placeBetUSDT(marketId, selection, amount);
        vm.stopPrank();
    }
    
    // ══════════════════════════════════════════════════════════════════════════
    // TEST 1: Odds change between bets → each bet uses correct odds at payout
    // ══════════════════════════════════════════════════════════════════════════
    
    function test_OddsChangePreservesHistoricalOdds() public {
        // Create market with initial odds 2.00x (20000)
        vm.prank(owner);
        footballMatch.addMarketWithLine(MARKET_WINNER, 20000, 0);
        
        // Open market
        vm.prank(owner);
        footballMatch.openMarket(0);
        
        // Alice bets 100 USDT at 2.00x
        _placeBet(alice, 0, 0, 100e6);
        
        // Odds change to 2.50x (25000)
        vm.prank(oddsSetter);
        footballMatch.setMarketOdds(0, 25000);
        
        // Bob bets 100 USDT at 2.50x
        _placeBet(bob, 0, 0, 100e6);
        
        // Odds change to 1.80x (18000)
        vm.prank(oddsSetter);
        footballMatch.setMarketOdds(0, 18000);
        
        // Charlie bets 100 USDT at 1.80x
        _placeBet(charlie, 0, 0, 100e6);
        
        // Close and resolve market - Home wins (selection 0)
        vm.prank(owner);
        footballMatch.closeMarket(0);
        vm.prank(resolver);
        footballMatch.resolveMarket(0, 0);
        
        // Verify each user gets correct payout based on THEIR odds
        uint256 aliceBalanceBefore = usdt.balanceOf(alice);
        vm.prank(alice);
        footballMatch.claim(0, 0);
        uint256 alicePayout = usdt.balanceOf(alice) - aliceBalanceBefore;
        assertEq(alicePayout, 200e6, "Alice should get 2.00x payout");
        
        uint256 bobBalanceBefore = usdt.balanceOf(bob);
        vm.prank(bob);
        footballMatch.claim(0, 0);
        uint256 bobPayout = usdt.balanceOf(bob) - bobBalanceBefore;
        assertEq(bobPayout, 250e6, "Bob should get 2.50x payout");
        
        uint256 charlieBalanceBefore = usdt.balanceOf(charlie);
        vm.prank(charlie);
        footballMatch.claim(0, 0);
        uint256 charliePayout = usdt.balanceOf(charlie) - charlieBalanceBefore;
        assertEq(charliePayout, 180e6, "Charlie should get 1.80x payout");
    }
    
    // ══════════════════════════════════════════════════════════════════════════
    // TEST 2: Two bets with same odds share same oddsIndex
    // ══════════════════════════════════════════════════════════════════════════
    
    function test_SameOddsShareIndex() public {
        vm.prank(owner);
        footballMatch.addMarketWithLine(MARKET_WINNER, 21800, 0); // 2.18x
        
        vm.prank(owner);
        footballMatch.openMarket(0);
        
        // Alice bets at 2.18x
        _placeBet(alice, 0, 0, 100e6);
        
        // Bob bets at same 2.18x (no odds change)
        _placeBet(bob, 0, 0, 100e6);
        
        // Verify both bets have same oddsIndex
        (,, uint32 aliceOdds,,, ) = footballMatch.getBetDetails(0, alice, 0);
        (,, uint32 bobOdds,,, ) = footballMatch.getBetDetails(0, bob, 0);
        
        assertEq(aliceOdds, 21800, "Alice odds should be 2.18x");
        assertEq(bobOdds, 21800, "Bob odds should be 2.18x");
        assertEq(aliceOdds, bobOdds, "Both should have same odds value");
        
        // Verify odds history only has 1 entry
        uint32[] memory oddsHistory = footballMatch.getOddsHistory(0);
        assertEq(oddsHistory.length, 1, "Should only have 1 unique odds entry");
    }
    
    // ══════════════════════════════════════════════════════════════════════════
    // TEST 3: New odds appended and mapping updated
    // ══════════════════════════════════════════════════════════════════════════
    
    function test_NewOddsAppendedToRegistry() public {
        vm.prank(owner);
        footballMatch.addMarketWithLine(MARKET_WINNER, 20000, 0);
        
        vm.prank(owner);
        footballMatch.openMarket(0);
        
        // Initial odds: 2.00x
        uint32[] memory history1 = footballMatch.getOddsHistory(0);
        assertEq(history1.length, 1);
        assertEq(history1[0], 20000);
        
        // Change to 2.18x
        vm.prank(oddsSetter);
        footballMatch.setMarketOdds(0, 21800);
        
        uint32[] memory history2 = footballMatch.getOddsHistory(0);
        assertEq(history2.length, 2, "Should have 2 odds entries");
        assertEq(history2[0], 20000);
        assertEq(history2[1], 21800);
        
        // Change to 2.35x
        vm.prank(oddsSetter);
        footballMatch.setMarketOdds(0, 23500);
        
        uint32[] memory history3 = footballMatch.getOddsHistory(0);
        assertEq(history3.length, 3, "Should have 3 odds entries");
        
        // Change BACK to 2.00x (should reuse existing index, not append)
        vm.prank(oddsSetter);
        footballMatch.setMarketOdds(0, 20000);
        
        uint32[] memory history4 = footballMatch.getOddsHistory(0);
        assertEq(history4.length, 3, "Should still have 3 entries (reused index)");
        
        // Verify current odds is 2.00x
        assertEq(footballMatch.getCurrentOdds(0), 20000);
    }
    
    // ══════════════════════════════════════════════════════════════════════════
    // TEST 4: Fuzz - Random odds updates and bets
    // ══════════════════════════════════════════════════════════════════════════
    
    function testFuzz_RandomOddsAndBets(
        uint32 odds1,
        uint32 odds2,
        uint32 odds3,
        uint96 betAmount1,
        uint96 betAmount2
    ) public {
        // Bound inputs - limit odds to 10x max to avoid payout exceeding treasury
        odds1 = uint32(bound(odds1, 10001, 100000));  // Max 10x
        odds2 = uint32(bound(odds2, 10001, 100000));  // Max 10x
        odds3 = uint32(bound(odds3, 10001, 100000));  // Max 10x
        betAmount1 = uint96(bound(betAmount1, 1e6, 10_000e6));  // 1 - 10,000 USDT
        betAmount2 = uint96(bound(betAmount2, 1e6, 10_000e6));
        
        vm.prank(owner);
        footballMatch.addMarketWithLine(MARKET_WINNER, odds1, 0);
        
        vm.prank(owner);
        footballMatch.openMarket(0);
        
        // Alice bets at odds1
        _placeBet(alice, 0, 0, betAmount1);
        
        // Change odds
        vm.prank(oddsSetter);
        footballMatch.setMarketOdds(0, odds2);
        
        // Bob bets at odds2
        _placeBet(bob, 0, 0, betAmount2);
        
        // Change odds again
        vm.prank(oddsSetter);
        footballMatch.setMarketOdds(0, odds3);
        
        // Close and resolve - Home wins
        vm.prank(owner);
        footballMatch.closeMarket(0);
        vm.prank(resolver);
        footballMatch.resolveMarket(0, 0);
        
        // Calculate expected payouts
        uint256 expectedAlicePayout = (uint256(betAmount1) * odds1) / ODDS_PRECISION;
        uint256 expectedBobPayout = (uint256(betAmount2) * odds2) / ODDS_PRECISION;
        
        // Claim and verify
        uint256 aliceBalanceBefore = usdt.balanceOf(alice);
        vm.prank(alice);
        footballMatch.claim(0, 0);
        assertEq(
            usdt.balanceOf(alice) - aliceBalanceBefore, 
            expectedAlicePayout, 
            "Alice payout incorrect"
        );
        
        uint256 bobBalanceBefore = usdt.balanceOf(bob);
        vm.prank(bob);
        footballMatch.claim(0, 0);
        assertEq(
            usdt.balanceOf(bob) - bobBalanceBefore, 
            expectedBobPayout, 
            "Bob payout incorrect"
        );
    }
    
    // ══════════════════════════════════════════════════════════════════════════
    // SECURITY TESTS
    // ══════════════════════════════════════════════════════════════════════════
    
    function test_Security_OnlyOddsSetterCanChangeOdds() public {
        vm.prank(owner);
        footballMatch.addMarketWithLine(MARKET_WINNER, 20000, 0);
        
        vm.prank(owner);
        footballMatch.openMarket(0);
        
        // Random user cannot change odds
        vm.prank(alice);
        vm.expectRevert();
        footballMatch.setMarketOdds(0, 25000);
        
        // Odds setter can change
        vm.prank(oddsSetter);
        footballMatch.setMarketOdds(0, 25000);
        assertEq(footballMatch.getCurrentOdds(0), 25000);
    }
    
    function test_Security_CannotBetOnClosedMarket() public {
        vm.prank(owner);
        footballMatch.addMarketWithLine(MARKET_WINNER, 20000, 0);
        
        // Market is Inactive, cannot bet
        vm.startPrank(alice);
        usdt.approve(address(footballMatch), 100e6);
        vm.expectRevert();
        footballMatch.placeBetUSDT(0, 0, 100e6);
        vm.stopPrank();
        
        // Open market
        vm.prank(owner);
        footballMatch.openMarket(0);
        
        // Now can bet
        _placeBet(alice, 0, 0, 100e6);
        
        // Close market
        vm.prank(owner);
        footballMatch.closeMarket(0);
        
        // Cannot bet on closed market
        vm.startPrank(bob);
        usdt.approve(address(footballMatch), 100e6);
        vm.expectRevert();
        footballMatch.placeBetUSDT(0, 0, 100e6);
        vm.stopPrank();
    }
    
    function test_Security_CannotClaimBeforeResolution() public {
        vm.prank(owner);
        footballMatch.addMarketWithLine(MARKET_WINNER, 20000, 0);
        
        vm.prank(owner);
        footballMatch.openMarket(0);
        
        _placeBet(alice, 0, 0, 100e6);
        
        // Cannot claim before resolution
        vm.prank(alice);
        vm.expectRevert();
        footballMatch.claim(0, 0);
    }
    
    function test_Security_CannotDoubleClaim() public {
        vm.prank(owner);
        footballMatch.addMarketWithLine(MARKET_WINNER, 20000, 0);
        
        vm.prank(owner);
        footballMatch.openMarket(0);
        
        _placeBet(alice, 0, 0, 100e6);
        
        vm.prank(owner);
        footballMatch.closeMarket(0);
        vm.prank(resolver);
        footballMatch.resolveMarket(0, 0);
        
        // First claim succeeds
        vm.prank(alice);
        footballMatch.claim(0, 0);
        
        // Second claim fails
        vm.prank(alice);
        vm.expectRevert();
        footballMatch.claim(0, 0);
    }
    
    function test_Security_LosingBetCannotClaim() public {
        vm.prank(owner);
        footballMatch.addMarketWithLine(MARKET_WINNER, 20000, 0);
        
        vm.prank(owner);
        footballMatch.openMarket(0);
        
        // Alice bets on Home (0)
        _placeBet(alice, 0, 0, 100e6);
        
        // Close and resolve - Away wins (1)
        vm.prank(owner);
        footballMatch.closeMarket(0);
        vm.prank(resolver);
        footballMatch.resolveMarket(0, 1);
        
        // Alice cannot claim (she bet on Home, Away won)
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                BettingMatch.BetLost.selector,
                0,
                alice,
                0
            )
        );
        footballMatch.claim(0, 0);
    }
    
    function test_Security_RefundOnCancelledMarket() public {
        vm.prank(owner);
        footballMatch.addMarketWithLine(MARKET_WINNER, 20000, 0);
        
        vm.prank(owner);
        footballMatch.openMarket(0);
        
        _placeBet(alice, 0, 0, 100e6);
        
        // Cancel market
        vm.prank(owner);
        footballMatch.cancelMarket(0, "Match postponed");
        
        // Alice can claim refund
        uint256 balanceBefore = usdt.balanceOf(alice);
        vm.prank(alice);
        footballMatch.claimRefund(0, 0);
        
        assertEq(usdt.balanceOf(alice) - balanceBefore, 100e6, "Should refund full amount");
    }
    
    // ══════════════════════════════════════════════════════════════════════════
    // MULTIPLE BETS PER USER
    // ══════════════════════════════════════════════════════════════════════════
    
    function test_MultipleBetsPerUser() public {
        vm.prank(owner);
        footballMatch.addMarketWithLine(MARKET_WINNER, 20000, 0);
        
        vm.prank(owner);
        footballMatch.openMarket(0);
        
        // Alice places first bet at 2.00x (100 USDT)
        _placeBet(alice, 0, 0, 100e6);
        
        // Odds change
        vm.prank(oddsSetter);
        footballMatch.setMarketOdds(0, 25000);
        
        // Alice places second bet at 2.50x (200 USDT)
        _placeBet(alice, 0, 0, 200e6);
        
        // Verify Alice has 2 bets
        BettingMatch.Bet[] memory aliceBets = footballMatch.getUserBets(0, alice);
        assertEq(aliceBets.length, 2, "Alice should have 2 bets");
        
        // Close and resolve
        vm.prank(owner);
        footballMatch.closeMarket(0);
        vm.prank(resolver);
        footballMatch.resolveMarket(0, 0);
        
        // Claim first bet: 100 USDT * 2.00x = 200 USDT
        uint256 balance1 = usdt.balanceOf(alice);
        vm.prank(alice);
        footballMatch.claim(0, 0);
        assertEq(usdt.balanceOf(alice) - balance1, 200e6, "First bet: 100 USDT * 2.00x");
        
        // Claim second bet: 200 USDT * 2.50x = 500 USDT
        uint256 balance2 = usdt.balanceOf(alice);
        vm.prank(alice);
        footballMatch.claim(0, 1);
        assertEq(usdt.balanceOf(alice) - balance2, 500e6, "Second bet: 200 USDT * 2.50x");
    }
    
    // ══════════════════════════════════════════════════════════════════════════
    // BATCH CLAIM
    // ══════════════════════════════════════════════════════════════════════════
    
    function test_ClaimAll() public {
        vm.prank(owner);
        footballMatch.addMarketWithLine(MARKET_WINNER, 20000, 0);
        
        vm.prank(owner);
        footballMatch.openMarket(0);
        
        // Alice places multiple bets at different odds (100 USDT each)
        _placeBet(alice, 0, 0, 100e6);
        
        vm.prank(oddsSetter);
        footballMatch.setMarketOdds(0, 21000);
        
        _placeBet(alice, 0, 0, 100e6);
        
        vm.prank(oddsSetter);
        footballMatch.setMarketOdds(0, 22000);
        
        _placeBet(alice, 0, 0, 100e6);
        
        // Close and resolve
        vm.prank(owner);
        footballMatch.closeMarket(0);
        vm.prank(resolver);
        footballMatch.resolveMarket(0, 0);
        
        // Claim all at once
        uint256 balanceBefore = usdt.balanceOf(alice);
        vm.prank(alice);
        footballMatch.claimAll(0);
        
        // Expected: 100*2.00 + 100*2.10 + 100*2.20 = 200 + 210 + 220 = 630 USDT
        uint256 expectedTotal = 200e6 + 210e6 + 220e6;
        assertEq(usdt.balanceOf(alice) - balanceBefore, expectedTotal, "Should claim all winnings");
    }
    
    // ══════════════════════════════════════════════════════════════════════════
    // ODDS BOUNDS
    // ══════════════════════════════════════════════════════════════════════════
    
    function test_OddsBoundsValidation() public {
        // Below minimum (1.0001x = 10001)
        vm.prank(owner);
        vm.expectRevert();
        footballMatch.addMarketWithLine(MARKET_WINNER, 10000, 0); // 1.00x not allowed
        
        // Above maximum (100x = 1000000)
        vm.prank(owner);
        vm.expectRevert();
        footballMatch.addMarketWithLine(MARKET_WINNER, 1000001, 0);
        
        // Valid odds
        vm.prank(owner);
        footballMatch.addMarketWithLine(MARKET_WINNER, 10001, 0); // 1.0001x OK
        
        vm.prank(owner);
        footballMatch.addMarketWithLine(MARKET_WINNER, 1000000, 0); // 100x OK
    }
}

/**
 * @title BettingMatchGasTest
 * @notice Gas benchmarks for USDT betting operations
 */
contract BettingMatchGasTest is Test {
    FootballMatch public implementation;
    FootballMatch public footballMatch;
    MockUSDT public usdt;
    
    address public owner = address(0x1);
    
    // Cached market type constant
    bytes32 constant MARKET_WINNER = keccak256("WINNER");
    bytes32 constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    
    function setUp() public {
        usdt = new MockUSDT();
        implementation = new FootballMatch();
        
        bytes memory initData = abi.encodeWithSelector(
            FootballMatch.initialize.selector,
            "Test Match",
            owner
        );
        
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        footballMatch = FootballMatch(payable(address(proxy)));
        
        // Configure USDT
        vm.prank(owner);
        footballMatch.setUSDTToken(address(usdt));
        
        // Fund this test contract and the match with USDT
        usdt.mint(address(this), 1_000_000e6);
        usdt.mint(address(footballMatch), 10_000_000e6);
    }
    
    function test_GasBenchmark_PlaceBetNewOdds() public {
        vm.prank(owner);
        footballMatch.addMarketWithLine(MARKET_WINNER, 20000, 0);
        
        vm.prank(owner);
        footballMatch.openMarket(0);
        
        // Approve and place first bet 
        usdt.approve(address(footballMatch), 100e6);
        uint256 gasBefore = gasleft();
        footballMatch.placeBetUSDT(0, 0, 100e6);
        uint256 gasUsed = gasBefore - gasleft();
        
        console.log("Gas for first USDT bet (new odds):", gasUsed);
    }
    
    function test_GasBenchmark_PlaceBetExistingOdds() public {
        vm.prank(owner);
        footballMatch.addMarketWithLine(MARKET_WINNER, 20000, 0);
        
        vm.prank(owner);
        footballMatch.openMarket(0);
        
        // First bet
        usdt.approve(address(footballMatch), 200e6);
        footballMatch.placeBetUSDT(0, 0, 100e6);
        
        // Second bet reuses existing odds
        uint256 gasBefore = gasleft();
        footballMatch.placeBetUSDT(0, 0, 100e6);
        uint256 gasUsed = gasBefore - gasleft();
        
        console.log("Gas for subsequent USDT bet (existing odds):", gasUsed);
    }
    
    function test_GasBenchmark_SetNewOdds() public {
        vm.prank(owner);
        footballMatch.addMarketWithLine(MARKET_WINNER, 20000, 0);
        
        vm.prank(owner);
        footballMatch.openMarket(0);
        
        vm.startPrank(owner);
        
        // New odds (not in registry)
        uint256 gas1 = gasleft();
        footballMatch.setMarketOdds(0, 21000);
        console.log("Gas for new odds entry:", gas1 - gasleft());
        
        // Another new odds
        uint256 gas2 = gasleft();
        footballMatch.setMarketOdds(0, 22000);
        console.log("Gas for another new odds:", gas2 - gasleft());
        
        // Existing odds (should be cheaper)
        uint256 gas3 = gasleft();
        footballMatch.setMarketOdds(0, 20000);
        console.log("Gas for existing odds (reuse):", gas3 - gasleft());
        
        vm.stopPrank();
    }
}
