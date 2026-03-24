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
 * @notice Tests for the full payout lifecycle with PayoutEscrow integration
 *
 * Coverage:
 *   1.  Full lifecycle: create match â†’ bet â†’ resolve â†’ fund escrow â†’ claim
 *   2.  Claim from contract balance only (no escrow needed)
 *   3.  Claim from escrow fallback (contract has zero USDC)
 *   4.  Mixed source: partial contract + partial escrow
 *   5.  Double claim prevention
 *   6.  Insufficient funding (both sources empty) â†’ revert
 *   7.  Unauthorized match â†’ escrow reverts
 *   8.  Escrow paused â†’ claims fail
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

        // Deploy PayoutEscrow owned by Safe
        escrow = new PayoutEscrow(address(usdc), safeAddr);

        // Deploy FootballMatch proxy
        implementation = new FootballMatch();
        bytes memory initData = abi.encodeWithSelector(
            FootballMatch.initialize.selector,
            "Test Match",
            owner
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        footballMatch = FootballMatch(payable(address(proxy)));

        // Setup roles, USDC, and escrow on the match contract
        vm.startPrank(owner);
        footballMatch.grantRole(ODDS_SETTER_ROLE, oddsSetter);
        footballMatch.grantRole(RESOLVER_ROLE, resolver);
        footballMatch.setUSDCToken(address(usdc));
        footballMatch.setPayoutEscrow(address(escrow));
        vm.stopPrank();

        // Authorize match in escrow (cap: 1M USDC)
        vm.prank(safeAddr);
        escrow.authorizeMatch(address(footballMatch), 1_000_000e6);

        // Fund test users (100k USDC each)
        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 100_000e6);
        usdc.mint(charlie, 100_000e6);

        // NOTE: Do NOT blanket pre-fund the match here.
        // Each test that needs solvency pre-funding adds it explicitly
        // via _fundMatchDirect() before placing bets.
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // HELPERS
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

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

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // TEST 1: Full payout lifecycle with escrow
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

    function test_FullPayoutLifecycle() public {
        // Create market, 2.0x odds
        _createAndOpenMarket(20000);

        // Pre-fund for solvency check during bet placement
        _fundMatchDirect(100e6);

        // Alice bets 100 USDC at 2.0x â†’ potential payout 200 USDC
        // Contract receives 100 USDC from bet, needs 100 more for profit portion
        _placeBet(alice, 0, 0, 100e6);

        // Resolve: Home (0) wins
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

        // Alice claims
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        footballMatch.claim(0, 0);
        uint256 payout = usdc.balanceOf(alice) - aliceBefore;

        assertEq(payout, 200e6, "Alice should receive 200 USDC (100 * 2.0x)");
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // TEST 2: Claim entirely from contract balance (no escrow needed)
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

    function test_ClaimFromContractBalanceOnly() public {
        _createAndOpenMarket(20000);

        // Pre-fund for solvency + enough to cover full payout from contract
        _fundMatchDirect(200e6);
        _placeBet(alice, 0, 0, 100e6);

        vm.prank(owner);
        footballMatch.closeMarket(0);
        vm.prank(resolver);
        footballMatch.resolveMarket(0, 0);

        // Contract has 300 (200 pre-fund + 100 bet), payout 200 â†’ no escrow needed
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        footballMatch.claim(0, 0);

        assertEq(usdc.balanceOf(alice) - aliceBefore, 200e6, "Should pay from contract balance");
        // Escrow should not have been touched
        assertEq(escrow.totalDisbursed(), 0, "Escrow should not be touched");
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // TEST 3: Claim entirely from escrow fallback (contract has 0 extra)
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

    function test_ClaimFromEscrowFallback() public {
        _createAndOpenMarket(20000);

        // Fund match with enough USDC for the solvency check during bet placement
        _fundMatchDirect(200e6);
        _placeBet(alice, 0, 0, 100e6);

        vm.prank(owner);
        footballMatch.closeMarket(0);
        vm.prank(resolver);
        footballMatch.resolveMarket(0, 0);

        // Drain match contract USDC to simulate unfunded state
        // (In production, the contract just has bet deposits, which are < payout)
        // Contract has 300 USDC (200 pre-funded + 100 from bet), payout is 200
        // Withdraw extra to leave only 50 USDC in the contract
        vm.prank(owner);
        footballMatch.emergencyPause();
        vm.prank(owner);
        footballMatch.emergencyWithdrawUSDC(250e6);
        vm.prank(owner);
        footballMatch.unpause();

        // Contract has 50 USDC, payout is 200 USDC, deficit is 150 USDC
        assertEq(usdc.balanceOf(address(footballMatch)), 50e6);

        // Fund escrow to cover the deficit
        _fundEscrow(150e6);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        footballMatch.claim(0, 0);

        assertEq(usdc.balanceOf(alice) - aliceBefore, 200e6, "Should get full payout");
        assertEq(escrow.totalDisbursed(), 150e6, "Escrow should have disbursed 150 USDC");
        assertEq(escrow.disbursedPerMatch(address(footballMatch)), 150e6);
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // TEST 4: Mixed source claim (partial contract + partial escrow)
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

    function test_ClaimFromMixedSources() public {
        _createAndOpenMarket(30000); // 3.0x odds

        // Pre-fund match for solvency check
        _fundMatchDirect(300e6);
        _placeBet(alice, 0, 0, 100e6);

        vm.prank(owner);
        footballMatch.closeMarket(0);
        vm.prank(resolver);
        footballMatch.resolveMarket(0, 0);

        // Contract has 400 USDC (300 pre-funded + 100 from bet)
        // Payout is 300 USDC â†’ contract has enough
        // Withdraw to leave only 200 USDC (deficit of 100)
        vm.prank(owner);
        footballMatch.emergencyPause();
        vm.prank(owner);
        footballMatch.emergencyWithdrawUSDC(200e6);
        vm.prank(owner);
        footballMatch.unpause();

        assertEq(usdc.balanceOf(address(footballMatch)), 200e6);

        // Fund escrow with 100 USDC to cover the deficit
        _fundEscrow(100e6);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        footballMatch.claim(0, 0);

        assertEq(usdc.balanceOf(alice) - aliceBefore, 300e6, "Alice gets 3.0x payout");
        assertEq(escrow.totalDisbursed(), 100e6, "Escrow covers deficit only");
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // TEST 5: Double claim prevention
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

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

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // TEST 6: Insufficient funding (both contract and escrow empty)
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

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
        footballMatch.emergencyWithdrawUSDC(300e6); // drain everything
        vm.prank(owner);
        footballMatch.unpause();

        assertEq(usdc.balanceOf(address(footballMatch)), 0);

        // Escrow also empty
        assertEq(usdc.balanceOf(address(escrow)), 0);

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

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // TEST 6b: Insufficient funding without escrow set â†’ original revert
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

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
        footballMatch.emergencyWithdrawUSDC(300e6);
        vm.prank(owner);
        footballMatch.unpause();

        // Without escrow, reverts with InsufficientUSDCBalance
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(BettingMatch.InsufficientUSDCBalance.selector, 200e6, 0)
        );
        footballMatch.claim(0, 0);
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // TEST 7: Unauthorized match cannot use escrow
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

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
        unauthorizedMatch.setUSDCToken(address(usdc));
        unauthorizedMatch.setPayoutEscrow(address(escrow));
        unauthorizedMatch.grantRole(RESOLVER_ROLE, resolver);
        unauthorizedMatch.addMarketWithLine(MARKET_WINNER, 20000, 0);
        unauthorizedMatch.openMarket(0);
        vm.stopPrank();

        _fundMatchDirect(200e6); // for footballMatch (won't help this one)

        // Fund unauthorizedMatch enough for solvency check
        usdc.mint(address(unauthorizedMatch), 200e6);

        vm.startPrank(alice);
        usdc.approve(address(unauthorizedMatch), 100e6);
        unauthorizedMatch.placeBetUSDC(0, 0, 100e6);
        vm.stopPrank();

        vm.prank(owner);
        unauthorizedMatch.closeMarket(0);
        vm.prank(resolver);
        unauthorizedMatch.resolveMarket(0, 0);

        // Drain match to force escrow fallback
        vm.prank(owner);
        unauthorizedMatch.emergencyPause();
        vm.prank(owner);
        unauthorizedMatch.emergencyWithdrawUSDC(300e6);
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

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // TEST 8: Escrow paused blocks disbursements
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

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
        footballMatch.emergencyWithdrawUSDC(200e6); // drain all
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

        // Unpause â†’ claim succeeds
        vm.prank(safeAddr);
        escrow.unpause();

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        footballMatch.claim(0, 0);
        assertEq(usdc.balanceOf(alice) - aliceBefore, 200e6);
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // TEST 9: Escrow owner can withdraw
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

    function test_EscrowWithdrawByOwner() public {
        // Revoke the match authorized in setUp to free up the allocation
        vm.prank(safeAddr);
        escrow.revokeMatch(address(footballMatch));

        _fundEscrow(500e6);

        assertEq(usdc.balanceOf(address(escrow)), 500e6);
        assertEq(escrow.freeBalance(), 500e6);

        vm.prank(safeAddr);
        escrow.withdraw(200e6);
        assertEq(usdc.balanceOf(address(escrow)), 300e6);
        assertEq(usdc.balanceOf(safeAddr), 200e6);

        // Non-owner cannot withdraw
        vm.prank(alice);
        vm.expectRevert();
        escrow.withdraw(100e6);
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // TEST 10: ClaimAll with escrow fallback
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

    function test_ClaimAllWithEscrow() public {
        _createAndOpenMarket(20000);

        // Pre-fund for solvency: after 2 bets, liability = 200+250 = 450
        _fundMatchDirect(250e6);
        _placeBet(alice, 0, 0, 100e6);

        // Change odds and place another bet
        vm.prank(oddsSetter);
        footballMatch.setMarketOdds(0, 25000);
        _placeBet(alice, 0, 0, 100e6);

        // Close and resolve â†’ Home wins
        vm.prank(owner);
        footballMatch.closeMarket(0);
        vm.prank(resolver);
        footballMatch.resolveMarket(0, 0);

        // Contract has 450 (250 pre-fund + 200 bets), payout = 450
        // Drain pre-fund to leave only bet deposits
        vm.prank(owner);
        footballMatch.emergencyPause();
        vm.prank(owner);
        footballMatch.emergencyWithdrawUSDC(250e6);
        vm.prank(owner);
        footballMatch.unpause();

        // Contract has 200 USDC (bet deposits). Deficit = 250
        _fundEscrow(250e6);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        footballMatch.claimAll(0);

        assertEq(usdc.balanceOf(alice) - aliceBefore, 450e6, "ClaimAll should pay 450 USDC");
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // TEST 11: Refund with escrow fallback (cancelled market)
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

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
        footballMatch.emergencyWithdrawUSDC(200e6);
        vm.prank(owner);
        footballMatch.unpause();

        _fundEscrow(100e6);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        footballMatch.claimRefund(0, 0);

        assertEq(usdc.balanceOf(alice) - aliceBefore, 100e6, "Should refund full amount");
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // TEST 12: getFundingDeficit view
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

    function test_GetFundingDeficit() public {
        _createAndOpenMarket(20000);

        // Before any bets â†’ deficit = 0
        assertEq(footballMatch.getFundingDeficit(), 0);

        // Pre-fund match for solvency check
        _fundMatchDirect(500e6);

        // Alice bets 100 USDC at 2.0x â†’ liability = 200
        _placeBet(alice, 0, 0, 100e6);

        // Contract has 600 (500 + 100 from bet), liabilities = 200 â†’ no deficit
        assertEq(footballMatch.getFundingDeficit(), 0);

        // Bob bets 200 USDC at 2.0x â†’ liability += 400, total = 600
        _placeBet(bob, 0, 0, 200e6);

        // Contract has 800 (500 + 100 + 200), liabilities = 600 â†’ no deficit
        assertEq(footballMatch.getFundingDeficit(), 0);

        // Drain some funds
        vm.prank(owner);
        footballMatch.emergencyPause();
        vm.prank(owner);
        footballMatch.emergencyWithdrawUSDC(500e6);
        vm.prank(owner);
        footballMatch.unpause();

        // Contract has 300, liabilities = 600 â†’ deficit = 300
        assertEq(footballMatch.getFundingDeficit(), 300e6);
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // TEST 13: setPayoutEscrow admin control
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

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

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // TEST 14: Escrow authorization lifecycle
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

    function test_EscrowAuthorizationLifecycle() public {
        address newMatch = address(0x456);

        // Initially not authorized
        assertFalse(escrow.authorizedMatches(newMatch));

        // Authorize
        vm.prank(safeAddr);
        escrow.authorizeMatch(newMatch, 1_000_000e6);
        assertTrue(escrow.authorizedMatches(newMatch));

        // Revoke
        vm.prank(safeAddr);
        escrow.revokeMatch(newMatch);
        assertFalse(escrow.authorizedMatches(newMatch));

        // Non-owner cannot authorize
        vm.prank(alice);
        vm.expectRevert();
        escrow.authorizeMatch(newMatch, 1_000_000e6);
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // TEST 15: Escrow validation errors
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

    function test_EscrowValidationErrors() public {
        // Zero amount fund
        vm.prank(safeAddr);
        vm.expectRevert(PayoutEscrow.ZeroAmount.selector);
        escrow.fund(0);

        // Zero amount withdraw
        vm.prank(safeAddr);
        vm.expectRevert(PayoutEscrow.ZeroAmount.selector);
        escrow.withdraw(0);

        // Withdraw more than free balance
        // Revoke match first so funded amount becomes free
        vm.prank(safeAddr);
        escrow.revokeMatch(address(footballMatch));
        _fundEscrow(100e6);
        vm.prank(safeAddr);
        vm.expectRevert(
            abi.encodeWithSelector(PayoutEscrow.InsufficientFreeBalance.selector, 200e6, 100e6)
        );
        escrow.withdraw(200e6);

        // Zero address authorization
        vm.prank(safeAddr);
        vm.expectRevert(PayoutEscrow.ZeroAddress.selector);
        escrow.authorizeMatch(address(0), 1_000_000e6);
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // TEST 16: Constructor validation
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

    function test_EscrowConstructorValidation() public {
        vm.expectRevert(PayoutEscrow.ZeroAddress.selector);
        new PayoutEscrow(address(0), safeAddr);
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // TEST 17: Multiple matches sharing one escrow
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

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
        match2.setUSDCToken(address(usdc));
        match2.setPayoutEscrow(address(escrow));
        match2.addMarketWithLine(MARKET_WINNER, 20000, 0);
        match2.openMarket(0);
        vm.stopPrank();

        // Authorize second match in escrow (cap: 1M USDC)
        vm.prank(safeAddr);
        escrow.authorizeMatch(address(match2), 1_000_000e6);

        // Setup first match
        _createAndOpenMarket(20000);

        // Pre-fund both matches for solvency
        _fundMatchDirect(100e6);              // footballMatch
        usdc.mint(address(match2), 100e6);     // match2

        // Alice bets on match1, Bob bets on match2
        _placeBet(alice, 0, 0, 100e6);

        vm.startPrank(bob);
        usdc.approve(address(match2), 100e6);
        match2.placeBetUSDC(0, 0, 100e6);
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
        footballMatch.emergencyWithdrawUSDC(100e6);
        footballMatch.unpause();
        match2.emergencyPause();
        match2.emergencyWithdrawUSDC(100e6);
        match2.unpause();
        vm.stopPrank();

        // Fund escrow to cover deficit for both matches
        // Each match has 100 (bet deposit), payout 200, deficit 100 each = 200
        _fundEscrow(200e6);

        // Claim from match1
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        footballMatch.claim(0, 0);
        assertEq(usdc.balanceOf(alice) - aliceBefore, 200e6);

        // Claim from match2
        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        match2.claim(0, 0);
        assertEq(usdc.balanceOf(bob) - bobBefore, 200e6);

        // Verify escrow tracked per-match disbursements
        assertEq(escrow.disbursedPerMatch(address(footballMatch)), 100e6);
        assertEq(escrow.disbursedPerMatch(address(match2)), 100e6);
        assertEq(escrow.totalDisbursed(), 200e6);
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // TEST 18: Escrow availableBalance view
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

    function test_EscrowAvailableBalance() public {
        assertEq(escrow.availableBalance(), 0);

        _fundEscrow(1000e6);
        assertEq(escrow.availableBalance(), 1000e6);

        // Revoke match first so funded amount becomes free (not committed)
        vm.prank(safeAddr);
        escrow.revokeMatch(address(footballMatch));

        vm.prank(safeAddr);
        escrow.withdraw(400e6);
        assertEq(escrow.availableBalance(), 600e6);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // H-01: AlreadyAuthorized guard prevents double-auth inflation
    // ══════════════════════════════════════════════════════════════════════════

    function test_H01_AlreadyAuthorized_Reverts() public {
        // footballMatch was authorized in setUp; a second call must revert
        vm.prank(safeAddr);
        vm.expectRevert(abi.encodeWithSelector(
            PayoutEscrow.AlreadyAuthorized.selector,
            address(footballMatch)
        ));
        escrow.authorizeMatch(address(footballMatch), 500_000e6);
    }

    function test_H01_ReAuthorizeAfterRevoke_AccountsForDisbursed() public {
        // Initial: authorized at 1_000_000e6 -> totalAllocated = 1_000_000e6
        assertEq(escrow.totalAllocated(), 1_000_000e6);

        // Fund escrow and simulate 300 USDC disbursed by footballMatch
        _fundEscrow(300e6);
        vm.prank(address(footballMatch));
        escrow.disburseTo(alice, 300e6);
        // totalAllocated = 1_000_000e6 - 300e6 = 999_700e6
        assertEq(escrow.totalAllocated(), 999_700e6);
        assertEq(escrow.disbursedPerMatch(address(footballMatch)), 300e6);

        // Revoke: frees remaining 999_700e6 allocation
        vm.prank(safeAddr);
        escrow.revokeMatch(address(footballMatch));
        assertEq(escrow.totalAllocated(), 0);
        assertFalse(escrow.authorizedMatches(address(footballMatch)));

        // Re-authorize with cap=500e6; 300e6 already disbursed -> only 200e6 reserved
        vm.prank(safeAddr);
        escrow.authorizeMatch(address(footballMatch), 500e6);
        assertEq(escrow.totalAllocated(), 200e6);
        assertEq(escrow.matchCaps(address(footballMatch)), 500e6);
        assertTrue(escrow.authorizedMatches(address(footballMatch)));
    }
}
