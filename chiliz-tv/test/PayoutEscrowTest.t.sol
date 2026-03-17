// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test, console} from "forge-std/Test.sol";
import {BettingMatch} from "../src/betting/BettingMatch.sol";
import {FootballMatch} from "../src/betting/FootballMatch.sol";
import {PayoutEscrow} from "../src/betting/PayoutEscrow.sol";
import {IPayoutEscrow} from "../src/interfaces/IPayoutEscrow.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/**
 * @title PayoutEscrowTest
 * @notice Tests for the full payout lifecycle with per-match PayoutEscrow
 *
 * Architecture: each BettingMatch has a dedicated PayoutEscrow. Only that match's
 * proxy can call disburseTo(). No shared pool, no whitelist management.
 *
 * Coverage:
 *   1.  Full lifecycle: create match → bet → resolve → fund escrow → claim
 *   2.  Claim from contract balance only (no escrow needed)
 *   3.  Claim from escrow fallback (contract has zero USDC)
 *   4.  Mixed source: partial contract + partial escrow
 *   5.  Double claim prevention
 *   6.  Insufficient funding (both sources empty) → revert
 *   6b. Insufficient funding without escrow set → original revert
 *   7.  Unauthorized caller cannot use escrow
 *   8.  Escrow paused → claims fail
 *   9.  Escrow owner can withdraw
 *   10. ClaimAll with escrow fallback
 *   11. Refund with escrow fallback (cancelled market)
 *   12. getFundingDeficit view correctness
 *   13. setPayoutEscrow admin control
 *   14. Escrow isolation: two matches have independent escrows
 *   15. Escrow validation errors
 *   16. Constructor validation
 *   17. fund() is owner-only
 */
