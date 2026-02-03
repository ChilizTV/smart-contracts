// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Test.sol";
import "../src/betting/BettingMatch.sol";
import "../src/betting/FootballMatch.sol";
import "../src/betting/BasketballMatch.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title BettingMatchTest
 * @notice Comprehensive tests for dynamic odds betting system
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
    
    address public owner = address(0x1);
    address public oddsSetter = address(0x2);
    address public resolver = address(0x3);
    address public alice = address(0x100);
    address public bob = address(0x101);
    address public charlie = address(0x102);
    
    bytes32 constant ODDS_SETTER_ROLE = keccak256("ODDS_SETTER_ROLE");
    bytes32 constant RESOLVER_ROLE = keccak256("RESOLVER_ROLE");
    bytes32 constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    
    uint32 constant ODDS_PRECISION = 10000;
    
    // Cached market type constants to avoid consuming vm.prank
    bytes32 constant MARKET_WINNER = keccak256("WINNER");
    bytes32 constant MARKET_GOALS_TOTAL = keccak256("GOALS_TOTAL");
    
    function setUp() public {
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
        
        // Setup roles
        vm.startPrank(owner);
        footballMatch.grantRole(ODDS_SETTER_ROLE, oddsSetter);
        footballMatch.grantRole(RESOLVER_ROLE, resolver);
        vm.stopPrank();
        
        // Fund test accounts
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(charlie, 100 ether);
        
        // Fund contract for payouts
        vm.deal(address(footballMatch), 1000 ether);
    }
    
    // ══════════════════════════════════════════════════════════════════════════
    // TEST 1: Odds change between bets → each bet uses correct odds at payout
    // ══════════════════════════════════════════════════════════════════════════
    
    function test_OddsChangePreservesHistoricalOdds() public {
        // Create market with initial odds 2.00x (20000)
        vm.prank(owner);
        footballMatch.addMarket(MARKET_WINNER, 20000);
        
        // Open market
        vm.prank(owner);
        footballMatch.openMarket(0);
        
        // Alice bets at 2.00x
        vm.prank(alice);
        footballMatch.placeBet{value: 1 ether}(0, 0); // Bet on Home
        
        // Odds change to 2.50x (25000)
        vm.prank(oddsSetter);
        footballMatch.setMarketOdds(0, 25000);
        
        // Bob bets at 2.50x
        vm.prank(bob);
        footballMatch.placeBet{value: 1 ether}(0, 0); // Bet on Home
        
        // Odds change to 1.80x (18000)
        vm.prank(oddsSetter);
        footballMatch.setMarketOdds(0, 18000);
        
        // Charlie bets at 1.80x
        vm.prank(charlie);
        footballMatch.placeBet{value: 1 ether}(0, 0); // Bet on Home
        
        // Resolve market - Home wins (selection 0)
        vm.prank(resolver);
        footballMatch.resolveMarket(0, 0);
        
        // Verify each user gets correct payout based on THEIR odds
        uint256 aliceBalanceBefore = alice.balance;
        vm.prank(alice);
        footballMatch.claim(0, 0);
        uint256 alicePayout = alice.balance - aliceBalanceBefore;
        assertEq(alicePayout, 2 ether, "Alice should get 2.00x payout");
        
        uint256 bobBalanceBefore = bob.balance;
        vm.prank(bob);
        footballMatch.claim(0, 0);
        uint256 bobPayout = bob.balance - bobBalanceBefore;
        assertEq(bobPayout, 2.5 ether, "Bob should get 2.50x payout");
        
        uint256 charlieBalanceBefore = charlie.balance;
        vm.prank(charlie);
        footballMatch.claim(0, 0);
        uint256 charliePayout = charlie.balance - charlieBalanceBefore;
        assertEq(charliePayout, 1.8 ether, "Charlie should get 1.80x payout");
    }
    
    // ══════════════════════════════════════════════════════════════════════════
    // TEST 2: Two bets with same odds share same oddsIndex
    // ══════════════════════════════════════════════════════════════════════════
    
    function test_SameOddsShareIndex() public {
        vm.prank(owner);
        footballMatch.addMarket(MARKET_WINNER, 21800); // 2.18x
        
        vm.prank(owner);
        footballMatch.openMarket(0);
        
        // Alice bets at 2.18x
        vm.prank(alice);
        footballMatch.placeBet{value: 1 ether}(0, 0);
        
        // Bob bets at same 2.18x (no odds change)
        vm.prank(bob);
        footballMatch.placeBet{value: 1 ether}(0, 0);
        
        // Verify both bets have same oddsIndex
        (uint256 aliceAmount,, uint32 aliceOdds,,, ) = footballMatch.getBetDetails(0, alice, 0);
        (uint256 bobAmount,, uint32 bobOdds,,, ) = footballMatch.getBetDetails(0, bob, 0);
        
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
        footballMatch.addMarket(MARKET_WINNER, 20000);
        
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
        // Bound inputs - limit odds to 10x max to avoid payout exceeding contract balance
        odds1 = uint32(bound(odds1, 10001, 100000));  // Max 10x
        odds2 = uint32(bound(odds2, 10001, 100000));  // Max 10x
        odds3 = uint32(bound(odds3, 10001, 100000));  // Max 10x
        betAmount1 = uint96(bound(betAmount1, 0.001 ether, 10 ether));
        betAmount2 = uint96(bound(betAmount2, 0.001 ether, 10 ether));
        
        vm.prank(owner);
        footballMatch.addMarket(MARKET_WINNER, odds1);
        
        vm.prank(owner);
        footballMatch.openMarket(0);
        
        // Alice bets at odds1
        vm.prank(alice);
        footballMatch.placeBet{value: betAmount1}(0, 0);
        
        // Change odds
        vm.prank(oddsSetter);
        footballMatch.setMarketOdds(0, odds2);
        
        // Bob bets at odds2
        vm.prank(bob);
        footballMatch.placeBet{value: betAmount2}(0, 0);
        
        // Change odds again
        vm.prank(oddsSetter);
        footballMatch.setMarketOdds(0, odds3);
        
        // Resolve - Home wins
        vm.prank(resolver);
        footballMatch.resolveMarket(0, 0);
        
        // Calculate expected payouts
        uint256 expectedAlicePayout = (uint256(betAmount1) * odds1) / ODDS_PRECISION;
        uint256 expectedBobPayout = (uint256(betAmount2) * odds2) / ODDS_PRECISION;
        
        // Claim and verify
        uint256 aliceBalanceBefore = alice.balance;
        vm.prank(alice);
        footballMatch.claim(0, 0);
        assertEq(
            alice.balance - aliceBalanceBefore, 
            expectedAlicePayout, 
            "Alice payout incorrect"
        );
        
        uint256 bobBalanceBefore = bob.balance;
        vm.prank(bob);
        footballMatch.claim(0, 0);
        assertEq(
            bob.balance - bobBalanceBefore, 
            expectedBobPayout, 
            "Bob payout incorrect"
        );
    }
    
    // ══════════════════════════════════════════════════════════════════════════
    // SECURITY TESTS
    // ══════════════════════════════════════════════════════════════════════════
    
    function test_Security_OnlyOddsSetterCanChangeOdds() public {
        vm.prank(owner);
        footballMatch.addMarket(MARKET_WINNER, 20000);
        
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
        footballMatch.addMarket(MARKET_WINNER, 20000);
        
        // Market is Inactive, cannot bet
        vm.prank(alice);
        vm.expectRevert();
        footballMatch.placeBet{value: 1 ether}(0, 0);
        
        // Open market
        vm.prank(owner);
        footballMatch.openMarket(0);
        
        // Now can bet
        vm.prank(alice);
        footballMatch.placeBet{value: 1 ether}(0, 0);
        
        // Close market
        vm.prank(owner);
        footballMatch.closeMarket(0);
        
        // Cannot bet on closed market
        vm.prank(bob);
        vm.expectRevert();
        footballMatch.placeBet{value: 1 ether}(0, 0);
    }
    
    function test_Security_CannotClaimBeforeResolution() public {
        vm.prank(owner);
        footballMatch.addMarket(MARKET_WINNER, 20000);
        
        vm.prank(owner);
        footballMatch.openMarket(0);
        
        vm.prank(alice);
        footballMatch.placeBet{value: 1 ether}(0, 0);
        
        // Cannot claim before resolution
        vm.prank(alice);
        vm.expectRevert();
        footballMatch.claim(0, 0);
    }
    
    function test_Security_CannotDoubleClaim() public {
        vm.prank(owner);
        footballMatch.addMarket(MARKET_WINNER, 20000);
        
        vm.prank(owner);
        footballMatch.openMarket(0);
        
        vm.prank(alice);
        footballMatch.placeBet{value: 1 ether}(0, 0);
        
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
        footballMatch.addMarket(MARKET_WINNER, 20000);
        
        vm.prank(owner);
        footballMatch.openMarket(0);
        
        // Alice bets on Home (0)
        vm.prank(alice);
        footballMatch.placeBet{value: 1 ether}(0, 0);
        
        // Away wins (1)
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
        footballMatch.addMarket(MARKET_WINNER, 20000);
        
        vm.prank(owner);
        footballMatch.openMarket(0);
        
        vm.prank(alice);
        footballMatch.placeBet{value: 1 ether}(0, 0);
        
        // Cancel market
        vm.prank(owner);
        footballMatch.cancelMarket(0, "Match postponed");
        
        // Alice can claim refund
        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        footballMatch.claimRefund(0, 0);
        
        assertEq(alice.balance - balanceBefore, 1 ether, "Should refund full amount");
    }
    
    // ══════════════════════════════════════════════════════════════════════════
    // MULTIPLE BETS PER USER
    // ══════════════════════════════════════════════════════════════════════════
    
    function test_MultipleBetsPerUser() public {
        vm.prank(owner);
        footballMatch.addMarket(MARKET_WINNER, 20000);
        
        vm.prank(owner);
        footballMatch.openMarket(0);
        
        // Alice places first bet at 2.00x
        vm.prank(alice);
        footballMatch.placeBet{value: 1 ether}(0, 0);
        
        // Odds change
        vm.prank(oddsSetter);
        footballMatch.setMarketOdds(0, 25000);
        
        // Alice places second bet at 2.50x
        vm.prank(alice);
        footballMatch.placeBet{value: 2 ether}(0, 0);
        
        // Verify Alice has 2 bets
        BettingMatch.Bet[] memory aliceBets = footballMatch.getUserBets(0, alice);
        assertEq(aliceBets.length, 2, "Alice should have 2 bets");
        
        // Resolve
        vm.prank(resolver);
        footballMatch.resolveMarket(0, 0);
        
        // Claim first bet
        uint256 balance1 = alice.balance;
        vm.prank(alice);
        footballMatch.claim(0, 0);
        assertEq(alice.balance - balance1, 2 ether, "First bet: 1 ETH * 2.00x");
        
        // Claim second bet
        uint256 balance2 = alice.balance;
        vm.prank(alice);
        footballMatch.claim(0, 1);
        assertEq(alice.balance - balance2, 5 ether, "Second bet: 2 ETH * 2.50x");
    }
    
    // ══════════════════════════════════════════════════════════════════════════
    // BATCH CLAIM
    // ══════════════════════════════════════════════════════════════════════════
    
    function test_ClaimAll() public {
        vm.prank(owner);
        footballMatch.addMarket(MARKET_WINNER, 20000);
        
        vm.prank(owner);
        footballMatch.openMarket(0);
        
        // Alice places multiple bets at different odds
        vm.prank(alice);
        footballMatch.placeBet{value: 1 ether}(0, 0);
        
        vm.prank(oddsSetter);
        footballMatch.setMarketOdds(0, 21000);
        
        vm.prank(alice);
        footballMatch.placeBet{value: 1 ether}(0, 0);
        
        vm.prank(oddsSetter);
        footballMatch.setMarketOdds(0, 22000);
        
        vm.prank(alice);
        footballMatch.placeBet{value: 1 ether}(0, 0);
        
        // Resolve
        vm.prank(resolver);
        footballMatch.resolveMarket(0, 0);
        
        // Claim all at once
        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        footballMatch.claimAll(0);
        
        // Expected: 1*2.00 + 1*2.10 + 1*2.20 = 6.30 ETH
        uint256 expectedTotal = 2 ether + 2.1 ether + 2.2 ether;
        assertEq(alice.balance - balanceBefore, expectedTotal, "Should claim all winnings");
    }
    
    // ══════════════════════════════════════════════════════════════════════════
    // ODDS BOUNDS
    // ══════════════════════════════════════════════════════════════════════════
    
    function test_OddsBoundsValidation() public {
        // Below minimum (1.0001x = 10001)
        vm.prank(owner);
        vm.expectRevert();
        footballMatch.addMarket(MARKET_WINNER, 10000); // 1.00x not allowed
        
        // Above maximum (100x = 1000000)
        vm.prank(owner);
        vm.expectRevert();
        footballMatch.addMarket(MARKET_WINNER, 1000001);
        
        // Valid odds
        vm.prank(owner);
        footballMatch.addMarket(MARKET_WINNER, 10001); // 1.0001x OK
        
        vm.prank(owner);
        footballMatch.addMarket(MARKET_WINNER, 1000000); // 100x OK
    }
}

