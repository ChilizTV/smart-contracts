// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test, console} from "forge-std/Test.sol";
import {BettingMatch} from "../src/betting/BettingMatch.sol";
import {FootballMatch} from "../src/betting/FootballMatch.sol";
import {BettingSwapRouter} from "../src/betting/BettingSwapRouter.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockKayenRouter} from "./mocks/MockKayenRouter.sol";

/// @dev Simple mock fan token for ERC20 swap tests
contract MockFanTokenSwap is ERC20 {
    constructor() ERC20("Fan Token", "FAN") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

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
    MockFanTokenSwap public fanToken;
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

        // Deploy mock Kayen router and fan token
        mockRouter = new MockKayenRouter(address(usdc));
        fanToken = new MockFanTokenSwap();

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

        // Mint USDC to users for direct USDC betting
        usdc.mint(alice, 1000e6);
        usdc.mint(bob, 1000e6);
        usdc.mint(charlie, 1000e6);

        // Mint fan tokens for ERC20 swap tests
        fanToken.mint(alice, 1000 ether);
        fanToken.mint(bob, 1000 ether);

        // Fund contract with USDC for payouts (treasury solvency)
        usdc.mint(address(footballMatch), 10000e6);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // USDC BETTING TESTS
    // ══════════════════════════════════════════════════════════════════════════

    function test_PlaceBetUSDC() public {
        vm.prank(owner);
        footballMatch.addMarketWithLine(MARKET_WINNER, 20000, 0); // 2.00x

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
        assertEq(bets[0].selection, 0);
    }

    function test_ClaimUSDC() public {
        vm.prank(owner);
        footballMatch.addMarketWithLine(MARKET_WINNER, 20000, 0); // 2.00x

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
        footballMatch.addMarketWithLine(MARKET_WINNER, 20000, 0);

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
        footballMatch.addMarketWithLine(MARKET_WINNER, 20000, 0); // 2.00x

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
        assertEq(bets[0].amount, 1e6, "Should be 1 USDC (10 CHZ * 0.10)");
    }

    function test_PlaceBetWithCHZSwapAndClaim() public {
        vm.prank(owner);
        footballMatch.addMarketWithLine(MARKET_WINNER, 20000, 0); // 2.00x

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
        footballMatch.addMarketWithLine(MARKET_WINNER, 20000, 0);
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
        footballMatch.addMarketWithLine(MARKET_WINNER, 20000, 0);
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
        footballMatch.addMarketWithLine(MARKET_WINNER, 20000, 0);
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
        footballMatch.addMarketWithLine(MARKET_WINNER, 20000, 0); // 2.00x

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
        footballMatch.addMarketWithLine(MARKET_WINNER, 20000, 0);
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
        match2.addMarketWithLine(MARKET_WINNER, 30000, 0); // 3.00x
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
        match2.addMarketWithLine(MARKET_WINNER, 30000, 0); // 3.00x
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
        match2.addMarketWithLine(MARKET_WINNER, 20000, 0);
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
        footballMatch.addMarketWithLine(MARKET_WINNER, 20000, 0);
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
        footballMatch.addMarketWithLine(MARKET_WINNER, 20000, 0);
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
    // DIRECT USDC VIA SWAP ROUTER (NO SWAP)
    // ══════════════════════════════════════════════════════════════════════════

    function test_PlaceBetWithUSDCViaRouter() public {
        vm.prank(owner);
        footballMatch.addMarketWithLine(MARKET_WINNER, 20000, 0); // 2.00x
        vm.prank(owner);
        footballMatch.openMarket(0);

        // Alice places bet via router's placeBetWithUSDC (no swap)
        vm.startPrank(alice);
        usdc.approve(address(swapRouter), 100e6);
        swapRouter.placeBetWithUSDC(
            address(footballMatch),
            0,      // marketId
            0,      // selection: Home
            100e6   // amount
        );
        vm.stopPrank();

        // Verify bet was placed for alice
        BettingMatch.Bet[] memory bets = footballMatch.getUserBets(0, alice);
        assertEq(bets.length, 1);
        assertEq(bets[0].amount, 100e6, "Should be 100 USDC (direct, no swap)");
    }

    function test_PlaceBetWithUSDCViaRouterAndClaim() public {
        vm.prank(owner);
        footballMatch.addMarketWithLine(MARKET_WINNER, 20000, 0); // 2.00x
        vm.prank(owner);
        footballMatch.openMarket(0);

        // Alice bets 100 USDC at 2.00x -> payout 200 USDC
        vm.startPrank(alice);
        usdc.approve(address(swapRouter), 100e6);
        swapRouter.placeBetWithUSDC(address(footballMatch), 0, 0, 100e6);
        vm.stopPrank();

        // Resolve
        vm.prank(resolver);
        footballMatch.resolveMarket(0, 0);

        // Claim
        uint256 aliceUSDCBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        footballMatch.claim(0, 0);
        assertEq(usdc.balanceOf(alice) - aliceUSDCBefore, 200e6, "Should claim 200 USDC payout");
    }

    function test_RevertPlaceBetWithUSDCZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(BettingSwapRouter.ZeroValue.selector);
        swapRouter.placeBetWithUSDC(address(footballMatch), 0, 0, 0);
    }

    function test_RevertPlaceBetWithUSDCZeroAddress() public {
        vm.startPrank(alice);
        usdc.approve(address(swapRouter), 100e6);
        vm.expectRevert(BettingSwapRouter.ZeroAddress.selector);
        swapRouter.placeBetWithUSDC(address(0), 0, 0, 100e6);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ERC20 TOKEN SWAP VIA ROUTER
    // ══════════════════════════════════════════════════════════════════════════

    function test_PlaceBetWithTokenSwap() public {
        vm.prank(owner);
        footballMatch.addMarketWithLine(MARKET_WINNER, 20000, 0); // 2.00x
        vm.prank(owner);
        footballMatch.openMarket(0);

        // Alice sends fan tokens, router swaps to USDC and places bet
        // 10 FAN * 0.10 USDC/token = 1 USDC (mock rate)
        vm.startPrank(alice);
        fanToken.approve(address(swapRouter), 10 ether);
        swapRouter.placeBetWithToken(
            address(fanToken),
            10 ether,
            address(footballMatch),
            0,      // marketId
            0,      // selection: Home
            0,      // amountOutMin
            block.timestamp + 1 hours
        );
        vm.stopPrank();

        // Verify bet was placed for alice
        BettingMatch.Bet[] memory bets = footballMatch.getUserBets(0, alice);
        assertEq(bets.length, 1);
        assertEq(bets[0].amount, 1e6, "Should be 1 USDC (10 tokens * 0.10)");
    }

    function test_PlaceBetWithTokenSwapAndClaim() public {
        vm.prank(owner);
        footballMatch.addMarketWithLine(MARKET_WINNER, 20000, 0); // 2.00x
        vm.prank(owner);
        footballMatch.openMarket(0);

        // Alice bets 10 FAN tokens -> 1 USDC at 2.00x -> payout 2 USDC
        vm.startPrank(alice);
        fanToken.approve(address(swapRouter), 10 ether);
        swapRouter.placeBetWithToken(
            address(fanToken), 10 ether,
            address(footballMatch), 0, 0, 0,
            block.timestamp + 1 hours
        );
        vm.stopPrank();

        // Resolve
        vm.prank(resolver);
        footballMatch.resolveMarket(0, 0);

        // Claim
        uint256 aliceUSDCBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        footballMatch.claim(0, 0);
        assertEq(usdc.balanceOf(alice) - aliceUSDCBefore, 2e6, "Should claim 2 USDC payout");
    }

    function test_RevertPlaceBetWithTokenIsUSDC() public {
        vm.startPrank(alice);
        usdc.approve(address(swapRouter), 100e6);
        vm.expectRevert(BettingSwapRouter.TokenIsUSDC.selector);
        swapRouter.placeBetWithToken(
            address(usdc), 100e6,
            address(footballMatch), 0, 0, 0,
            block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    function test_RevertPlaceBetWithTokenExpiredDeadline() public {
        vm.startPrank(alice);
        fanToken.approve(address(swapRouter), 10 ether);
        vm.expectRevert(BettingSwapRouter.DeadlinePassed.selector);
        swapRouter.placeBetWithToken(
            address(fanToken), 10 ether,
            address(footballMatch), 0, 0, 0,
            block.timestamp - 1
        );
        vm.stopPrank();
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
