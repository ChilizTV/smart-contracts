// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test, console} from "forge-std/Test.sol";
import {BettingMatch} from "../src/betting/BettingMatch.sol";
import {FootballMatch} from "../src/betting/FootballMatch.sol";
import {BettingSwapRouter} from "../src/betting/BettingSwapRouter.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockKayenRouter} from "./mocks/MockKayenRouter.sol";

/**
 * @title SwapIntegrationTest
 * @notice Tests for Kayen DEX swap integration with betting system
 *
 * Test Coverage:
 * 1. USDC betting: place bet, claim, refund in USDC
 * 2. CHZ→USDC swap via BettingSwapRouter
 * 3. Slippage and deadline revert
 * 4. Treasury solvency checks
 * 5. Mixed CHZ + USDC bets and claims
 */
contract SwapIntegrationTest is Test {
    FootballMatch public implementation;
    FootballMatch public footballMatch;
    MockUSDC public usdc;
    MockKayenRouter public mockRouter;
    BettingSwapRouter public swapRouter;

    address public owner = address(0x1);
    address public oddsSetter = address(0x2);
    address public resolver = address(0x3);
    address public alice = address(0x100);
    address public bob = address(0x101);
    address public charlie = address(0x102);

    // Placeholder WCHZ address for path construction (mock wrapped CHZ)
    address public constant WCHZ = address(0xC42);

    bytes32 constant ODDS_SETTER_ROLE = keccak256("ODDS_SETTER_ROLE");
    bytes32 constant RESOLVER_ROLE = keccak256("RESOLVER_ROLE");
    bytes32 constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 constant SWAP_ROUTER_ROLE = keccak256("SWAP_ROUTER_ROLE");
    bytes32 constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    bytes32 constant MARKET_WINNER = keccak256("WINNER");

    uint32 constant ODDS_PRECISION = 10000;

    function setUp() public {
        // Deploy mock USDC
        usdc = new MockUSDC();

        // Deploy mock Kayen router
        mockRouter = new MockKayenRouter(address(usdc));

        // Deploy betting implementation + proxy
        implementation = new FootballMatch();
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
        footballMatch.setUSDCToken(address(usdc));
        vm.stopPrank();

        // Deploy swap router
        swapRouter = new BettingSwapRouter(
            address(mockRouter),
            address(usdc),
            WCHZ
        );

        // Grant SWAP_ROUTER_ROLE to swapRouter
        vm.prank(owner);
        footballMatch.grantRole(SWAP_ROUTER_ROLE, address(swapRouter));

        // Fund accounts
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(charlie, 100 ether);
        vm.deal(address(footballMatch), 1000 ether);

        // Mint USDC to users for direct USDC betting
        usdc.mint(alice, 1000e6);
        usdc.mint(bob, 1000e6);
        usdc.mint(charlie, 1000e6);

        // Fund contract with USDC for payouts (treasury solvency)
        usdc.mint(address(footballMatch), 10000e6);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // USDC BETTING TESTS
    // ══════════════════════════════════════════════════════════════════════════

    function test_PlaceBetUSDC() public {
        vm.prank(owner);
        footballMatch.addMarket(MARKET_WINNER, 20000); // 2.00x

        vm.prank(owner);
        footballMatch.openMarket(0);

        // Alice places USDC bet
        vm.startPrank(alice);
        usdc.approve(address(footballMatch), 100e6);
        footballMatch.placeBetUSDC(0, 0, 100e6);
        vm.stopPrank();

        // Verify bet was placed
        BettingMatch.Bet[] memory bets = footballMatch.getUserBets(0, alice);
        assertEq(bets.length, 1);
        assertEq(bets[0].amount, 100e6);
        assertTrue(bets[0].isUSDC);
        assertEq(bets[0].selection, 0);
    }

    function test_ClaimUSDC() public {
        vm.prank(owner);
        footballMatch.addMarket(MARKET_WINNER, 20000); // 2.00x

        vm.prank(owner);
        footballMatch.openMarket(0);

        // Alice places USDC bet
        vm.startPrank(alice);
        usdc.approve(address(footballMatch), 100e6);
        footballMatch.placeBetUSDC(0, 0, 100e6);
        vm.stopPrank();

        // Resolve - Home wins
        vm.prank(resolver);
        footballMatch.resolveMarket(0, 0);

        // Alice claims USDC payout
        uint256 aliceUSDCBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        footballMatch.claim(0, 0);
        uint256 aliceUSDCAfter = usdc.balanceOf(alice);

        // Expected: 100 USDC * 2.00x = 200 USDC
        assertEq(aliceUSDCAfter - aliceUSDCBefore, 200e6, "Should receive 200 USDC payout");
    }

    function test_RefundUSDCOnCancellation() public {
        vm.prank(owner);
        footballMatch.addMarket(MARKET_WINNER, 20000);

        vm.prank(owner);
        footballMatch.openMarket(0);

        vm.startPrank(alice);
        usdc.approve(address(footballMatch), 50e6);
        footballMatch.placeBetUSDC(0, 0, 50e6);
        vm.stopPrank();

        vm.prank(owner);
        footballMatch.cancelMarket(0, "Match cancelled");

        uint256 aliceUSDCBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        footballMatch.claimRefund(0, 0);
        uint256 aliceUSDCAfter = usdc.balanceOf(alice);

        assertEq(aliceUSDCAfter - aliceUSDCBefore, 50e6, "Should refund full USDC amount");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // SWAP ROUTER TESTS
    // ══════════════════════════════════════════════════════════════════════════

    function test_PlaceBetWithCHZSwap() public {
        vm.prank(owner);
        footballMatch.addMarket(MARKET_WINNER, 20000); // 2.00x

        vm.prank(owner);
        footballMatch.openMarket(0);

        // Alice sends CHZ, router swaps to USDC and places bet
        // 10 CHZ * 0.10 USDC/CHZ = 1 USDC (1_000_000 in 6 decimals)
        vm.prank(alice);
        swapRouter.placeBetWithCHZ{value: 10 ether}(
            address(footballMatch),
            0,      // marketId
            0,      // selection: Home
            0,      // amountOutMin (no slippage protection for test)
            block.timestamp + 1 hours // deadline
        );

        // Verify bet was placed for alice
        BettingMatch.Bet[] memory bets = footballMatch.getUserBets(0, alice);
        assertEq(bets.length, 1);
        assertTrue(bets[0].isUSDC);
        assertEq(bets[0].amount, 1e6, "Should be 1 USDC (10 CHZ * 0.10)");
    }

    function test_PlaceBetWithCHZSwapAndClaim() public {
        vm.prank(owner);
        footballMatch.addMarket(MARKET_WINNER, 20000); // 2.00x

        vm.prank(owner);
        footballMatch.openMarket(0);

        // Alice bets 10 CHZ -> 1 USDC at 2.00x -> payout 2 USDC
        vm.prank(alice);
        swapRouter.placeBetWithCHZ{value: 10 ether}(
            address(footballMatch),
            0, 0, 0,
            block.timestamp + 1 hours
        );

        // Resolve
        vm.prank(resolver);
        footballMatch.resolveMarket(0, 0);

        // Claim
        uint256 aliceUSDCBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        footballMatch.claim(0, 0);
        uint256 aliceUSDCAfter = usdc.balanceOf(alice);

        assertEq(aliceUSDCAfter - aliceUSDCBefore, 2e6, "Should claim 2 USDC payout");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // SLIPPAGE AND DEADLINE TESTS
    // ══════════════════════════════════════════════════════════════════════════

    function test_RevertOnExpiredDeadline() public {
        vm.prank(owner);
        footballMatch.addMarket(MARKET_WINNER, 20000);
        vm.prank(owner);
        footballMatch.openMarket(0);

        // Set deadline in the past
        vm.prank(alice);
        vm.expectRevert(BettingSwapRouter.DeadlinePassed.selector);
        swapRouter.placeBetWithCHZ{value: 10 ether}(
            address(footballMatch),
            0, 0, 0,
            block.timestamp - 1
        );
    }

    function test_RevertOnInsufficientSlippage() public {
        vm.prank(owner);
        footballMatch.addMarket(MARKET_WINNER, 20000);
        vm.prank(owner);
        footballMatch.openMarket(0);

        // Request more USDC than swap will produce
        // 10 CHZ * 0.10 = 1 USDC, but we request min 2 USDC
        vm.prank(alice);
        vm.expectRevert("MockRouter: insufficient output");
        swapRouter.placeBetWithCHZ{value: 10 ether}(
            address(footballMatch),
            0, 0, 2e6, // minOut = 2 USDC (too high)
            block.timestamp + 1 hours
        );
    }

    function test_RevertOnSwapFailure() public {
        vm.prank(owner);
        footballMatch.addMarket(MARKET_WINNER, 20000);
        vm.prank(owner);
        footballMatch.openMarket(0);

        // Make router fail
        mockRouter.setShouldFail(true);

        vm.prank(alice);
        vm.expectRevert("MockRouter: swap failed");
        swapRouter.placeBetWithCHZ{value: 10 ether}(
            address(footballMatch),
            0, 0, 0,
            block.timestamp + 1 hours
        );
    }

    // ══════════════════════════════════════════════════════════════════════════
    // TREASURY SOLVENCY TESTS
    // ══════════════════════════════════════════════════════════════════════════

    function test_SolvencyTracking() public {
        vm.prank(owner);
        footballMatch.addMarket(MARKET_WINNER, 20000); // 2.00x

        vm.prank(owner);
        footballMatch.openMarket(0);

        // Place USDC bet: 100 USDC at 2.00x = 200 USDC liability
        vm.startPrank(alice);
        usdc.approve(address(footballMatch), 100e6);
        footballMatch.placeBetUSDC(0, 0, 100e6);
        vm.stopPrank();

        (uint256 balance, uint256 liabilities, uint256 pool) = footballMatch.getUSDCSolvency();
        assertEq(liabilities, 200e6, "Liabilities should be 200 USDC");
        assertEq(pool, 100e6, "Pool should be 100 USDC");
        assertTrue(balance >= liabilities, "Balance should cover liabilities");
    }

    function test_SolvencyReducedOnClaim() public {
        vm.prank(owner);
        footballMatch.addMarket(MARKET_WINNER, 20000);
        vm.prank(owner);
        footballMatch.openMarket(0);

        vm.startPrank(alice);
        usdc.approve(address(footballMatch), 100e6);
        footballMatch.placeBetUSDC(0, 0, 100e6);
        vm.stopPrank();

        vm.prank(resolver);
        footballMatch.resolveMarket(0, 0);

        // Before claim
        (, uint256 liabilitiesBefore,) = footballMatch.getUSDCSolvency();
        assertEq(liabilitiesBefore, 200e6);

        // Claim
        vm.prank(alice);
        footballMatch.claim(0, 0);

        // After claim
        (, uint256 liabilitiesAfter,) = footballMatch.getUSDCSolvency();
        assertEq(liabilitiesAfter, 0, "Liabilities should be 0 after claim");
    }

    function test_SolvencyExceededReverts() public {
        // Deploy a fresh contract with no pre-funded USDC
        FootballMatch impl2 = new FootballMatch();
        bytes memory initData = abi.encodeWithSelector(
            FootballMatch.initialize.selector,
            "Test Match 2",
            owner
        );
        ERC1967Proxy proxy2 = new ERC1967Proxy(address(impl2), initData);
        FootballMatch match2 = FootballMatch(payable(address(proxy2)));

        vm.startPrank(owner);
        match2.setUSDCToken(address(usdc));
        match2.addMarket(MARKET_WINNER, 30000); // 3.00x
        match2.openMarket(0);
        vm.stopPrank();

        // Alice has 100 USDC, bet at 3x means 300 USDC liability
        // Contract only has the 100 USDC from Alice's deposit = insufficient
        vm.startPrank(alice);
        usdc.approve(address(match2), 100e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                BettingMatch.USDCSolvencyExceeded.selector,
                300e6,  // newLiability
                100e6   // available (alice's deposit)
            )
        );
        match2.placeBetUSDC(0, 0, 100e6);
        vm.stopPrank();
    }

    function test_FundTreasuryEnablesBetting() public {
        // Deploy fresh contract
        FootballMatch impl2 = new FootballMatch();
        bytes memory initData = abi.encodeWithSelector(
            FootballMatch.initialize.selector,
            "Test Match 3",
            owner
        );
        ERC1967Proxy proxy2 = new ERC1967Proxy(address(impl2), initData);
        FootballMatch match2 = FootballMatch(payable(address(proxy2)));

        vm.startPrank(owner);
        match2.setUSDCToken(address(usdc));
        match2.addMarket(MARKET_WINNER, 30000); // 3.00x
        match2.openMarket(0);
        vm.stopPrank();

        // Fund treasury with enough USDC first
        usdc.mint(owner, 500e6);
        vm.startPrank(owner);
        usdc.approve(address(match2), 500e6);
        match2.fundUSDCTreasury(500e6);
        vm.stopPrank();

        // Now Alice can bet: 100 USDC at 3x = 300 liability, 600 available (500+100)
        vm.startPrank(alice);
        usdc.approve(address(match2), 100e6);
        match2.placeBetUSDC(0, 0, 100e6);
        vm.stopPrank();

        BettingMatch.Bet[] memory bets = match2.getUserBets(0, alice);
        assertEq(bets.length, 1);
        assertEq(bets[0].amount, 100e6);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // MIXED CHZ + USDC TESTS
    // ══════════════════════════════════════════════════════════════════════════

    function test_MixedCHZAndUSDCBets() public {
        vm.prank(owner);
        footballMatch.addMarket(MARKET_WINNER, 20000); // 2.00x

        vm.prank(owner);
        footballMatch.openMarket(0);

        // Alice bets in CHZ
        vm.prank(alice);
        footballMatch.placeBet{value: 1 ether}(0, 0);

        // Bob bets in USDC
        vm.startPrank(bob);
        usdc.approve(address(footballMatch), 100e6);
        footballMatch.placeBetUSDC(0, 0, 100e6);
        vm.stopPrank();

        // Resolve
        vm.prank(resolver);
        footballMatch.resolveMarket(0, 0);

        // Alice claims CHZ
        uint256 aliceCHZBefore = alice.balance;
        vm.prank(alice);
        footballMatch.claim(0, 0);
        assertEq(alice.balance - aliceCHZBefore, 2 ether, "Alice gets CHZ payout");

        // Bob claims USDC
        uint256 bobUSDCBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        footballMatch.claim(0, 0);
        assertEq(usdc.balanceOf(bob) - bobUSDCBefore, 200e6, "Bob gets USDC payout");
    }

    function test_ClaimAllWithMixedBets() public {
        vm.prank(owner);
        footballMatch.addMarket(MARKET_WINNER, 20000); // 2.00x

        vm.prank(owner);
        footballMatch.openMarket(0);

        // Alice places both CHZ and USDC bets
        vm.prank(alice);
        footballMatch.placeBet{value: 1 ether}(0, 0); // CHZ

        vm.startPrank(alice);
        usdc.approve(address(footballMatch), 50e6);
        footballMatch.placeBetUSDC(0, 0, 50e6); // USDC
        vm.stopPrank();

        // Resolve
        vm.prank(resolver);
        footballMatch.resolveMarket(0, 0);

        // Claim all
        uint256 aliceCHZBefore = alice.balance;
        uint256 aliceUSDCBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        footballMatch.claimAll(0);

        assertEq(alice.balance - aliceCHZBefore, 2 ether, "CHZ payout via claimAll");
        assertEq(usdc.balanceOf(alice) - aliceUSDCBefore, 100e6, "USDC payout via claimAll");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // USDC NOT CONFIGURED TESTS
    // ══════════════════════════════════════════════════════════════════════════

    function test_RevertUSDCBetWhenNotConfigured() public {
        // Deploy fresh contract without USDC
        FootballMatch impl2 = new FootballMatch();
        bytes memory initData = abi.encodeWithSelector(
            FootballMatch.initialize.selector,
            "Test No USDC",
            owner
        );
        ERC1967Proxy proxy2 = new ERC1967Proxy(address(impl2), initData);
        FootballMatch match2 = FootballMatch(payable(address(proxy2)));

        vm.startPrank(owner);
        match2.addMarket(MARKET_WINNER, 20000);
        match2.openMarket(0);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(BettingMatch.USDCNotConfigured.selector);
        match2.placeBetUSDC(0, 0, 100e6);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // DOUBLE CLAIM PROTECTION (USDC)
    // ══════════════════════════════════════════════════════════════════════════

    function test_CannotDoubleClaimUSDC() public {
        vm.prank(owner);
        footballMatch.addMarket(MARKET_WINNER, 20000);
        vm.prank(owner);
        footballMatch.openMarket(0);

        vm.startPrank(alice);
        usdc.approve(address(footballMatch), 100e6);
        footballMatch.placeBetUSDC(0, 0, 100e6);
        vm.stopPrank();

        vm.prank(resolver);
        footballMatch.resolveMarket(0, 0);

        vm.prank(alice);
        footballMatch.claim(0, 0);

        vm.prank(alice);
        vm.expectRevert();
        footballMatch.claim(0, 0);
    }

    function test_LosingUSDCBetCannotClaim() public {
        vm.prank(owner);
        footballMatch.addMarket(MARKET_WINNER, 20000);
        vm.prank(owner);
        footballMatch.openMarket(0);

        vm.startPrank(alice);
        usdc.approve(address(footballMatch), 100e6);
        footballMatch.placeBetUSDC(0, 0, 100e6); // Bet on Home
        vm.stopPrank();

        vm.prank(resolver);
        footballMatch.resolveMarket(0, 1); // Away wins

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(BettingMatch.BetLost.selector, 0, alice, 0)
        );
        footballMatch.claim(0, 0);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ZERO VALUE PROTECTION
    // ══════════════════════════════════════════════════════════════════════════

    function test_RevertZeroValueSwap() public {
        vm.prank(alice);
        vm.expectRevert(BettingSwapRouter.ZeroValue.selector);
        swapRouter.placeBetWithCHZ{value: 0}(
            address(footballMatch),
            0, 0, 0,
            block.timestamp + 1 hours
        );
    }
}
