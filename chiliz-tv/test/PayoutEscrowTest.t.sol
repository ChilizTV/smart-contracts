// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test, console} from "forge-std/Test.sol";
import {BettingMatch} from "../src/betting/BettingMatch.sol";
import {FootballMatch} from "../src/betting/FootballMatch.sol";
import {PayoutEscrow} from "../src/betting/PayoutEscrow.sol";
import {IPayoutEscrow} from "../src/interfaces/IPayoutEscrow.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockUSDT} from "./mocks/MockUSDT.sol";

/**
 * @title PayoutEscrowTest
 * @notice Tests for the full payout lifecycle with PayoutEscrow integration
 *
 * Coverage:
 *   1.  Full lifecycle: create match → bet → resolve → fund escrow → claim
 *   2.  Claim from contract balance only (no escrow needed)
 *   3.  Claim from escrow fallback (contract has zero USDT)
 *   4.  Mixed source: partial contract + partial escrow
 *   5.  Double claim prevention
 *   6.  Insufficient funding (both sources empty) → revert
 *   7.  Unauthorized match → escrow reverts
 *   8.  Escrow paused → claims fail
 *   9.  Escrow withdraw by owner
 *   10. ClaimAll with escrow fallback
 *   11. Refund with escrow fallback (cancelled market)
 *   12. getFundingDeficit view correctness
 *   13. setPayoutEscrow admin function
 *   14. Escrow authorization lifecycle
 *   15. Adversarial: non-admin cannot setPayoutEscrow
 */
