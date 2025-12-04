// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/betting/FootballMatch.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract FootballMatchTest is Test {
    FootballMatch public footballImpl;
    FootballMatch public footballMatch;
    
    address public owner = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);
    
    event MatchInitialized(string indexed name, string sportType, address indexed owner);
    event MarketAdded(uint256 indexed marketId, string marketType, uint256 odds);
    event BetPlaced(uint256 indexed marketId, address indexed user, uint256 amount, uint256 selection);
    event MarketResolved(uint256 indexed marketId, uint256 result);
    event Payout(uint256 indexed marketId, address indexed user, uint256 amount);

    function setUp() public {
        // Deploy implementation
        footballImpl = new FootballMatch();
        
        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(
            FootballMatch.initialize.selector,
            "Barcelona vs Real Madrid",
            owner
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(footballImpl), initData);
        footballMatch = FootballMatch(payable(address(proxy)));
        
        // Fund test accounts
        vm.deal(owner, 100 ether);
        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);
    }

    function testInitialization() public {
        assertEq(footballMatch.matchName(), "Barcelona vs Real Madrid");
        assertEq(footballMatch.sportType(), "FOOTBALL");
        assertEq(footballMatch.owner(), owner);
        assertEq(footballMatch.marketCount(), 0);
    }

    function testAddWinnerMarket() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit MarketAdded(0, "Winner", 250);
        footballMatch.addMarket("Winner", 250);
        
        assertEq(footballMatch.marketCount(), 1);
        
        (string memory mtype, uint256 odds, BettingMatch.State state, uint256 result) = footballMatch.getMarket(0);
        assertEq(mtype, "Winner");
        assertEq(odds, 250);
        assertTrue(state == BettingMatch.State.Live);
        assertEq(result, 0);
    }

    function testAddGoalsCountMarket() public {
        vm.prank(owner);
        footballMatch.addMarket("GoalsCount", 300);
        
        (string memory mtype, , , ) = footballMatch.getMarket(0);
        assertEq(mtype, "GoalsCount");
    }

    function testAddFirstScorerMarket() public {
        vm.prank(owner);
        footballMatch.addMarket("FirstScorer", 500);
        
        (string memory mtype, , , ) = footballMatch.getMarket(0);
        assertEq(mtype, "FirstScorer");
    }

    function testAddBothTeamsScoreMarket() public {
        vm.prank(owner);
        footballMatch.addMarket("BothTeamsScore", 180);
        
        (string memory mtype, , , ) = footballMatch.getMarket(0);
        assertEq(mtype, "BothTeamsScore");
    }

    function testAddMultipleMarkets() public {
        vm.startPrank(owner);
        footballMatch.addMarket("Winner", 250);
        footballMatch.addMarket("GoalsCount", 300);
        footballMatch.addMarket("FirstScorer", 500);
        vm.stopPrank();
        
        assertEq(footballMatch.marketCount(), 3);
    }

    function testOnlyOwnerCanAddMarket() public {
        vm.prank(user1);
        vm.expectRevert();
        footballMatch.addMarket("Winner", 250);
    }

    function testPlaceBetOnWinner() public {
        vm.prank(owner);
        footballMatch.addMarket("Winner", 200); // 2.0x odds
        
        vm.prank(user1);
        vm.expectEmit(true, true, false, true);
        emit BetPlaced(0, user1, 1 ether, 0); // Bet on Home (0)
        footballMatch.placeBet{value: 1 ether}(0, 0);
        
        (uint256 amount, uint256 selection, bool claimed) = footballMatch.getBet(0, user1);
        assertEq(amount, 1 ether);
        assertEq(selection, 0);
        assertFalse(claimed);
    }

    function testPlaceMultipleBets() public {
        vm.prank(owner);
        footballMatch.addMarket("Winner", 250);
        
        vm.prank(user1);
        footballMatch.placeBet{value: 1 ether}(0, 0); // Home
        
        vm.prank(user2);
        footballMatch.placeBet{value: 2 ether}(0, 2); // Away
        
        (uint256 amount1, , ) = footballMatch.getBet(0, user1);
        (uint256 amount2, , ) = footballMatch.getBet(0, user2);
        
        assertEq(amount1, 1 ether);
        assertEq(amount2, 2 ether);
    }

    function testCannotPlaceZeroBet() public {
        vm.prank(owner);
        footballMatch.addMarket("Winner", 200);
        
        vm.prank(user1);
        vm.expectRevert(BettingMatch.ZeroBet.selector);
        footballMatch.placeBet{value: 0}(0, 0);
    }

    function testCannotBetOnInvalidMarket() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(BettingMatch.InvalidMarket.selector, 999));
        footballMatch.placeBet{value: 1 ether}(999, 0);
    }

    function testResolveMarket() public {
        vm.prank(owner);
        footballMatch.addMarket("Winner", 200);
        
        vm.prank(user1);
        footballMatch.placeBet{value: 1 ether}(0, 0); // Bet on Home
        
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit MarketResolved(0, 0); // Home wins
        footballMatch.resolveMarket(0, 0);
        
        (, , BettingMatch.State state, uint256 result) = footballMatch.getMarket(0);
        assertTrue(state == BettingMatch.State.Ended);
        assertEq(result, 0);
    }

    function testOnlyOwnerCanResolveMarket() public {
        vm.prank(owner);
        footballMatch.addMarket("Winner", 200);
        
        vm.prank(user1);
        vm.expectRevert();
        footballMatch.resolveMarket(0, 0);
    }

    function testClaimWinningBet() public {
        vm.prank(owner);
        footballMatch.addMarket("Winner", 200); // 2.0x
        
        vm.prank(user1);
        footballMatch.placeBet{value: 1 ether}(0, 0); // Bet 1 ETH on Home
        
        // Fund contract with liquidity
        vm.prank(owner);
        payable(address(footballMatch)).transfer(5 ether);
        
        vm.prank(owner);
        footballMatch.resolveMarket(0, 0); // Home wins
        
        uint256 balanceBefore = user1.balance;
        
        vm.prank(user1);
        vm.expectEmit(true, true, false, true);
        emit Payout(0, user1, 2 ether);
        footballMatch.claim(0);
        
        uint256 balanceAfter = user1.balance;
        assertEq(balanceAfter - balanceBefore, 2 ether); // 1 ETH * 2.0x = 2 ETH
        
        (, , bool claimed) = footballMatch.getBet(0, user1);
        assertTrue(claimed);
    }

    function testCannotClaimLosingBet() public {
        vm.prank(owner);
        footballMatch.addMarket("Winner", 200);
        
        vm.prank(user1);
        footballMatch.placeBet{value: 1 ether}(0, 0); // Bet on Home
        
        vm.prank(owner);
        footballMatch.resolveMarket(0, 2); // Away wins
        
        vm.prank(user1);
        vm.expectRevert(BettingMatch.Lost.selector);
        footballMatch.claim(0);
    }

    function testCannotClaimBeforeResolution() public {
        vm.prank(owner);
        footballMatch.addMarket("Winner", 200);
        
        vm.prank(user1);
        footballMatch.placeBet{value: 1 ether}(0, 0);
        
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(BettingMatch.WrongState.selector, BettingMatch.State.Ended));
        footballMatch.claim(0);
    }

    function testCannotClaimTwice() public {
        vm.prank(owner);
        footballMatch.addMarket("Winner", 200);
        
        vm.prank(user1);
        footballMatch.placeBet{value: 1 ether}(0, 0);
        
        vm.prank(owner);
        payable(address(footballMatch)).transfer(5 ether);
        
        vm.prank(owner);
        footballMatch.resolveMarket(0, 0);
        
        vm.prank(user1);
        footballMatch.claim(0);
        
        vm.prank(user1);
        vm.expectRevert(BettingMatch.AlreadyClaimed.selector);
        footballMatch.claim(0);
    }

    function testCannotClaimWithoutBet() public {
        vm.prank(owner);
        footballMatch.addMarket("Winner", 200);
        
        vm.prank(owner);
        footballMatch.resolveMarket(0, 0);
        
        vm.prank(user1);
        vm.expectRevert(BettingMatch.NoBet.selector);
        footballMatch.claim(0);
    }

    function testCompleteFootballBettingFlow() public {
        // Owner adds Winner market with 2.5x odds
        vm.prank(owner);
        footballMatch.addMarket("Winner", 250);
        
        // User1 bets 2 ETH on Home (0)
        vm.prank(user1);
        footballMatch.placeBet{value: 2 ether}(0, 0);
        
        // User2 bets 1 ETH on Away (2)
        vm.prank(user2);
        footballMatch.placeBet{value: 1 ether}(0, 2);
        
        // Owner adds liquidity
        vm.prank(owner);
        payable(address(footballMatch)).transfer(10 ether);
        
        // Owner resolves market - Home wins
        vm.prank(owner);
        footballMatch.resolveMarket(0, 0);
        
        // User1 claims (winner)
        uint256 user1BalanceBefore = user1.balance;
        vm.prank(user1);
        footballMatch.claim(0);
        assertEq(user1.balance - user1BalanceBefore, 5 ether); // 2 ETH * 2.5x
        
        // User2 cannot claim (loser)
        vm.prank(user2);
        vm.expectRevert(BettingMatch.Lost.selector);
        footballMatch.claim(0);
    }

    function testInvalidMarketTypeReverts() public {
        vm.prank(owner);
        vm.expectRevert("Invalid market type");
        footballMatch.addMarket("InvalidType", 200);
    }

    function testGoalsCountMarket() public {
        vm.prank(owner);
        footballMatch.addMarket("GoalsCount", 300);
        
        vm.prank(user1);
        footballMatch.placeBet{value: 1 ether}(0, 3); // Bet on 3+ goals
        
        vm.prank(owner);
        payable(address(footballMatch)).transfer(5 ether);
        
        vm.prank(owner);
        footballMatch.resolveMarket(0, 3);
        
        uint256 balanceBefore = user1.balance;
        vm.prank(user1);
        footballMatch.claim(0);
        assertEq(user1.balance - balanceBefore, 3 ether); // 1 ETH * 3.0x
    }
}
