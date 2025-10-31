// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/betting/MatchBettingOdds.sol";
import "./mocks/MockV3Aggregator.sol";

/// @title Match Betting Odds Test Suite
/// @notice Comprehensive tests for fixed-odds betting system with unrealistic mock data
/// @dev Uses exaggerated odds for clear testing (e.g., 10.0x, 6.5x) - real odds from Chainlink API in production
contract MatchBettingOddsTest is Test {
    MatchBettingOdds public betting;
    MockV3Aggregator public priceFeed;

    address admin = makeAddr("ADMIN");
    address treasury = makeAddr("TREASURY");
    address user1 = makeAddr("USER1");
    address user2 = makeAddr("USER2");
    address user3 = makeAddr("USER3");

    uint256 constant MIN_BET_USD = 5e8; // $5
    uint256 constant MAX_LIABILITY = 100_000 ether; // 100k CHZ max risk
    uint256 constant MAX_BET = 10_000 ether; // 10k CHZ max single bet

    function setUp() public {
        vm.warp(1000000);
        priceFeed = new MockV3Aggregator(8, 10e6); // CHZ = $0.10
        betting = new MatchBettingOdds();
        
        vm.deal(user1, 100_000 ether);
        vm.deal(user2, 100_000 ether);
        vm.deal(user3, 100_000 ether);
        vm.deal(treasury, 1_000_000 ether);
    }

    function _init(bytes32 matchId, uint64[] memory odds) internal {
        MatchBettingOdds.InitParams memory params = MatchBettingOdds.InitParams({
            owner: admin,
            priceFeed: address(priceFeed),
            matchId: matchId,
            cutoffTs: uint64(block.timestamp + 1 days),
            feeBps: 0,
            treasury: treasury,
            minBetUsd: MIN_BET_USD,
            maxLiability: MAX_LIABILITY,
            maxBetAmount: MAX_BET,
            outcomes: uint8(odds.length),
            initialOdds: odds
        });
        vm.prank(admin);
        betting.initialize(params);
    }

    function test_BasicBetAndWin() public {
        uint64[] memory odds = new uint64[](3);
        odds[0] = 20000; // 2.0x
        odds[1] = 30000; // 3.0x
        odds[2] = 25000; // 2.5x
        
        _init(keccak256("MATCH1"), odds);

        // User bets 1000 CHZ @ 2.0x
        vm.prank(user1);
        betting.placeBet{value: 1000 ether}(0);

        // Settle
        vm.warp(block.timestamp + 2 days);
        vm.prank(treasury);
        betting.fundContract{value: 10000 ether}();
        vm.prank(admin);
        betting.settle(0);

        // Claim
        uint256 balBefore = user1.balance;
        vm.prank(user1);
        betting.claim();
        
        // Should receive 2000 CHZ (1000 * 2.0x)
        assertEq(user1.balance - balBefore, 2000 ether);
    }

    function test_HouseProfitScenario() public {
        uint64[] memory odds = new uint64[](3);
        odds[0] = 15000; // 1.5x (favorite)
        odds[1] = 40000; // 4.0x
        odds[2] = 35000; // 3.5x
        
        _init(keccak256("MATCH2"), odds);

        // Heavy betting on losers
        vm.prank(user1);
        betting.placeBet{value: 5000 ether}(1);
        vm.prank(user2);
        betting.placeBet{value: 3000 ether}(2);
        
        // Light betting on winner
        vm.prank(user3);
        betting.placeBet{value: 1000 ether}(0);

        // Settle: outcome 0 wins
        vm.warp(block.timestamp + 2 days);
        uint256 treasuryBefore = treasury.balance;
        
        vm.prank(admin);
        betting.settle(0);

        // Treasury receives profit: 9000 - 1500 = 7500 CHZ
        assertEq(treasury.balance - treasuryBefore, 7500 ether);
    }

    function test_MultipleBetsSameUser() public {
        uint64[] memory odds = new uint64[](3);
        odds[0] = 20000;
        odds[1] = 30000;
        odds[2] = 25000;
        
        _init(keccak256("MATCH3"), odds);

        // User places 3 bets
        vm.startPrank(user1);
        betting.placeBet{value: 1000 ether}(0);
        betting.placeBet{value: 500 ether}(0);
        betting.placeBet{value: 300 ether}(1);
        vm.stopPrank();

        assertEq(betting.getUserBetCount(user1), 3);

        // Settle with outcome 0
        vm.warp(block.timestamp + 2 days);
        vm.prank(treasury);
        betting.fundContract{value: 10000 ether}();
        vm.prank(admin);
        betting.settle(0);

        // Pending: (1000 * 2.0) + (500 * 2.0) = 3000 CHZ
        assertEq(betting.pendingPayout(user1), 3000 ether);
    }

    function test_OddsUpdateBetweenBets() public {
        uint64[] memory odds = new uint64[](3);
        odds[0] = 20000;
        odds[1] = 30000;
        odds[2] = 25000;
        
        _init(keccak256("MATCH4"), odds);

        // First bet @ 2.0x
        vm.prank(user1);
        betting.placeBet{value: 1000 ether}(0);

        // Change odds
        vm.prank(admin);
        betting.setOdds(0, 18000); // Reduce to 1.8x

        // Second bet @ 1.8x
        vm.prank(user2);
        betting.placeBet{value: 1000 ether}(0);

        // Verify locked odds
        assertEq(betting.getUserBet(user1, 0).odds, 20000);
        assertEq(betting.getUserBet(user2, 0).odds, 18000);
    }

    function test_RevertInsufficientLiquidity() public {
        uint64[] memory odds = new uint64[](3);
        odds[0] = 100000; // 10.0x
        odds[1] = 30000;
        odds[2] = 25000;
        
        _init(keccak256("MATCH5"), odds);
        
        // Set low max liability
        vm.prank(admin);
        betting.setMaxLiability(10_000 ether);

        // First bet works
        vm.prank(user1);
        betting.placeBet{value: 1000 ether}(0); // Adds 9000 liability

        // Second bet exceeds max
        vm.prank(user2);
        vm.expectRevert(MatchBettingOdds.InsufficientLiquidity.selector);
        betting.placeBet{value: 200 ether}(0); // Would add 1800
    }

    function test_RevertBetAfterCutoff() public {
        uint64[] memory odds = new uint64[](3);
        odds[0] = 20000;
        odds[1] = 30000;
        odds[2] = 25000;
        
        _init(keccak256("MATCH6"), odds);

        vm.warp(block.timestamp + 2 days);

        vm.prank(user1);
        vm.expectRevert(MatchBettingOdds.BettingClosed.selector);
        betting.placeBet{value: 100 ether}(0);
    }

    function test_RevertBetBelowMinimum() public {
        uint64[] memory odds = new uint64[](3);
        odds[0] = 20000;
        odds[1] = 30000;
        odds[2] = 25000;
        
        _init(keccak256("MATCH7"), odds);

        // 10 CHZ = $1, below $5 minimum
        vm.prank(user1);
        vm.expectRevert(MatchBettingOdds.BetBelowMinimum.selector);
        betting.placeBet{value: 10 ether}(0);
    }

    function test_RevertBetAboveMaximum() public {
        uint64[] memory odds = new uint64[](3);
        odds[0] = 20000;
        odds[1] = 30000;
        odds[2] = 25000;
        
        _init(keccak256("MATCH8"), odds);

        // 15k CHZ > 10k max
        vm.prank(user1);
        vm.expectRevert(MatchBettingOdds.BetAboveMaximum.selector);
        betting.placeBet{value: 15_000 ether}(0);
    }

    function test_ViewFunctions() public {
        uint64[] memory odds = new uint64[](3);
        odds[0] = 20000;
        odds[1] = 30000;
        odds[2] = 25000;
        
        _init(keccak256("MATCH9"), odds);

        // Check getAllOdds
        uint64[] memory allOdds = betting.getAllOdds();
        assertEq(allOdds.length, 3);
        assertEq(allOdds[0], 20000);

        // Place bets
        vm.prank(user1);
        betting.placeBet{value: 1000 ether}(0);
        vm.prank(user2);
        betting.placeBet{value: 500 ether}(1);

        // Check total pool
        assertEq(betting.totalPoolAmount(), 1500 ether);
    }

    /// @notice Test with unrealistic UFC odds for clarity
    /// @dev Real odds would come from Chainlink API in production
    function test_UFCHeavyUnderdog() public {
        // Champion vs Unknown Challenger
        uint64[] memory odds = new uint64[](2);
        odds[0] = 11000; // 1.1x (champion, heavy favorite)
        odds[1] = 95000; // 9.5x (challenger, massive underdog)
        
        _init(keccak256("UFC_FIGHT"), odds);

        // Someone bets on underdog
        vm.prank(user1);
        betting.placeBet{value: 100 ether}(1); // Potential 950 CHZ payout

        // Underdog wins!
        vm.warp(block.timestamp + 2 days);
        vm.prank(treasury);
        betting.fundContract{value: 1000 ether}(); // Treasury funds the upset
        vm.prank(admin);
        betting.settle(1);

        // User claims 950 CHZ
        uint256 balBefore = user1.balance;
        vm.prank(user1);
        betting.claim();
        assertEq(user1.balance - balBefore, 950 ether);
    }
}
