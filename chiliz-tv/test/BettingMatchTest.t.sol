// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/betting/BettingMatch.sol";
import "../src/betting/BettingMatchFactory.sol";

/**
 * @title BettingMatchTest
 * @notice Comprehensive tests for BettingMatch UUPS system
 */
contract BettingMatchTest is Test {
    BettingMatch public implementation;
    BettingMatchFactory public factory;
    BettingMatch public bettingMatch;
    
    address public owner = address(1);
    address public user1 = address(2);
    address public user2 = address(3);
    
    function setUp() public {
        // Deploy implementation
        implementation = new BettingMatch();
        
        // Deploy factory
        factory = new BettingMatchFactory(address(implementation));
        
        // Create a match
        vm.prank(owner);
        address matchProxy = factory.createMatch("Real Madrid vs Barcelona", owner);
        bettingMatch = BettingMatch(payable(matchProxy));
        
        // Fund users with CHZ
        vm.deal(owner, 100 ether);
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
    }
    
    // ============================================================================
    // INITIALIZATION TESTS
    // ============================================================================
    
    function testMatchInitialization() public view {
        assertEq(bettingMatch.matchName(), "Real Madrid vs Barcelona");
        assertEq(bettingMatch.owner(), owner);
        assertEq(bettingMatch.marketCount(), 0);
    }
    
    // ============================================================================
    // MARKET CREATION TESTS
    // ============================================================================
    
    function testAddMarket() public {
        vm.prank(owner);
        bettingMatch.addMarket(BettingMatch.MarketType.Winner, 150);
        
        assertEq(bettingMatch.marketCount(), 1);
    }
    
    function testAddMarketNonOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        bettingMatch.addMarket(BettingMatch.MarketType.Winner, 150);
    }
    
    function testAddMultipleMarkets() public {
        vm.startPrank(owner);
        bettingMatch.addMarket(BettingMatch.MarketType.Winner, 150);
        bettingMatch.addMarket(BettingMatch.MarketType.GoalsCount, 200);
        bettingMatch.addMarket(BettingMatch.MarketType.FirstScorer, 300);
        vm.stopPrank();
        
        assertEq(bettingMatch.marketCount(), 3);
    }
    
    // ============================================================================
    // BETTING TESTS
    // ============================================================================
    
    function testPlaceBet() public {
        // Add market
        vm.prank(owner);
        bettingMatch.addMarket(BettingMatch.MarketType.Winner, 150);
        
        // Place bet
        vm.prank(user1);
        bettingMatch.placeBet{value: 1 ether}(0, 1);
    }
    
    function testPlaceBetZeroAmount() public {
        vm.prank(owner);
        bettingMatch.addMarket(BettingMatch.MarketType.Winner, 150);
        
        vm.prank(user1);
        vm.expectRevert(BettingMatch.ZeroBet.selector);
        bettingMatch.placeBet{value: 0}(0, 1);
    }
    
    function testPlaceBetInvalidMarket() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(BettingMatch.InvalidMarket.selector, 0));
        bettingMatch.placeBet{value: 1 ether}(0, 1);
    }
    
    function testMultipleBets() public {
        vm.prank(owner);
        bettingMatch.addMarket(BettingMatch.MarketType.Winner, 150);
        
        vm.prank(user1);
        bettingMatch.placeBet{value: 1 ether}(0, 1);
        
        vm.prank(user2);
        bettingMatch.placeBet{value: 2 ether}(0, 2);
        
        assertEq(address(bettingMatch).balance, 3 ether);
    }
    
    // ============================================================================
    // RESOLUTION TESTS
    // ============================================================================
    
    function testResolveMarket() public {
        vm.prank(owner);
        bettingMatch.addMarket(BettingMatch.MarketType.Winner, 150);
        
        vm.prank(user1);
        bettingMatch.placeBet{value: 1 ether}(0, 1);
        
        vm.prank(owner);
        bettingMatch.resolveMarket(0, 1);
    }
    
    function testResolveMarketNonOwner() public {
        vm.prank(owner);
        bettingMatch.addMarket(BettingMatch.MarketType.Winner, 150);
        
        vm.prank(user1);
        vm.expectRevert();
        bettingMatch.resolveMarket(0, 1);
    }
    
    function testResolveMarketInvalid() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BettingMatch.InvalidMarket.selector, 0));
        bettingMatch.resolveMarket(0, 1);
    }
    
    // ============================================================================
    // CLAIM TESTS
    // ============================================================================
    
    function testClaimWinningBet() public {
        // Add market
        vm.prank(owner);
        bettingMatch.addMarket(BettingMatch.MarketType.Winner, 150);
        
        // Place bet
        vm.prank(user1);
        bettingMatch.placeBet{value: 1 ether}(0, 1);
        
        // Fund the contract with additional CHZ for payouts (owner sends liquidity)
        vm.prank(owner);
        (bool success, ) = address(bettingMatch).call{value: 1 ether}("");
        require(success, "Failed to fund contract");
        
        // Resolve with winning outcome
        vm.prank(owner);
        bettingMatch.resolveMarket(0, 1);
        
        // Claim
        uint256 balanceBefore = user1.balance;
        vm.prank(user1);
        bettingMatch.claim(0);
        uint256 balanceAfter = user1.balance;
        
        assertEq(balanceAfter - balanceBefore, 1.5 ether); // 1 ETH * 150 / 100
    }
    
    function testClaimLosingBet() public {
        vm.prank(owner);
        bettingMatch.addMarket(BettingMatch.MarketType.Winner, 150);
        
        vm.prank(user1);
        bettingMatch.placeBet{value: 1 ether}(0, 1);
        
        vm.prank(owner);
        bettingMatch.resolveMarket(0, 2); // Different outcome
        
        vm.prank(user1);
        vm.expectRevert(BettingMatch.Lost.selector);
        bettingMatch.claim(0);
    }
    
    function testClaimBeforeResolution() public {
        vm.prank(owner);
        bettingMatch.addMarket(BettingMatch.MarketType.Winner, 150);
        
        vm.prank(user1);
        bettingMatch.placeBet{value: 1 ether}(0, 1);
        
        vm.prank(user1);
        vm.expectRevert();
        bettingMatch.claim(0);
    }
    
    function testClaimNoBet() public {
        vm.prank(owner);
        bettingMatch.addMarket(BettingMatch.MarketType.Winner, 150);
        
        vm.prank(owner);
        bettingMatch.resolveMarket(0, 1);
        
        vm.prank(user1);
        vm.expectRevert(BettingMatch.NoBet.selector);
        bettingMatch.claim(0);
    }
    
    function testClaimTwice() public {
        vm.prank(owner);
        bettingMatch.addMarket(BettingMatch.MarketType.Winner, 150);
        
        vm.prank(user1);
        bettingMatch.placeBet{value: 1 ether}(0, 1);
        
        // Fund the contract with additional CHZ for payouts
        vm.prank(owner);
        (bool success, ) = address(bettingMatch).call{value: 1 ether}("");
        require(success, "Failed to fund contract");
        
        vm.prank(owner);
        bettingMatch.resolveMarket(0, 1);
        
        vm.prank(user1);
        bettingMatch.claim(0);
        
        vm.prank(user1);
        vm.expectRevert(BettingMatch.AlreadyClaimed.selector);
        bettingMatch.claim(0);
    }
    
    // ============================================================================
    // FACTORY TESTS
    // ============================================================================
    
    function testFactoryCreateMatch() public {
        address newMatch = factory.createMatch("PSG vs Lyon", owner);
        assertTrue(newMatch != address(0));
        
        BettingMatch newMatchContract = BettingMatch(payable(newMatch));
        assertEq(newMatchContract.matchName(), "PSG vs Lyon");
        assertEq(newMatchContract.owner(), owner);
    }
    
    function testFactoryUpdateImplementation() public {
        BettingMatch newImpl = new BettingMatch();
        
        factory.setImplementation(address(newImpl));
        assertEq(factory.implementation(), address(newImpl));
    }
    
    function testFactoryUpdateImplementationNonOwner() public {
        BettingMatch newImpl = new BettingMatch();
        
        vm.prank(user1);
        vm.expectRevert();
        factory.setImplementation(address(newImpl));
    }
}