contract PayoutEscrowTest is Test {
    FootballMatch public implementation;
    FootballMatch public footballMatch;
    PayoutEscrow public escrow;
    MockUSDC public usdc;

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
        // Deploy mock USDC
        usdc = new MockUSDC();

        // Deploy FootballMatch proxy
        implementation = new FootballMatch();
        bytes memory initData = abi.encodeWithSelector(
            FootballMatch.initialize.selector,
            "Test Match",
            owner
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        footballMatch = FootballMatch(payable(address(proxy)));

        // Deploy dedicated PayoutEscrow for this match, owned by the Safe
        escrow = new PayoutEscrow(address(usdc), address(footballMatch), safeAddr);

        // Setup roles, USDC, and escrow on the match contract
        vm.startPrank(owner);
        footballMatch.grantRole(ODDS_SETTER_ROLE, oddsSetter);
        footballMatch.grantRole(RESOLVER_ROLE, resolver);
        footballMatch.setUSDCToken(address(usdc));
        footballMatch.setPayoutEscrow(address(escrow));
        vm.stopPrank();

        // Fund test users (100k USDC each)
        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 100_000e6);
        usdc.mint(charlie, 100_000e6);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // HELPERS
    // ══════════════════════════════════════════════════════════════════════════

    function _createAndOpenMarket(uint32 odds) internal {
        vm.prank(owner);
        footballMatch.addMarketWithLine(MARKET_WINNER, odds, 0);
        vm.prank(owner);
        footballMatch.openMarket(0);
    }

    function _placeBet(address user, uint256 marketId, uint64 selection, uint256 amount) internal {
        vm.startPrank(user);
        usdc.approve(address(footballMatch), amount);
        footballMatch.placeBetUSDC(marketId, selection, amount);
        vm.stopPrank();
    }

    function _fundEscrow(uint256 amount) internal {
        usdc.mint(safeAddr, amount);
        vm.startPrank(safeAddr);
        usdc.approve(address(escrow), amount);
        escrow.fund(amount);
        vm.stopPrank();
    }

    function _fundMatchDirect(uint256 amount) internal {
        usdc.mint(address(footballMatch), amount);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // TEST 1: Full payout lifecycle with escrow
    // ══════════════════════════════════════════════════════════════════════════

    function test_FullPayoutLifecycle() public {
        _createAndOpenMarket(20000);
        _fundMatchDirect(100e6);
        _placeBet(alice, 0, 0, 100e6);

        vm.prank(owner);
        footballMatch.closeMarket(0);
        vm.prank(resolver);
        footballMatch.resolveMarket(0, 0);

        // Drain pre-fund so only bet deposit remains (100 USDC)
        vm.prank(owner);
        footballMatch.emergencyPause();
        vm.prank(owner);
        footballMatch.emergencyWithdrawUSDC(100e6);
        vm.prank(owner);
        footballMatch.unpause();

        // Fund escrow with 100 USDC to cover deficit
        _fundEscrow(100e6);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        footballMatch.claim(0, 0);
        assertEq(usdc.balanceOf(alice) - aliceBefore, 200e6, "Alice should receive 200 USDC (100 * 2.0x)");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // TEST 2: Claim entirely from contract balance (no escrow needed)
    // ══════════════════════════════════════════════════════════════════════════

    function test_ClaimFromContractBalanceOnly() public {
        _createAndOpenMarket(20000);
        _fundMatchDirect(200e6);
        _placeBet(alice, 0, 0, 100e6);

        vm.prank(owner);
        footballMatch.closeMarket(0);
        vm.prank(resolver);
        footballMatch.resolveMarket(0, 0);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        footballMatch.claim(0, 0);

        assertEq(usdc.balanceOf(alice) - aliceBefore, 200e6, "Should pay from contract balance");
        assertEq(escrow.totalDisbursed(), 0, "Escrow should not be touched");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // TEST 3: Claim entirely from escrow fallback (contract has 0 extra)
    // ══════════════════════════════════════════════════════════════════════════

    function test_ClaimFromEscrowFallback() public {
        _createAndOpenMarket(20000);
        _fundMatchDirect(200e6);
        _placeBet(alice, 0, 0, 100e6);

        vm.prank(owner);
        footballMatch.closeMarket(0);
        vm.prank(resolver);
        footballMatch.resolveMarket(0, 0);

        // Withdraw extra to leave only 50 USDC in the contract
        vm.prank(owner);
        footballMatch.emergencyPause();
        vm.prank(owner);
        footballMatch.emergencyWithdrawUSDC(250e6);
        vm.prank(owner);
        footballMatch.unpause();

        assertEq(usdc.balanceOf(address(footballMatch)), 50e6);

        _fundEscrow(150e6);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        footballMatch.claim(0, 0);

        assertEq(usdc.balanceOf(alice) - aliceBefore, 200e6, "Should get full payout");
        assertEq(escrow.totalDisbursed(), 150e6, "Escrow should have disbursed 150 USDC");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // TEST 4: Mixed source claim (partial contract + partial escrow)
    // ══════════════════════════════════════════════════════════════════════════

    function test_ClaimFromMixedSources() public {
        _createAndOpenMarket(30000); // 3.0x odds
        _fundMatchDirect(300e6);
        _placeBet(alice, 0, 0, 100e6);

        vm.prank(owner);
        footballMatch.closeMarket(0);
        vm.prank(resolver);
        footballMatch.resolveMarket(0, 0);

        // Leave only 200 USDC (deficit of 100)
        vm.prank(owner);
        footballMatch.emergencyPause();
        vm.prank(owner);
        footballMatch.emergencyWithdrawUSDC(200e6);
        vm.prank(owner);
        footballMatch.unpause();

        assertEq(usdc.balanceOf(address(footballMatch)), 200e6);
        _fundEscrow(100e6);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        footballMatch.claim(0, 0);

        assertEq(usdc.balanceOf(alice) - aliceBefore, 300e6, "Alice gets 3.0x payout");
        assertEq(escrow.totalDisbursed(), 100e6, "Escrow covers deficit only");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // TEST 5: Double claim prevention
    // ══════════════════════════════════════════════════════════════════════════

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

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(BettingMatch.AlreadyClaimed.selector, 0, alice, 0)
        );
        footballMatch.claim(0, 0);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // TEST 6: Insufficient funding (both contract and escrow empty)
    // ══════════════════════════════════════════════════════════════════════════

    function test_InsufficientFundingReverts() public {
        _createAndOpenMarket(20000);
        _fundMatchDirect(200e6);
        _placeBet(alice, 0, 0, 100e6);

        vm.prank(owner);
        footballMatch.closeMarket(0);
        vm.prank(resolver);
        footballMatch.resolveMarket(0, 0);

        vm.prank(owner);
        footballMatch.emergencyPause();
        vm.prank(owner);
        footballMatch.emergencyWithdrawUSDC(300e6);
        vm.prank(owner);
        footballMatch.unpause();

        assertEq(usdc.balanceOf(address(footballMatch)), 0);
        assertEq(usdc.balanceOf(address(escrow)), 0);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(PayoutEscrow.InsufficientEscrowBalance.selector, 200e6, 0)
        );
        footballMatch.claim(0, 0);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // TEST 6b: Insufficient funding without escrow set → original revert
    // ══════════════════════════════════════════════════════════════════════════

    function test_NoEscrowInsufficientReverts() public {
        vm.prank(owner);
        footballMatch.setPayoutEscrow(address(0));

        _createAndOpenMarket(20000);
        _fundMatchDirect(200e6);
        _placeBet(alice, 0, 0, 100e6);

        vm.prank(owner);
        footballMatch.closeMarket(0);
        vm.prank(resolver);
        footballMatch.resolveMarket(0, 0);

        vm.prank(owner);
        footballMatch.emergencyPause();
        vm.prank(owner);
        footballMatch.emergencyWithdrawUSDC(300e6);
        vm.prank(owner);
        footballMatch.unpause();

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(BettingMatch.InsufficientUSDCBalance.selector, 200e6, 0)
        );
        footballMatch.claim(0, 0);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // TEST 7: Unauthorized caller cannot use escrow
    // ══════════════════════════════════════════════════════════════════════════

    function test_UnauthorizedCallerReverts() public {
        _fundEscrow(500e6);

        // Direct call from attacker
        vm.prank(address(0xBEEF));
        vm.expectRevert(
            abi.encodeWithSelector(PayoutEscrow.UnauthorizedCaller.selector, address(0xBEEF))
        );
        escrow.disburseTo(address(0xBEEF), 100e6);

        // A second match pointing to the same escrow cannot disburse
        bytes memory initData = abi.encodeWithSelector(
            FootballMatch.initialize.selector,
            "Other Match",
            owner
        );
        ERC1967Proxy proxy2 = new ERC1967Proxy(address(implementation), initData);
        FootballMatch otherMatch = FootballMatch(payable(address(proxy2)));

        vm.startPrank(owner);
        otherMatch.setUSDCToken(address(usdc));
        otherMatch.setPayoutEscrow(address(escrow)); // points to footballMatch's escrow
        otherMatch.addMarketWithLine(MARKET_WINNER, 20000, 0);
        otherMatch.openMarket(0);
        vm.stopPrank();

        usdc.mint(address(otherMatch), 200e6);

        vm.startPrank(alice);
        usdc.approve(address(otherMatch), 100e6);
        otherMatch.placeBetUSDC(0, 0, 100e6);
        vm.stopPrank();

        vm.prank(owner);
        otherMatch.closeMarket(0);
        vm.prank(owner);
        otherMatch.resolveMarket(0, 0);

        // Drain to force escrow fallback
        vm.prank(owner);
        otherMatch.emergencyPause();
        vm.prank(owner);
        otherMatch.emergencyWithdrawUSDC(300e6);
        vm.prank(owner);
        otherMatch.unpause();

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(PayoutEscrow.UnauthorizedCaller.selector, address(otherMatch))
        );
        otherMatch.claim(0, 0);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // TEST 8: Escrow paused blocks disbursements
    // ══════════════════════════════════════════════════════════════════════════

    function test_EscrowPauseBlocksClaims() public {
        _createAndOpenMarket(20000);
        _fundMatchDirect(100e6);
        _placeBet(alice, 0, 0, 100e6);

        vm.prank(owner);
        footballMatch.closeMarket(0);
        vm.prank(resolver);
        footballMatch.resolveMarket(0, 0);

        vm.prank(owner);
        footballMatch.emergencyPause();
        vm.prank(owner);
        footballMatch.emergencyWithdrawUSDC(200e6);
        vm.prank(owner);
        footballMatch.unpause();

        _fundEscrow(200e6);

        vm.prank(safeAddr);
        escrow.pause();

        vm.prank(alice);
        vm.expectRevert(); // Pausable: EnforcedPause
        footballMatch.claim(0, 0);

        vm.prank(safeAddr);
        escrow.unpause();

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        footballMatch.claim(0, 0);
        assertEq(usdc.balanceOf(alice) - aliceBefore, 200e6);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // TEST 9: Escrow owner can withdraw
    // ══════════════════════════════════════════════════════════════════════════

    function test_EscrowWithdrawByOwner() public {
        _fundEscrow(500e6);

        assertEq(usdc.balanceOf(address(escrow)), 500e6);

        vm.prank(safeAddr);
        escrow.withdraw(200e6);
        assertEq(usdc.balanceOf(address(escrow)), 300e6);
        assertEq(usdc.balanceOf(safeAddr), 200e6);

        vm.prank(alice);
        vm.expectRevert();
        escrow.withdraw(100e6);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // TEST 10: ClaimAll with escrow fallback
    // ══════════════════════════════════════════════════════════════════════════

    function test_ClaimAllWithEscrow() public {
        _createAndOpenMarket(20000);
        _fundMatchDirect(250e6);
        _placeBet(alice, 0, 0, 100e6);

        vm.prank(oddsSetter);
        footballMatch.setMarketOdds(0, 25000);
        _placeBet(alice, 0, 0, 100e6);

        vm.prank(owner);
        footballMatch.closeMarket(0);
        vm.prank(resolver);
        footballMatch.resolveMarket(0, 0);

        vm.prank(owner);
        footballMatch.emergencyPause();
        vm.prank(owner);
        footballMatch.emergencyWithdrawUSDC(250e6);
        vm.prank(owner);
        footballMatch.unpause();

        _fundEscrow(250e6);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        footballMatch.claimAll(0);

        assertEq(usdc.balanceOf(alice) - aliceBefore, 450e6, "ClaimAll should pay 450 USDC");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // TEST 11: Refund with escrow fallback (cancelled market)
    // ══════════════════════════════════════════════════════════════════════════

    function test_RefundWithEscrow() public {
        _createAndOpenMarket(20000);
        _fundMatchDirect(100e6);
        _placeBet(alice, 0, 0, 100e6);

        vm.prank(owner);
        footballMatch.cancelMarket(0, "Match postponed");

        vm.prank(owner);
        footballMatch.emergencyPause();
        vm.prank(owner);
        footballMatch.emergencyWithdrawUSDC(200e6);
        vm.prank(owner);
        footballMatch.unpause();

        _fundEscrow(100e6);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        footballMatch.claimRefund(0, 0);

        assertEq(usdc.balanceOf(alice) - aliceBefore, 100e6, "Should refund full amount");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // TEST 12: getFundingDeficit view
    // ══════════════════════════════════════════════════════════════════════════

    function test_GetFundingDeficit() public {
        _createAndOpenMarket(20000);

        assertEq(footballMatch.getFundingDeficit(), 0);

        _fundMatchDirect(500e6);
        _placeBet(alice, 0, 0, 100e6);
        assertEq(footballMatch.getFundingDeficit(), 0);

        _placeBet(bob, 0, 0, 200e6);
        assertEq(footballMatch.getFundingDeficit(), 0);

        vm.prank(owner);
        footballMatch.emergencyPause();
        vm.prank(owner);
        footballMatch.emergencyWithdrawUSDC(500e6);
        vm.prank(owner);
        footballMatch.unpause();

        // Contract has 300 (bets), liabilities = 600 → deficit = 300
        assertEq(footballMatch.getFundingDeficit(), 300e6);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // TEST 13: setPayoutEscrow admin control
    // ══════════════════════════════════════════════════════════════════════════

    function test_SetPayoutEscrow() public {
        vm.prank(alice);
        vm.expectRevert();
        footballMatch.setPayoutEscrow(address(0x999));

        vm.prank(owner);
        footballMatch.setPayoutEscrow(address(0x999));
        assertEq(address(footballMatch.payoutEscrow()), address(0x999));

        vm.prank(owner);
        footballMatch.setPayoutEscrow(address(0));
        assertEq(address(footballMatch.payoutEscrow()), address(0));
    }

    // ══════════════════════════════════════════════════════════════════════════
    // TEST 14: Escrow isolation — two matches have independent escrows
    // ══════════════════════════════════════════════════════════════════════════

    function test_EscrowIsolation() public {
        // Deploy second match with its own dedicated escrow
        bytes memory initData = abi.encodeWithSelector(
            FootballMatch.initialize.selector,
            "Second Match",
            owner
        );
        ERC1967Proxy proxy2 = new ERC1967Proxy(address(implementation), initData);
        FootballMatch match2 = FootballMatch(payable(address(proxy2)));
        PayoutEscrow escrow2 = new PayoutEscrow(address(usdc), address(match2), safeAddr);

        vm.startPrank(owner);
        match2.grantRole(RESOLVER_ROLE, resolver);
        match2.setUSDCToken(address(usdc));
        match2.setPayoutEscrow(address(escrow2));
        match2.addMarketWithLine(MARKET_WINNER, 20000, 0);
        match2.openMarket(0);
        vm.stopPrank();

        _createAndOpenMarket(20000);

        // Pre-fund both matches
        _fundMatchDirect(100e6);
        usdc.mint(address(match2), 100e6);

        // Alice bets on match1, Bob bets on match2
        _placeBet(alice, 0, 0, 100e6);

        vm.startPrank(bob);
        usdc.approve(address(match2), 100e6);
        match2.placeBetUSDC(0, 0, 100e6);
        vm.stopPrank();

        // Resolve both
        vm.prank(owner);
        footballMatch.closeMarket(0);
        vm.prank(resolver);
        footballMatch.resolveMarket(0, 0);
        vm.prank(owner);
        match2.closeMarket(0);
        vm.prank(resolver);
        match2.resolveMarket(0, 0);

        // Drain pre-funds from both matches
        vm.startPrank(owner);
        footballMatch.emergencyPause();
        footballMatch.emergencyWithdrawUSDC(100e6);
        footballMatch.unpause();
        match2.emergencyPause();
        match2.emergencyWithdrawUSDC(100e6);
        match2.unpause();
        vm.stopPrank();

        // Fund each escrow separately
        _fundEscrow(100e6); // escrow for match1 only

        usdc.mint(safeAddr, 100e6);
        vm.startPrank(safeAddr);
        usdc.approve(address(escrow2), 100e6);
        escrow2.fund(100e6);
        vm.stopPrank();

        // Verify escrow1 cannot be drained by match2 (isolation)
        assertEq(escrow.authorizedMatch(), address(footballMatch));
        assertEq(escrow2.authorizedMatch(), address(match2));

        // Claims succeed independently
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        footballMatch.claim(0, 0);
        assertEq(usdc.balanceOf(alice) - aliceBefore, 200e6);

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        match2.claim(0, 0);
        assertEq(usdc.balanceOf(bob) - bobBefore, 200e6);

        // Each escrow only disbursed its own funds
        assertEq(escrow.totalDisbursed(), 100e6);
        assertEq(escrow2.totalDisbursed(), 100e6);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // TEST 15: Escrow validation errors
    // ══════════════════════════════════════════════════════════════════════════

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
    }

    // ══════════════════════════════════════════════════════════════════════════
    // TEST 16: Constructor validation
    // ══════════════════════════════════════════════════════════════════════════

    function test_EscrowConstructorValidation() public {
        // Zero USDC address
        vm.expectRevert(PayoutEscrow.ZeroAddress.selector);
        new PayoutEscrow(address(0), address(footballMatch), safeAddr);

        // Zero authorized match
        vm.expectRevert(PayoutEscrow.ZeroAddress.selector);
        new PayoutEscrow(address(usdc), address(0), safeAddr);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // TEST 17: fund() is owner-only
    // ══════════════════════════════════════════════════════════════════════════

    function test_FundIsOwnerOnly() public {
        usdc.mint(alice, 100e6);

        vm.startPrank(alice);
        usdc.approve(address(escrow), 100e6);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        escrow.fund(100e6);
        vm.stopPrank();

        // Owner can fund
        _fundEscrow(100e6);
        assertEq(escrow.availableBalance(), 100e6);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // TEST 18: availableBalance view
    // ══════════════════════════════════════════════════════════════════════════

    function test_EscrowAvailableBalance() public {
        assertEq(escrow.availableBalance(), 0);

        _fundEscrow(1000e6);
        assertEq(escrow.availableBalance(), 1000e6);

        vm.prank(safeAddr);
        escrow.withdraw(400e6);
        assertEq(escrow.availableBalance(), 600e6);
    }
}