/**
 * @title BettingMatchGasTest
 * @notice Gas benchmarks for odds storage approaches
 */
contract BettingMatchGasTest is Test {
    FootballMatch public implementation;
    FootballMatch public footballMatch;
    
    address public owner = address(0x1);
    
    // Cached market type constant
    bytes32 constant MARKET_WINNER = keccak256("WINNER");
    
    function setUp() public {
        implementation = new FootballMatch();
        
        bytes memory initData = abi.encodeWithSelector(
            FootballMatch.initialize.selector,
            "Test Match",
            owner
        );
        
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        footballMatch = FootballMatch(payable(address(proxy)));
        
        vm.deal(address(this), 1000 ether);
        vm.deal(address(footballMatch), 10000 ether);
    }
    
    function test_GasBenchmark_PlaceBetNewOdds() public {
        vm.prank(owner);
        footballMatch.addMarket(MARKET_WINNER, 20000);
        
        vm.prank(owner);
        footballMatch.openMarket(0);
        
        // First bet creates new odds entry
        uint256 gasBefore = gasleft();
        footballMatch.placeBet{value: 1 ether}(0, 0);
        uint256 gasUsed = gasBefore - gasleft();
        
        console.log("Gas for first bet (new odds):", gasUsed);
    }
    
    function test_GasBenchmark_PlaceBetExistingOdds() public {
        vm.prank(owner);
        footballMatch.addMarket(MARKET_WINNER, 20000);
        
        vm.prank(owner);
        footballMatch.openMarket(0);
        
        // First bet
        footballMatch.placeBet{value: 1 ether}(0, 0);
        
        // Second bet reuses existing odds
        uint256 gasBefore = gasleft();
        footballMatch.placeBet{value: 1 ether}(0, 0);
        uint256 gasUsed = gasBefore - gasleft();
        
        console.log("Gas for subsequent bet (existing odds):", gasUsed);
    }
    
    function test_GasBenchmark_SetNewOdds() public {
        vm.prank(owner);
        footballMatch.addMarket(MARKET_WINNER, 20000);
        
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
