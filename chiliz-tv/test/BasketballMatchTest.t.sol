// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test, console} from "forge-std/Test.sol";
import {BettingMatch} from "../src/betting/BettingMatch.sol";
import {BasketballMatch} from "../src/betting/BasketballMatch.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/**
 * @title BasketballMatchTest
 * @notice Lifecycle tests for BasketballMatch (create → bet → resolve → claim)
 */
contract BasketballMatchTest is Test {
    BasketballMatch public implementation;
    BasketballMatch public match_;
    MockUSDC public usdc;

    address public owner = address(0x1);
    address public oddsSetter = address(0x2);
    address public resolver = address(0x3);
    address public alice = address(0x100);
    address public bob = address(0x101);

    bytes32 constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 constant ODDS_SETTER_ROLE = keccak256("ODDS_SETTER_ROLE");
    bytes32 constant RESOLVER_ROLE = keccak256("RESOLVER_ROLE");

    uint32 constant ODDS_PRECISION = 10000;

    bytes32 constant MARKET_WINNER = keccak256("WINNER");
    bytes32 constant MARKET_TOTAL_POINTS = keccak256("TOTAL_POINTS");
    bytes32 constant MARKET_SPREAD = keccak256("SPREAD");
    bytes32 constant MARKET_HIGHEST_QUARTER = keccak256("HIGHEST_QUARTER");

    function setUp() public {
        usdc = new MockUSDC();
        implementation = new BasketballMatch();

        bytes memory initData = abi.encodeWithSelector(
            BasketballMatch.initialize.selector,
            "Lakers vs Celtics",
            owner
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        match_ = BasketballMatch(payable(address(proxy)));

        vm.startPrank(owner);
        match_.grantRole(ODDS_SETTER_ROLE, oddsSetter);
        match_.grantRole(RESOLVER_ROLE, resolver);
        match_.setUSDCToken(address(usdc));
        vm.stopPrank();

        // Fund users with USDC
        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 100_000e6);

        // Fund contract for payouts
        usdc.mint(address(match_), 500_000e6);
    }

    // Helper: approve and place USDC bet
    function _placeBet(address user, uint256 marketId, uint64 selection, uint256 amount) internal {
        vm.startPrank(user);
        usdc.approve(address(match_), amount);
        match_.placeBetUSDC(marketId, selection, amount);
        vm.stopPrank();
    }

    // ═════════════════════════════════════════════════════════════════════════
    // LIFECYCLE: Create → Open → Bet → Resolve → Claim
    // ═════════════════════════════════════════════════════════════════════════

    function test_FullLifecycle_WinnerMarket() public {
        // 1. Admin adds WINNER market at 2.0x odds
        vm.prank(owner);
        match_.addMarketWithLine(MARKET_WINNER, 20000, 0);

        // 2. Open market
        vm.prank(owner);
        match_.openMarket(0);

        // 3. Alice bets 1000 USDC on Home (selection 0)
        _placeBet(alice, 0, 0, 1000e6);

        // 4. Bob bets 500 USDC on Away (selection 1)
        _placeBet(bob, 0, 1, 500e6);

        // 5. Close market
        vm.prank(owner);
        match_.closeMarket(0);

        // 6. Resolve: Home wins (result = 0)
        vm.prank(resolver);
        match_.resolveMarket(0, 0);

        // 7. Alice claims — should receive 1000 * 20000 / 10000 = 2000 USDC
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        match_.claim(0, 0);
        assertEq(usdc.balanceOf(alice) - balBefore, 2000e6);

        // 8. Bob tries to claim — should revert (lost)
        vm.prank(bob);
        vm.expectRevert();
        match_.claim(0, 0);
    }

    function test_AddMarketWithLine_Spread() public {
        // Add spread market with line = -55 (5.5 point spread), quarter = 0 (full game)
        vm.prank(owner);
        match_.addMarketWithQuarter(MARKET_SPREAD, 19000, -55, 0);

        (
            string memory typeStr,
            int16 line,
            uint8 quarter,
            uint8 maxSel,
            ,
            uint32 odds,
            ,
        ) = match_.getBasketballMarket(0);

        assertEq(typeStr, "SPREAD");
        assertEq(line, -55);
        assertEq(quarter, 0);
        assertEq(maxSel, 1);
        assertEq(odds, 19000);
    }

    function test_AddMarketWithLine_QuarterWinner() public {
        // Quarter 3 winner market
        vm.prank(owner);
        match_.addMarketWithQuarter(MARKET_WINNER, 21000, 0, 3);

        (, , uint8 quarter, , , , , ) = match_.getBasketballMarket(0);
        assertEq(quarter, 3);
    }

    function test_RevertInvalidQuarter() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BasketballMatch.InvalidQuarter.selector, 5));
        match_.addMarketWithQuarter(MARKET_WINNER, 20000, 0, 5);
    }

    function test_RevertInvalidMarketType() public {
        vm.prank(owner);
        bytes32 badType = keccak256("NONEXISTENT");
        vm.expectRevert(abi.encodeWithSelector(BasketballMatch.InvalidMarketType.selector, badType));
        match_.addMarketWithLine(badType, 20000, 0);
    }

    function test_InvalidSelection_Reverts() public {
        // WINNER market has maxSelections=1, so selection=2 should revert
        vm.prank(owner);
        match_.addMarketWithLine(MARKET_WINNER, 20000, 0);

        vm.prank(owner);
        match_.openMarket(0);

        vm.startPrank(alice);
        usdc.approve(address(match_), 100e6);
        vm.expectRevert();
        match_.placeBetUSDC(0, 2, 100e6);
        vm.stopPrank();
    }

    function test_HighestQuarterMarket_MultipleSelections() public {
        // HIGHEST_QUARTER has maxSelections=3 (selections 0-3 = Q1,Q2,Q3,Q4)
        vm.prank(owner);
        match_.addMarketWithLine(MARKET_HIGHEST_QUARTER, 30000, 0);

        vm.prank(owner);
        match_.openMarket(0);

        // Valid: selection 3 (Q4)
        _placeBet(alice, 0, 3, 100e6);

        // Invalid: selection 4
        vm.startPrank(bob);
        usdc.approve(address(match_), 100e6);
        vm.expectRevert();
        match_.placeBetUSDC(0, 4, 100e6);
        vm.stopPrank();
    }

    function test_CancelledMarket_Refund() public {
        vm.prank(owner);
        match_.addMarketWithLine(MARKET_WINNER, 20000, 0);

        vm.prank(owner);
        match_.openMarket(0);

        _placeBet(alice, 0, 0, 1000e6);

        // Cancel
        vm.prank(owner);
        match_.cancelMarket(0, "game postponed");

        // Refund
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        match_.claimRefund(0, 0);
        assertEq(usdc.balanceOf(alice) - balBefore, 1000e6);
    }

    function test_OddsUpdate_LocksAtBetTime() public {
        vm.prank(owner);
        match_.addMarketWithLine(MARKET_WINNER, 20000, 0);

        vm.prank(owner);
        match_.openMarket(0);

        // Alice bets at 2.0x
        _placeBet(alice, 0, 0, 1000e6);

        // Odds change to 3.0x
        vm.prank(oddsSetter);
        match_.setMarketOdds(0, 30000);

        // Bob bets at 3.0x
        _placeBet(bob, 0, 0, 1000e6);

        // Close and resolve: Home wins
        vm.prank(owner);
        match_.closeMarket(0);

        vm.prank(resolver);
        match_.resolveMarket(0, 0);

        // Alice gets 2000 USDC (1000 * 2.0x), Bob gets 3000 USDC (1000 * 3.0x)
        uint256 aliceBal = usdc.balanceOf(alice);
        vm.prank(alice);
        match_.claim(0, 0);
        assertEq(usdc.balanceOf(alice) - aliceBal, 2000e6);

        uint256 bobBal = usdc.balanceOf(bob);
        vm.prank(bob);
        match_.claim(0, 0);
        assertEq(usdc.balanceOf(bob) - bobBal, 3000e6);
    }
}