contract PayoutEscrowTest is Test {
    FootballMatch public implementation;
    FootballMatch public footballMatch;
    PayoutEscrow public escrow;
    MockUSDT public usdt;

    address public owner = address(0x1);
    address public safeAddr = address(0x5AFE);
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
    bytes32 constant MARKET_WINNER = keccak256("WINNER");

    function setUp() public {
        // Deploy mock USDT
        usdt = new MockUSDT();

        // Deploy PayoutEscrow owned by Safe
        escrow = new PayoutEscrow(address(usdt), safeAddr);

        // Deploy FootballMatch proxy
        implementation = new FootballMatch();
        bytes memory initData = abi.encodeWithSelector(
            FootballMatch.initialize.selector,
            "Test Match",
            owner
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        footballMatch = FootballMatch(payable(address(proxy)));

        // Setup roles, USDT, and escrow on the match contract
        vm.startPrank(owner);
        footballMatch.grantRole(ODDS_SETTER_ROLE, oddsSetter);
        footballMatch.grantRole(RESOLVER_ROLE, resolver);
        footballMatch.setUSDTToken(address(usdt));
        footballMatch.setPayoutEscrow(address(escrow));
        vm.stopPrank();

        // Authorize match in escrow
        vm.prank(safeAddr);
        escrow.authorizeMatch(address(footballMatch));

        // Fund test users (100k USDT each)
        usdt.mint(alice, 100_000e6);
        usdt.mint(bob, 100_000e6);
        usdt.mint(charlie, 100_000e6);

        // NOTE: Do NOT blanket pre-fund the match here.
        // Each test that needs solvency pre-funding adds it explicitly
        // via _fundMatchDirect() before placing bets.
    }

    // ═════════════════════════════════════════════════════════════════════
    // HELPERS
    // ═════════════════════════════════════════════════════════════════════

    function _createAndOpenMarket(uint32 odds) internal {
        vm.prank(owner);
        footballMatch.addMarketWithLine(MARKET_WINNER, odds, 0);
        vm.prank(owner);
        footballMatch.openMarket(0);
    }

    function _placeBet(address user, uint256 marketId, uint64 selection, uint256 amount) internal {
        vm.startPrank(user);
        usdt.approve(address(footballMatch), amount);
        footballMatch.placeBetUSDT(marketId, selection, amount);
        vm.stopPrank();
    }

    function _fundEscrow(uint256 amount) internal {
        usdt.mint(safeAddr, amount);
        vm.startPrank(safeAddr);
        usdt.approve(address(escrow), amount);
        escrow.fund(amount);
        vm.stopPrank();
    }

    function _fundMatchDirect(uint256 amount) internal {
        usdt.mint(address(footballMatch), amount);
    }

    // ═════════════════════════════════════════════════════════════════════
    // TEST 1: Full payout lifecycle with escrow
    // ═════════════════════════════════════════════════════════════════════

    function test_FullPayoutLifecycle() public {
        // Create market, 2.0x odds
        _createAndOpenMarket(20000);

        // Pre-fund for solvency check during bet placement
        _fundMatchDirect(100e6);

        // Alice bets 100 USDT at 2.0x → potential payout 200 USDT
        // Contract receives 100 USDT from bet, needs 100 more for profit portion
        _placeBet(alice, 0, 0, 100e6);

        // Resolve: Home (0) wins
        vm.prank(owner);
        footballMatch.closeMarket(0);
        vm.prank(resolver);
        footballMatch.resolveMarket(0, 0);

        // Drain pre-fund so only bet deposit remains (100 USDT)
        vm.prank(owner);
        footballMatch.emergencyPause();
        vm.prank(owner);
        footballMatch.emergencyWithdrawUSDT(100e6);
        vm.prank(owner);
        footballMatch.unpause();

        // Fund escrow with 100 USDT to cover deficit
        _fundEscrow(100e6);

        // Alice claims
        uint256 aliceBefore = usdt.balanceOf(alice);
        vm.prank(alice);
        footballMatch.claim(0, 0);
        uint256 payout = usdt.balanceOf(alice) - aliceBefore;

        assertEq(payout, 200e6, "Alice should receive 200 USDT (100 * 2.0x)");
    }

    // ═════════════════════════════════════════════════════════════════════
    // TEST 2: Claim entirely from contract balance (no escrow needed)
    // ═════════════════════════════════════════════════════════════════════

    function test_ClaimFromContractBalanceOnly() public {
        _createAndOpenMarket(20000);

        // Pre-fund for solvency + enough to cover full payout from contract
        _fundMatchDirect(200e6);
        _placeBet(alice, 0, 0, 100e6);

        vm.prank(owner);
        footballMatch.closeMarket(0);
        vm.prank(resolver);
        footballMatch.resolveMarket(0, 0);

        // Contract has 300 (200 pre-fund + 100 bet), payout 200 → no escrow needed
        uint256 aliceBefore = usdt.balanceOf(alice);
        vm.prank(alice);
        footballMatch.claim(0, 0);

        assertEq(usdt.balanceOf(alice) - aliceBefore, 200e6, "Should pay from contract balance");
        // Escrow should not have been touched
        assertEq(escrow.totalDisbursed(), 0, "Escrow should not be touched");
    }

    // ═════════════════════════════════════════════════════════════════════
    // TEST 3: Claim entirely from escrow fallback (contract has 0 extra)
    // ═════════════════════════════════════════════════════════════════════

    function test_ClaimFromEscrowFallback() public {
        _createAndOpenMarket(20000);

        // Fund match with enough USDT for the solvency check during bet placement
        _fundMatchDirect(200e6);
        _placeBet(alice, 0, 0, 100e6);

        vm.prank(owner);
        footballMatch.closeMarket(0);
        vm.prank(resolver);
        footballMatch.resolveMarket(0, 0);

        // Drain match contract USDT to simulate unfunded state
        // (In production, the contract just has bet deposits, which are < payout)
        // Contract has 300 USDT (200 pre-funded + 100 from bet), payout is 200
        // Withdraw extra to leave only 50 USDT in the contract
        vm.prank(owner);
        footballMatch.emergencyPause();
        vm.prank(owner);
        footballMatch.emergencyWithdrawUSDT(250e6);
        vm.prank(owner);
        footballMatch.unpause();

        // Contract has 50 USDT, payout is 200 USDT, deficit is 150 USDT
        assertEq(usdt.balanceOf(address(footballMatch)), 50e6);

        // Fund escrow to cover the deficit
        _fundEscrow(150e6);

        uint256 aliceBefore = usdt.balanceOf(alice);
        vm.prank(alice);
        footballMatch.claim(0, 0);

        assertEq(usdt.balanceOf(alice) - aliceBefore, 200e6, "Should get full payout");
        assertEq(escrow.totalDisbursed(), 150e6, "Escrow should have disbursed 150 USDT");
        assertEq(escrow.disbursedPerMatch(address(footballMatch)), 150e6);
    }

    // ═════════════════════════════════════════════════════════════════════
    // TEST 4: Mixed source claim (partial contract + partial escrow)
    // ═════════════════════════════════════════════════════════════════════

    function test_ClaimFromMixedSources() public {
        _createAndOpenMarket(30000); // 3.0x odds

        // Pre-fund match for solvency check
        _fundMatchDirect(300e6);
        _placeBet(alice, 0, 0, 100e6);

        vm.prank(owner);
        footballMatch.closeMarket(0);
        vm.prank(resolver);
        footballMatch.resolveMarket(0, 0);

        // Contract has 400 USDT (300 pre-funded + 100 from bet)
        // Payout is 300 USDT → contract has enough
        // Withdraw to leave only 200 USDT (deficit of 100)
        vm.prank(owner);
        footballMatch.emergencyPause();
        vm.prank(owner);
        footballMatch.emergencyWithdrawUSDT(200e6);
        vm.prank(owner);
        footballMatch.unpause();

        assertEq(usdt.balanceOf(address(footballMatch)), 200e6);

        // Fund escrow with 100 USDT to cover the deficit
        _fundEscrow(100e6);

        uint256 aliceBefore = usdt.balanceOf(alice);
        vm.prank(alice);
        footballMatch.claim(0, 0);

        assertEq(usdt.balanceOf(alice) - aliceBefore, 300e6, "Alice gets 3.0x payout");
        assertEq(escrow.totalDisbursed(), 100e6, "Escrow covers deficit only");
    }

    // ═════════════════════════════════════════════════════════════════════
    // TEST 5: Double claim prevention
    // ═════════════════════════════════════════════════════════════════════

    function test_DoubleClaimPrevented() public {
        _createAndOpenMarket(20000);
        _fundMatchDirect(100e6);
        _placeBet(alice, 0, 0, 100e6);

        vm.prank(owner);
        footballMatch.closeMarket(0);
        vm.prank(resolver);
        footballMatch.resolveMarket(0, 0);

        vm.prank(alice);
        footballMatch.claim(0, 0);

        // Second claim reverts
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(BettingMatch.AlreadyClaimed.selector, 0, alice, 0)
        );
        footballMatch.claim(0, 0);
    }

    // ═════════════════════════════════════════════════════════════════════
    // TEST 6: Insufficient funding (both contract and escrow empty)
    // ═════════════════════════════════════════════════════════════════════

    function test_InsufficientFundingReverts() public {
        _createAndOpenMarket(20000);
        _fundMatchDirect(200e6); // for solvency at bet time
        _placeBet(alice, 0, 0, 100e6);

        vm.prank(owner);
        footballMatch.closeMarket(0);
        vm.prank(resolver);
        footballMatch.resolveMarket(0, 0);

        // Drain match contract
        vm.prank(owner);
        footballMatch.emergencyPause();
        vm.prank(owner);
        footballMatch.emergencyWithdrawUSDT(300e6); // drain everything
        vm.prank(owner);
        footballMatch.unpause();

        assertEq(usdt.balanceOf(address(footballMatch)), 0);

        // Escrow also empty
        assertEq(usdt.balanceOf(address(escrow)), 0);

        // Claim should revert (escrow has insufficient balance)
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                PayoutEscrow.InsufficientEscrowBalance.selector,
                200e6,
                0
            )
        );
        footballMatch.claim(0, 0);
    }

    // ═════════════════════════════════════════════════════════════════════
    // TEST 6b: Insufficient funding without escrow set → original revert
    // ═════════════════════════════════════════════════════════════════════

    function test_NoEscrowInsufficientReverts() public {
        // Remove escrow
        vm.prank(owner);
        footballMatch.setPayoutEscrow(address(0));

        _createAndOpenMarket(20000);
        _fundMatchDirect(200e6);
        _placeBet(alice, 0, 0, 100e6);

        vm.prank(owner);
        footballMatch.closeMarket(0);
        vm.prank(resolver);
        footballMatch.resolveMarket(0, 0);

        // Drain match
        vm.prank(owner);
        footballMatch.emergencyPause();
        vm.prank(owner);
        footballMatch.emergencyWithdrawUSDT(300e6);
        vm.prank(owner);
        footballMatch.unpause();

        // Without escrow, reverts with InsufficientUSDTBalance
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(BettingMatch.InsufficientUSDTBalance.selector, 200e6, 0)
        );
        footballMatch.claim(0, 0);
    }

    // ═════════════════════════════════════════════════════════════════════
    // TEST 7: Unauthorized match cannot use escrow
    // ═════════════════════════════════════════════════════════════════════

    function test_UnauthorizedMatchReverts() public {
        // Deploy a second match NOT authorized in escrow
        bytes memory initData = abi.encodeWithSelector(
            FootballMatch.initialize.selector,
            "Unauthorized Match",
            owner
        );
        ERC1967Proxy proxy2 = new ERC1967Proxy(address(implementation), initData);
        FootballMatch unauthorizedMatch = FootballMatch(payable(address(proxy2)));

        vm.startPrank(owner);
        unauthorizedMatch.setUSDTToken(address(usdt));
        unauthorizedMatch.setPayoutEscrow(address(escrow));
        unauthorizedMatch.grantRole(RESOLVER_ROLE, resolver);
        unauthorizedMatch.addMarketWithLine(MARKET_WINNER, 20000, 0);
        unauthorizedMatch.openMarket(0);
        vm.stopPrank();

        _fundMatchDirect(200e6); // for footballMatch (won't help this one)

        // Fund unauthorizedMatch enough for solvency check
        usdt.mint(address(unauthorizedMatch), 200e6);

        vm.startPrank(alice);
        usdt.approve(address(unauthorizedMatch), 100e6);
        unauthorizedMatch.placeBetUSDT(0, 0, 100e6);
        vm.stopPrank();

        vm.prank(owner);
        unauthorizedMatch.closeMarket(0);
        vm.prank(resolver);
        unauthorizedMatch.resolveMarket(0, 0);

        // Drain match to force escrow fallback
        vm.prank(owner);
        unauthorizedMatch.emergencyPause();
        vm.prank(owner);
        unauthorizedMatch.emergencyWithdrawUSDT(300e6);
        vm.prank(owner);
        unauthorizedMatch.unpause();

        _fundEscrow(200e6);

        // Claim should fail because match is not authorized in escrow
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                PayoutEscrow.UnauthorizedMatch.selector,
                address(unauthorizedMatch)
            )
        );
        unauthorizedMatch.claim(0, 0);
    }

    // ═════════════════════════════════════════════════════════════════════
    // TEST 8: Escrow paused blocks disbursements
    // ═════════════════════════════════════════════════════════════════════

    function test_EscrowPauseBlocksClaims() public {
        _createAndOpenMarket(20000);
        _fundMatchDirect(100e6); // solvency for bet
        _placeBet(alice, 0, 0, 100e6);

        vm.prank(owner);
        footballMatch.closeMarket(0);
        vm.prank(resolver);
        footballMatch.resolveMarket(0, 0);

        // Drain contract to force escrow path
        vm.prank(owner);
        footballMatch.emergencyPause();
        vm.prank(owner);
        footballMatch.emergencyWithdrawUSDT(200e6); // drain all
        vm.prank(owner);
        footballMatch.unpause();

        // Fund escrow to cover full payout
        _fundEscrow(200e6);

        // Pause escrow
        vm.prank(safeAddr);
        escrow.pause();

        // Claim fails (escrow paused, contract empty)
        vm.prank(alice);
        vm.expectRevert(); // Pausable: EnforcedPause
        footballMatch.claim(0, 0);

        // Unpause → claim succeeds
        vm.prank(safeAddr);
        escrow.unpause();

        uint256 aliceBefore = usdt.balanceOf(alice);
        vm.prank(alice);
        footballMatch.claim(0, 0);
        assertEq(usdt.balanceOf(alice) - aliceBefore, 200e6);
    }

    // ═════════════════════════════════════════════════════════════════════
    // TEST 9: Escrow owner can withdraw
    // ═════════════════════════════════════════════════════════════════════

    function test_EscrowWithdrawByOwner() public {
        _fundEscrow(500e6);

        assertEq(usdt.balanceOf(address(escrow)), 500e6);

        vm.prank(safeAddr);
        escrow.withdraw(200e6);
        assertEq(usdt.balanceOf(address(escrow)), 300e6);
        assertEq(usdt.balanceOf(safeAddr), 200e6);

        // Non-owner cannot withdraw
        vm.prank(alice);
        vm.expectRevert();
        escrow.withdraw(100e6);
    }

    // ═════════════════════════════════════════════════════════════════════
    // TEST 10: ClaimAll with escrow fallback
    // ═════════════════════════════════════════════════════════════════════

    function test_ClaimAllWithEscrow() public {
        _createAndOpenMarket(20000);

        // Pre-fund for solvency: after 2 bets, liability = 200+250 = 450
        _fundMatchDirect(250e6);
        _placeBet(alice, 0, 0, 100e6);

        // Change odds and place another bet
        vm.prank(oddsSetter);
        footballMatch.setMarketOdds(0, 25000);
        _placeBet(alice, 0, 0, 100e6);

        // Close and resolve → Home wins
        vm.prank(owner);
        footballMatch.closeMarket(0);
        vm.prank(resolver);
        footballMatch.resolveMarket(0, 0);

        // Contract has 450 (250 pre-fund + 200 bets), payout = 450
        // Drain pre-fund to leave only bet deposits
        vm.prank(owner);
        footballMatch.emergencyPause();
        vm.prank(owner);
        footballMatch.emergencyWithdrawUSDT(250e6);
        vm.prank(owner);
        footballMatch.unpause();

        // Contract has 200 USDT (bet deposits). Deficit = 250
        _fundEscrow(250e6);

        uint256 aliceBefore = usdt.balanceOf(alice);
        vm.prank(alice);
        footballMatch.claimAll(0);

        assertEq(usdt.balanceOf(alice) - aliceBefore, 450e6, "ClaimAll should pay 450 USDT");
    }

    // ═════════════════════════════════════════════════════════════════════
    // TEST 11: Refund with escrow fallback (cancelled market)
    // ═════════════════════════════════════════════════════════════════════

    function test_RefundWithEscrow() public {
        _createAndOpenMarket(20000);
        _fundMatchDirect(100e6); // solvency for bet
        _placeBet(alice, 0, 0, 100e6);

        // Cancel market
        vm.prank(owner);
        footballMatch.cancelMarket(0, "Match postponed");

        // Drain contract completely to force escrow fallback
        // Contract has 200 (100 pre-fund + 100 bet)
        vm.prank(owner);
        footballMatch.emergencyPause();
        vm.prank(owner);
        footballMatch.emergencyWithdrawUSDT(200e6);
        vm.prank(owner);
        footballMatch.unpause();

        _fundEscrow(100e6);

        uint256 aliceBefore = usdt.balanceOf(alice);
        vm.prank(alice);
        footballMatch.claimRefund(0, 0);

        assertEq(usdt.balanceOf(alice) - aliceBefore, 100e6, "Should refund full amount");
    }

    // ═════════════════════════════════════════════════════════════════════
    // TEST 12: getFundingDeficit view
    // ═════════════════════════════════════════════════════════════════════

    function test_GetFundingDeficit() public {
        _createAndOpenMarket(20000);

        // Before any bets → deficit = 0
        assertEq(footballMatch.getFundingDeficit(), 0);

        // Pre-fund match for solvency check
        _fundMatchDirect(500e6);

        // Alice bets 100 USDT at 2.0x → liability = 200
        _placeBet(alice, 0, 0, 100e6);

        // Contract has 600 (500 + 100 from bet), liabilities = 200 → no deficit
        assertEq(footballMatch.getFundingDeficit(), 0);

        // Bob bets 200 USDT at 2.0x → liability += 400, total = 600
        _placeBet(bob, 0, 0, 200e6);

        // Contract has 800 (500 + 100 + 200), liabilities = 600 → no deficit
        assertEq(footballMatch.getFundingDeficit(), 0);

        // Drain some funds
        vm.prank(owner);
        footballMatch.emergencyPause();
        vm.prank(owner);
        footballMatch.emergencyWithdrawUSDT(500e6);
        vm.prank(owner);
        footballMatch.unpause();

        // Contract has 300, liabilities = 600 → deficit = 300
        assertEq(footballMatch.getFundingDeficit(), 300e6);
    }

    // ═════════════════════════════════════════════════════════════════════
    // TEST 13: setPayoutEscrow admin control
    // ═════════════════════════════════════════════════════════════════════

    function test_SetPayoutEscrow() public {
        // Only admin can set
        vm.prank(alice);
        vm.expectRevert();
        footballMatch.setPayoutEscrow(address(0x999));

        // Admin can set
        vm.prank(owner);
        footballMatch.setPayoutEscrow(address(0x999));
        assertEq(address(footballMatch.payoutEscrow()), address(0x999));

        // Admin can disable (set to address(0))
        vm.prank(owner);
        footballMatch.setPayoutEscrow(address(0));
        assertEq(address(footballMatch.payoutEscrow()), address(0));
    }

    // ═════════════════════════════════════════════════════════════════════
    // TEST 14: Escrow authorization lifecycle
    // ═════════════════════════════════════════════════════════════════════

    function test_EscrowAuthorizationLifecycle() public {
        address newMatch = address(0x456);

        // Initially not authorized
        assertFalse(escrow.authorizedMatches(newMatch));

        // Authorize
        vm.prank(safeAddr);
        escrow.authorizeMatch(newMatch);
        assertTrue(escrow.authorizedMatches(newMatch));

        // Revoke
        vm.prank(safeAddr);
        escrow.revokeMatch(newMatch);
        assertFalse(escrow.authorizedMatches(newMatch));

        // Non-owner cannot authorize
        vm.prank(alice);
        vm.expectRevert();
        escrow.authorizeMatch(newMatch);
    }

    // ═════════════════════════════════════════════════════════════════════
    // TEST 15: Escrow validation errors
    // ═════════════════════════════════════════════════════════════════════

    function test_EscrowValidationErrors() public {
        // Zero amount fund
        vm.prank(safeAddr);
        vm.expectRevert(PayoutEscrow.ZeroAmount.selector);
        escrow.fund(0);

        // Zero amount withdraw
        vm.prank(safeAddr);
        vm.expectRevert(PayoutEscrow.ZeroAmount.selector);
        escrow.withdraw(0);

        // Withdraw more than balance
        _fundEscrow(100e6);
        vm.prank(safeAddr);
        vm.expectRevert(
            abi.encodeWithSelector(PayoutEscrow.InsufficientEscrowBalance.selector, 200e6, 100e6)
        );
        escrow.withdraw(200e6);

        // Zero address authorization
        vm.prank(safeAddr);
        vm.expectRevert(PayoutEscrow.ZeroAddress.selector);
        escrow.authorizeMatch(address(0));
    }

    // ═════════════════════════════════════════════════════════════════════
    // TEST 16: Constructor validation
    // ═════════════════════════════════════════════════════════════════════

    function test_EscrowConstructorValidation() public {
        vm.expectRevert(PayoutEscrow.ZeroAddress.selector);
        new PayoutEscrow(address(0), safeAddr);
    }

    // ═════════════════════════════════════════════════════════════════════
    // TEST 17: Multiple matches sharing one escrow
    // ═════════════════════════════════════════════════════════════════════

    function test_MultipleMatchesSharingEscrow() public {
        // Deploy second match
        bytes memory initData = abi.encodeWithSelector(
            FootballMatch.initialize.selector,
            "Second Match",
            owner
        );
        ERC1967Proxy proxy2 = new ERC1967Proxy(address(implementation), initData);
        FootballMatch match2 = FootballMatch(payable(address(proxy2)));

        vm.startPrank(owner);
        match2.grantRole(ODDS_SETTER_ROLE, oddsSetter);
        match2.grantRole(RESOLVER_ROLE, resolver);
        match2.setUSDTToken(address(usdt));
        match2.setPayoutEscrow(address(escrow));
        match2.addMarketWithLine(MARKET_WINNER, 20000, 0);
        match2.openMarket(0);
        vm.stopPrank();

        // Authorize second match in escrow
        vm.prank(safeAddr);
        escrow.authorizeMatch(address(match2));

        // Setup first match
        _createAndOpenMarket(20000);

        // Pre-fund both matches for solvency
        _fundMatchDirect(100e6);              // footballMatch
        usdt.mint(address(match2), 100e6);     // match2

        // Alice bets on match1, Bob bets on match2
        _placeBet(alice, 0, 0, 100e6);

        vm.startPrank(bob);
        usdt.approve(address(match2), 100e6);
        match2.placeBetUSDT(0, 0, 100e6);
        vm.stopPrank();

        // Close and resolve both matches
        vm.prank(owner);
        footballMatch.closeMarket(0);
        vm.prank(resolver);
        footballMatch.resolveMarket(0, 0);
        vm.prank(owner);
        match2.closeMarket(0);
        vm.prank(resolver);
        match2.resolveMarket(0, 0);

        // Drain pre-funds from both matches to leave only bet deposits
        vm.startPrank(owner);
        footballMatch.emergencyPause();
        footballMatch.emergencyWithdrawUSDT(100e6);
        footballMatch.unpause();
        match2.emergencyPause();
        match2.emergencyWithdrawUSDT(100e6);
        match2.unpause();
        vm.stopPrank();

        // Fund escrow to cover deficit for both matches
        // Each match has 100 (bet deposit), payout 200, deficit 100 each = 200
        _fundEscrow(200e6);

        // Claim from match1
        uint256 aliceBefore = usdt.balanceOf(alice);
        vm.prank(alice);
        footballMatch.claim(0, 0);
        assertEq(usdt.balanceOf(alice) - aliceBefore, 200e6);

        // Claim from match2
        uint256 bobBefore = usdt.balanceOf(bob);
        vm.prank(bob);
        match2.claim(0, 0);
        assertEq(usdt.balanceOf(bob) - bobBefore, 200e6);

        // Verify escrow tracked per-match disbursements
        assertEq(escrow.disbursedPerMatch(address(footballMatch)), 100e6);
        assertEq(escrow.disbursedPerMatch(address(match2)), 100e6);
        assertEq(escrow.totalDisbursed(), 200e6);
    }

    // ═════════════════════════════════════════════════════════════════════
    // TEST 18: Escrow availableBalance view
    // ═════════════════════════════════════════════════════════════════════

    function test_EscrowAvailableBalance() public {
        assertEq(escrow.availableBalance(), 0);

        _fundEscrow(1000e6);
        assertEq(escrow.availableBalance(), 1000e6);

        vm.prank(safeAddr);
        escrow.withdraw(400e6);
        assertEq(escrow.availableBalance(), 600e6);
    }
}
