// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test, console} from "forge-std/Test.sol";
import {BettingMatch} from "../src/betting/BettingMatch.sol";
import {FootballMatch} from "../src/betting/FootballMatch.sol";
import {BettingMatchFactory} from "../src/betting/BettingMatchFactory.sol";
import {ChilizSwapRouter} from "../src/swap/ChilizSwapRouter.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockKayenRouter} from "./mocks/MockKayenRouter.sol";
import {LiquidityPool} from "../src/liquidity/LiquidityPool.sol";

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
 * 2. CHZâ†’USDC swap via ChilizSwapRouter
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
    ChilizSwapRouter public swapRouter;
    LiquidityPool public pool;
    BettingMatchFactory public factory;

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

        // Deploy LiquidityPool first so the factory can wire matches to it.
        LiquidityPool poolImpl = new LiquidityPool();
        bytes memory poolInitData = abi.encodeWithSelector(
            LiquidityPool.initialize.selector,
            address(usdc), owner, owner,
            uint16(0), uint16(5000), uint16(9000), uint48(0)
        );
        ERC1967Proxy poolProxy = new ERC1967Proxy(address(poolImpl), poolInitData);
        pool = LiquidityPool(address(poolProxy));

        // Deploy swap router (unified: betting + streaming)
        swapRouter = new ChilizSwapRouter(
            address(mockRouter),
            address(mockRouter),
            address(usdc),
            WCHZ,
            address(0x999),  // treasury
            500              // 5% platform fee
        );

        // Deploy factory and grant it MATCH_AUTHORIZER_ROLE on the pool so it can
        // atomically register new matches on `createFootballMatch`.
        factory = new BettingMatchFactory();
        bytes32 authRole = pool.MATCH_AUTHORIZER_ROLE();
        vm.prank(owner);
        pool.grantRole(authRole, address(factory));

        // Wire the factory: new matches get USDC + pool + swapRouter set, and
        // SWAP_ROUTER_ROLE granted to the swap router, all in one tx.
        factory.setWiring(address(pool), address(usdc), address(swapRouter));

        // Register the factory on the swap router so `placeBetWith*` validates
        // every `bettingMatch` argument against the factory's registry.
        swapRouter.setMatchFactory(address(factory));

        // Create the match through the factory (atomic wiring). `resolver` gets
        // RESOLVER_ROLE; `owner` becomes match admin. Implementation is read
        // back from the factory for the ERC1967-slot assertion (if any).
        address matchAddr = factory.createFootballMatch(
            "Barcelona vs Real Madrid",
            owner,
            resolver
        );
        footballMatch = FootballMatch(payable(matchAddr));
        implementation = FootballMatch(payable(factory.footballImplementation()));

        // Additional role grant: legacy oddsSetter wiring.
        vm.prank(owner);
        footballMatch.grantRole(ODDS_SETTER_ROLE, oddsSetter);

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

        // Fund LiquidityPool with USDC for payouts
        usdc.mint(address(pool), 10000e6);
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // USDC BETTING TESTS
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

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
        vm.prank(owner);
        footballMatch.closeMarket(0);
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

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // SWAP ROUTER TESTS
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

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
        vm.prank(owner);
        footballMatch.closeMarket(0);
        vm.prank(resolver);
        footballMatch.resolveMarket(0, 0);

        // Claim
        uint256 aliceUSDCBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        footballMatch.claim(0, 0);
        uint256 aliceUSDCAfter = usdc.balanceOf(alice);

        assertEq(aliceUSDCAfter - aliceUSDCBefore, 2e6, "Should claim 2 USDC payout");
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // SLIPPAGE AND DEADLINE TESTS
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

    function test_RevertOnExpiredDeadline() public {
        vm.prank(owner);
        footballMatch.addMarketWithLine(MARKET_WINNER, 20000, 0);
        vm.prank(owner);
        footballMatch.openMarket(0);

        // Set deadline in the past
        vm.prank(alice);
        vm.expectRevert(ChilizSwapRouter.DeadlinePassed.selector);
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

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // USDC NOT CONFIGURED TESTS
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

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
        vm.expectRevert(BettingMatch.LiquidityPoolNotConfigured.selector);
        match2.placeBetUSDC(0, 0, 100e6);
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // DOUBLE CLAIM PROTECTION (USDC)
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

    function test_CannotDoubleClaimUSDC() public {
        vm.prank(owner);
        footballMatch.addMarketWithLine(MARKET_WINNER, 20000, 0);
        vm.prank(owner);
        footballMatch.openMarket(0);

        vm.startPrank(alice);
        usdc.approve(address(footballMatch), 100e6);
        footballMatch.placeBetUSDC(0, 0, 100e6);
        vm.stopPrank();

        vm.prank(owner);
        footballMatch.closeMarket(0);
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

        vm.prank(owner);
        footballMatch.closeMarket(0);
        vm.prank(resolver);
        footballMatch.resolveMarket(0, 1); // Away wins

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(BettingMatch.BetLost.selector, 0, alice, 0)
        );
        footballMatch.claim(0, 0);
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // DIRECT USDC VIA SWAP ROUTER (NO SWAP)
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

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
        vm.prank(owner);
        footballMatch.closeMarket(0);
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
        vm.expectRevert(ChilizSwapRouter.ZeroValue.selector);
        swapRouter.placeBetWithUSDC(address(footballMatch), 0, 0, 0);
    }

    function test_RevertPlaceBetWithUSDCZeroAddress() public {
        vm.startPrank(alice);
        usdc.approve(address(swapRouter), 100e6);
        vm.expectRevert(ChilizSwapRouter.ZeroAddress.selector);
        swapRouter.placeBetWithUSDC(address(0), 0, 0, 100e6);
        vm.stopPrank();
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // ERC20 TOKEN SWAP VIA ROUTER
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

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
        vm.prank(owner);
        footballMatch.closeMarket(0);
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
        vm.expectRevert(ChilizSwapRouter.TokenIsUSDC.selector);
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
        vm.expectRevert(ChilizSwapRouter.DeadlinePassed.selector);
        swapRouter.placeBetWithToken(
            address(fanToken), 10 ether,
            address(footballMatch), 0, 0, 0,
            block.timestamp - 1
        );
        vm.stopPrank();
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // ZERO VALUE PROTECTION
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

    function test_RevertZeroValueSwap() public {
        vm.prank(alice);
        vm.expectRevert(ChilizSwapRouter.ZeroValue.selector);
        swapRouter.placeBetWithCHZ{value: 0}(
            address(footballMatch),
            0, 0, 0,
            block.timestamp + 1 hours
        );
    }
}
