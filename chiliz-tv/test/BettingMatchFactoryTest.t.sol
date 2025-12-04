// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/betting/BettingMatchFactory.sol";
import "../src/betting/FootballMatch.sol";
import "../src/betting/BasketballMatch.sol";

contract BettingMatchFactoryTest is Test {
    BettingMatchFactory public factory;
    
    address public owner = address(this);
    address public user1 = address(0x1);
    address public user2 = address(0x2);
    
    event MatchCreated(address indexed proxy, BettingMatchFactory.SportType sportType, address indexed owner);

    function setUp() public {
        // Deploy factory (deploys implementations internally)
        factory = new BettingMatchFactory();
        
        vm.deal(owner, 100 ether);
        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);
    }

    function testFactoryInitialization() public {
        assertEq(factory.owner(), owner);
    }

    function testCreateFootballMatch() public {
        vm.expectEmit(false, false, true, false);
        emit MatchCreated(address(0), BettingMatchFactory.SportType.FOOTBALL, user1);
        
        address proxy = factory.createFootballMatch("Barcelona vs Real Madrid", user1);
        
        assertFalse(proxy == address(0));
        assertEq(factory.getAllMatches().length, 1);
        assertEq(factory.getAllMatches()[0], proxy);
        assertTrue(factory.getSportType(proxy) == BettingMatchFactory.SportType.FOOTBALL);
        
        // Verify the proxy is initialized correctly
        FootballMatch footballMatch = FootballMatch(payable(proxy));
        assertEq(footballMatch.matchName(), "Barcelona vs Real Madrid");
        assertEq(footballMatch.sportType(), "FOOTBALL");
        assertEq(footballMatch.owner(), user1);
    }

    function testCreateBasketballMatch() public {
        vm.expectEmit(false, false, true, false);
        emit MatchCreated(address(0), BettingMatchFactory.SportType.BASKETBALL, user2);
        
        address proxy = factory.createBasketballMatch("Lakers vs Celtics", user2);
        
        assertFalse(proxy == address(0));
        assertEq(factory.getAllMatches().length, 1);
        assertEq(factory.getAllMatches()[0], proxy);
        assertTrue(factory.getSportType(proxy) == BettingMatchFactory.SportType.BASKETBALL);
        
        // Verify the proxy is initialized correctly
        BasketballMatch basketballMatch = BasketballMatch(payable(proxy));
        assertEq(basketballMatch.matchName(), "Lakers vs Celtics");
        assertEq(basketballMatch.sportType(), "BASKETBALL");
        assertEq(basketballMatch.owner(), user2);
    }

    function testCreateMultipleFootballMatches() public {
        address proxy1 = factory.createFootballMatch("Match 1", user1);
        address proxy2 = factory.createFootballMatch("Match 2", user2);
        address proxy3 = factory.createFootballMatch("Match 3", user1);
        
        assertEq(factory.getAllMatches().length, 3);
        assertEq(factory.getAllMatches()[0], proxy1);
        assertEq(factory.getAllMatches()[1], proxy2);
        assertEq(factory.getAllMatches()[2], proxy3);
    }

    function testCreateMultipleBasketballMatches() public {
        address proxy1 = factory.createBasketballMatch("Game 1", user1);
        address proxy2 = factory.createBasketballMatch("Game 2", user2);
        
        assertEq(factory.getAllMatches().length, 2);
        assertTrue(factory.getSportType(proxy1) == BettingMatchFactory.SportType.BASKETBALL);
        assertTrue(factory.getSportType(proxy2) == BettingMatchFactory.SportType.BASKETBALL);
    }

    function testCreateMixedSportMatches() public {
        address footballProxy1 = factory.createFootballMatch("Football 1", user1);
        address basketballProxy1 = factory.createBasketballMatch("Basketball 1", user2);
        address footballProxy2 = factory.createFootballMatch("Football 2", user1);
        address basketballProxy2 = factory.createBasketballMatch("Basketball 2", user2);
        
        assertEq(factory.getAllMatches().length, 4);
        assertTrue(factory.getSportType(footballProxy1) == BettingMatchFactory.SportType.FOOTBALL);
        assertTrue(factory.getSportType(basketballProxy1) == BettingMatchFactory.SportType.BASKETBALL);
        assertTrue(factory.getSportType(footballProxy2) == BettingMatchFactory.SportType.FOOTBALL);
        assertTrue(factory.getSportType(basketballProxy2) == BettingMatchFactory.SportType.BASKETBALL);
    }

    function testGetAllMatchesReturnsEmpty() public {
        assertEq(factory.getAllMatches().length, 0);
    }

    function testFootballMatchCanReceiveBets() public {
        address proxy = factory.createFootballMatch("Test Match", user1);
        FootballMatch footballMatch = FootballMatch(payable(proxy));
        
        // User1 (owner) adds market
        vm.prank(user1);
        footballMatch.addMarket("Winner", 200);
        
        // User2 places bet
        vm.prank(user2);
        footballMatch.placeBet{value: 1 ether}(0, 0);
        
        (uint256 amount, , ) = footballMatch.getBet(0, user2);
        assertEq(amount, 1 ether);
    }

    function testBasketballMatchCanReceiveBets() public {
        address proxy = factory.createBasketballMatch("Test Game", user1);
        BasketballMatch basketballMatch = BasketballMatch(payable(proxy));
        
        // User1 (owner) adds market
        vm.prank(user1);
        basketballMatch.addMarket("Winner", 180);
        
        // User2 places bet
        vm.prank(user2);
        basketballMatch.placeBet{value: 2 ether}(0, 1);
        
        (uint256 amount, , ) = basketballMatch.getBet(0, user2);
        assertEq(amount, 2 ether);
    }

    function testCompleteFootballMatchFlow() public {
        // Create football match
        address proxy = factory.createFootballMatch("Champions League Final", user1);
        FootballMatch footballMatch = FootballMatch(payable(proxy));
        
        // Add market
        vm.prank(user1);
        footballMatch.addMarket("Winner", 250);
        
        // Place bet
        vm.prank(user2);
        footballMatch.placeBet{value: 1 ether}(0, 0);
        
        // Add liquidity
        vm.prank(user1);
        payable(address(footballMatch)).transfer(5 ether);
        
        // Resolve market
        vm.prank(user1);
        footballMatch.resolveMarket(0, 0);
        
        // Claim payout
        uint256 balanceBefore = user2.balance;
        vm.prank(user2);
        footballMatch.claim(0);
        assertEq(user2.balance - balanceBefore, 2.5 ether);
    }

    function testCompleteBasketballMatchFlow() public {
        // Create basketball match
        address proxy = factory.createBasketballMatch("NBA Finals", user1);
        BasketballMatch basketballMatch = BasketballMatch(payable(proxy));
        
        // Add market
        vm.prank(user1);
        basketballMatch.addMarket("TotalPoints", 200);
        
        // Place bet
        vm.prank(user2);
        basketballMatch.placeBet{value: 2 ether}(0, 1);
        
        // Add liquidity
        vm.prank(user1);
        payable(address(basketballMatch)).transfer(10 ether);
        
        // Resolve market
        vm.prank(user1);
        basketballMatch.resolveMarket(0, 1);
        
        // Claim payout
        uint256 balanceBefore = user2.balance;
        vm.prank(user2);
        basketballMatch.claim(0);
        assertEq(user2.balance - balanceBefore, 4 ether);
    }

    function testDifferentOwnersForDifferentMatches() public {
        address footballProxy = factory.createFootballMatch("Football Match", user1);
        address basketballProxy = factory.createBasketballMatch("Basketball Match", user2);
        
        FootballMatch footballMatch = FootballMatch(payable(footballProxy));
        BasketballMatch basketballMatch = BasketballMatch(payable(basketballProxy));
        
        assertEq(footballMatch.owner(), user1);
        assertEq(basketballMatch.owner(), user2);
        
        // User1 can add markets to football match
        vm.prank(user1);
        footballMatch.addMarket("Winner", 200);
        
        // User2 can add markets to basketball match
        vm.prank(user2);
        basketballMatch.addMarket("Winner", 180);
        
        // User1 cannot add markets to basketball match
        vm.prank(user1);
        vm.expectRevert();
        basketballMatch.addMarket("TotalPoints", 200);
        
        // User2 cannot add markets to football match
        vm.prank(user2);
        vm.expectRevert();
        footballMatch.addMarket("GoalsCount", 300);
    }
}
