// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/betting/BasketballMatch.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract BasketballMatchTest is Test {
    BasketballMatch public basketballImpl;
    BasketballMatch public basketballMatch;
    
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
        basketballImpl = new BasketballMatch();
        
        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(
            BasketballMatch.initialize.selector,
            "Lakers vs Celtics",
            owner
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(basketballImpl), initData);
        basketballMatch = BasketballMatch(payable(address(proxy)));
        
        // Fund test accounts
        vm.deal(owner, 100 ether);
        vm.deal(user1, 10 ether);
        vm.deal(user2, 10 ether);
    }

    function testInitialization() public {
        assertEq(basketballMatch.matchName(), "Lakers vs Celtics");
        assertEq(basketballMatch.sportType(), "BASKETBALL");
        assertEq(basketballMatch.owner(), owner);
        assertEq(basketballMatch.marketCount(), 0);
    }

    function testAddWinnerMarket() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit MarketAdded(0, "Winner", 180);
        basketballMatch.addMarket("Winner", 180);
        
        assertEq(basketballMatch.marketCount(), 1);
        
        (string memory mtype, uint256 odds, BettingMatch.State state, uint256 result) = basketballMatch.getMarket(0);
        assertEq(mtype, "Winner");
        assertEq(odds, 180);
        assertTrue(state == BettingMatch.State.Live);
        assertEq(result, 0);
    }

    function testAddTotalPointsMarket() public {
        vm.prank(owner);
        basketballMatch.addMarket("TotalPoints", 200);
        
        (string memory mtype, , , ) = basketballMatch.getMarket(0);
        assertEq(mtype, "TotalPoints");
    }

    function testAddPointSpreadMarket() public {
        vm.prank(owner);
        basketballMatch.addMarket("PointSpread", 190);
        
        (string memory mtype, , , ) = basketballMatch.getMarket(0);
        assertEq(mtype, "PointSpread");
    }

    function testAddQuarterWinnerMarket() public {
        vm.prank(owner);
        basketballMatch.addMarket("QuarterWinner", 220);
        
        (string memory mtype, , , ) = basketballMatch.getMarket(0);
        assertEq(mtype, "QuarterWinner");
    }

    function testAddFirstToScoreMarket() public {
        vm.prank(owner);
        basketballMatch.addMarket("FirstToScore", 200);
        
        (string memory mtype, , , ) = basketballMatch.getMarket(0);
        assertEq(mtype, "FirstToScore");
    }

    function testAddHighestScoringQuarterMarket() public {
        vm.prank(owner);
        basketballMatch.addMarket("HighestScoringQuarter", 400);
        
        (string memory mtype, , , ) = basketballMatch.getMarket(0);
        assertEq(mtype, "HighestScoringQuarter");
    }

    function testAddMultipleMarkets() public {
        vm.startPrank(owner);
        basketballMatch.addMarket("Winner", 180);
        basketballMatch.addMarket("TotalPoints", 200);
        basketballMatch.addMarket("PointSpread", 190);
        vm.stopPrank();
        
        assertEq(basketballMatch.marketCount(), 3);
    }

    function testOnlyOwnerCanAddMarket() public {
        vm.prank(user1);
        vm.expectRevert();
        basketballMatch.addMarket("Winner", 180);
    }

    function testPlaceBetOnWinner() public {
        vm.prank(owner);
        basketballMatch.addMarket("Winner", 180);
        
        vm.prank(user1);
        vm.expectEmit(true, true, false, true);
        emit BetPlaced(0, user1, 1 ether, 0); // Bet on Home (0)
        basketballMatch.placeBet{value: 1 ether}(0, 0);
        
        (uint256 amount, uint256 selection, bool claimed) = basketballMatch.getBet(0, user1);
        assertEq(amount, 1 ether);
        assertEq(selection, 0);
        assertFalse(claimed);
    }

    function testPlaceMultipleBets() public {
        vm.prank(owner);
        basketballMatch.addMarket("Winner", 180);
        
        vm.prank(user1);
        basketballMatch.placeBet{value: 2 ether}(0, 0); // Home
        
        vm.prank(user2);
        basketballMatch.placeBet{value: 3 ether}(0, 1); // Away
        
        (uint256 amount1, , ) = basketballMatch.getBet(0, user1);
        (uint256 amount2, , ) = basketballMatch.getBet(0, user2);
        
        assertEq(amount1, 2 ether);
        assertEq(amount2, 3 ether);
    }

    function testCannotPlaceZeroBet() public {
        vm.prank(owner);
        basketballMatch.addMarket("Winner", 180);
        
        vm.prank(user1);
        vm.expectRevert(BettingMatch.ZeroBet.selector);
        basketballMatch.placeBet{value: 0}(0, 0);
    }

    function testCannotBetOnInvalidMarket() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(BettingMatch.InvalidMarket.selector, 999));
        basketballMatch.placeBet{value: 1 ether}(999, 0);
    }

    function testResolveMarket() public {
        vm.prank(owner);
        basketballMatch.addMarket("Winner", 180);
        
        vm.prank(user1);
        basketballMatch.placeBet{value: 1 ether}(0, 0);
        
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit MarketResolved(0, 0); // Home wins
        basketballMatch.resolveMarket(0, 0);
        
        (, , BettingMatch.State state, uint256 result) = basketballMatch.getMarket(0);
        assertTrue(state == BettingMatch.State.Ended);
        assertEq(result, 0);
    }

    function testOnlyOwnerCanResolveMarket() public {
        vm.prank(owner);
        basketballMatch.addMarket("Winner", 180);
        
        vm.prank(user1);
        vm.expectRevert();
        basketballMatch.resolveMarket(0, 0);
    }

    function testClaimWinningBet() public {
        vm.prank(owner);
        basketballMatch.addMarket("Winner", 180); // 1.8x
        
        vm.prank(user1);
        basketballMatch.placeBet{value: 2 ether}(0, 0);
        
        // Fund contract with liquidity
        vm.prank(owner);
        payable(address(basketballMatch)).transfer(10 ether);
        
        vm.prank(owner);
        basketballMatch.resolveMarket(0, 0); // Home wins
        
        uint256 balanceBefore = user1.balance;
        
        vm.prank(user1);
        vm.expectEmit(true, true, false, true);
        emit Payout(0, user1, 3.6 ether);
        basketballMatch.claim(0);
        
        uint256 balanceAfter = user1.balance;
        assertEq(balanceAfter - balanceBefore, 3.6 ether); // 2 ETH * 1.8x
        
        (, , bool claimed) = basketballMatch.getBet(0, user1);
        assertTrue(claimed);
    }

    function testCannotClaimLosingBet() public {
        vm.prank(owner);
        basketballMatch.addMarket("Winner", 180);
        
        vm.prank(user1);
        basketballMatch.placeBet{value: 1 ether}(0, 0); // Bet on Home
        
        vm.prank(owner);
        basketballMatch.resolveMarket(0, 1); // Away wins
        
        vm.prank(user1);
        vm.expectRevert(BettingMatch.Lost.selector);
        basketballMatch.claim(0);
    }

    function testCannotClaimBeforeResolution() public {
        vm.prank(owner);
        basketballMatch.addMarket("Winner", 180);
        
        vm.prank(user1);
        basketballMatch.placeBet{value: 1 ether}(0, 0);
        
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(BettingMatch.WrongState.selector, BettingMatch.State.Ended));
        basketballMatch.claim(0);
    }

    function testCannotClaimTwice() public {
        vm.prank(owner);
        basketballMatch.addMarket("Winner", 180);
        
        vm.prank(user1);
        basketballMatch.placeBet{value: 1 ether}(0, 0);
        
        vm.prank(owner);
        payable(address(basketballMatch)).transfer(5 ether);
        
        vm.prank(owner);
        basketballMatch.resolveMarket(0, 0);
        
        vm.prank(user1);
        basketballMatch.claim(0);
        
        vm.prank(user1);
        vm.expectRevert(BettingMatch.AlreadyClaimed.selector);
        basketballMatch.claim(0);
    }

    function testCannotClaimWithoutBet() public {
        vm.prank(owner);
        basketballMatch.addMarket("Winner", 180);
        
        vm.prank(owner);
        basketballMatch.resolveMarket(0, 0);
        
        vm.prank(user1);
        vm.expectRevert(BettingMatch.NoBet.selector);
        basketballMatch.claim(0);
    }

    function testCompleteBasketballBettingFlow() public {
        // Owner adds TotalPoints market with 2.0x odds
        vm.prank(owner);
        basketballMatch.addMarket("TotalPoints", 200);
        
        // User1 bets 3 ETH on Over (1)
        vm.prank(user1);
        basketballMatch.placeBet{value: 3 ether}(0, 1);
        
        // User2 bets 2 ETH on Under (0)
        vm.prank(user2);
        basketballMatch.placeBet{value: 2 ether}(0, 0);
        
        // Owner adds liquidity
        vm.prank(owner);
        payable(address(basketballMatch)).transfer(10 ether);
        
        // Owner resolves market - Over hits
        vm.prank(owner);
        basketballMatch.resolveMarket(0, 1);
        
        // User1 claims (winner)
        uint256 user1BalanceBefore = user1.balance;
        vm.prank(user1);
        basketballMatch.claim(0);
        assertEq(user1.balance - user1BalanceBefore, 6 ether); // 3 ETH * 2.0x
        
        // User2 cannot claim (loser)
        vm.prank(user2);
        vm.expectRevert(BettingMatch.Lost.selector);
        basketballMatch.claim(0);
    }

    function testInvalidMarketTypeReverts() public {
        vm.prank(owner);
        vm.expectRevert("Invalid market type");
        basketballMatch.addMarket("InvalidType", 180);
    }

    function testQuarterWinnerMarket() public {
        vm.prank(owner);
        basketballMatch.addMarket("QuarterWinner", 250);
        
        vm.prank(user1);
        basketballMatch.placeBet{value: 1 ether}(0, 2); // Bet on Q3 winner
        
        vm.prank(owner);
        payable(address(basketballMatch)).transfer(5 ether);
        
        vm.prank(owner);
        basketballMatch.resolveMarket(0, 2);
        
        uint256 balanceBefore = user1.balance;
        vm.prank(user1);
        basketballMatch.claim(0);
        assertEq(user1.balance - balanceBefore, 2.5 ether); // 1 ETH * 2.5x
    }
}
