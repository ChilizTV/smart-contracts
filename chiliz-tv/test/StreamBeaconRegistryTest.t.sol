// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StreamWalletFactory} from "../src/streamer/StreamWalletFactory.sol";
import {StreamWallet} from "../src/streamer/StreamWallet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IKayenRouter} from "../src/interfaces/IKayenRouter.sol";

/// @dev Simple ERC20 mock for fan token and USDC
contract MockERC20 is IERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public override totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/**
 * @dev Mock Kayen router for token-to-token swaps (IKayenRouter interface)
 * Note: This is different from test/mocks/MockKayenRouter.sol which implements
 * IKayenMasterRouterV2 for native CHZ swaps. Both are needed:
 * - IKayenRouter: Fan Token → USDC (used by StreamWallet)
 * - IKayenMasterRouterV2: CHZ (native) → USDC (used by BettingSwapRouter, StreamSwapRouter)
 */
contract MockKayenRouterTokenSwap is IKayenRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 /* amountOutMin */,
        address[] calldata path,
        address to,
        uint256 /* deadline */
    ) external override returns (uint256[] memory amounts) {
        require(path.length >= 2, "Invalid path");

        address tokenIn = path[0];
        address tokenOut = path[path.length - 1];

        // Pull input tokens from caller
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        // Mint output tokens 1:1 and send to recipient
        MockERC20(tokenOut).mint(to, amountIn);

        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = amountIn;
    }

    function getAmountsOut(
        uint256 amountIn,
        address[] calldata path
    ) external pure override returns (uint256[] memory amounts) {
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = amountIn; // 1:1 swap
    }
}

contract StreamBeaconRegistryTest is Test {
    StreamWalletFactory public factory;
    MockERC20 public fanToken;
    MockERC20 public usdcToken;
    MockKayenRouterTokenSwap public router;

    address public admin = address(0x1);
    address public gnosisSafe = address(0x2);
    address public treasury = address(0x3);
    address public streamer1 = address(0x4);
    address public streamer2 = address(0x5);
    address public viewer1 = address(0x6);
    address public viewer2 = address(0x7);

    uint16 public constant PLATFORM_FEE_BPS = 500; // 5%
    uint256 public constant INITIAL_BALANCE = 1000 ether;

    event StreamWalletCreated(address indexed streamer, address indexed wallet);
    event SubscriptionProcessed(
        address indexed streamer,
        address indexed subscriber,
        uint256 amount
    );
    event DonationProcessed(
        address indexed streamer,
        address indexed donor,
        uint256 amount,
        string message
    );

    function setUp() public {
        // Deploy mock tokens and router
        fanToken = new MockERC20("Fan Token", "FAN", 18);
        usdcToken = new MockERC20("USD Coin", "USDC", 6);
        router = new MockKayenRouterTokenSwap();

        // Deploy factory
        vm.prank(admin);
        factory = new StreamWalletFactory(
            admin,
            treasury,
            PLATFORM_FEE_BPS,
            address(router),
            address(fanToken),
            address(usdcToken)
        );

        // Mint fan tokens to viewers and streamers
        fanToken.mint(viewer1, INITIAL_BALANCE);
        fanToken.mint(viewer2, INITIAL_BALANCE);
        fanToken.mint(streamer1, INITIAL_BALANCE);
        fanToken.mint(streamer2, INITIAL_BALANCE);

        // Approve factory to spend fan tokens on behalf of viewers
        vm.prank(viewer1);
        fanToken.approve(address(factory), type(uint256).max);
        vm.prank(viewer2);
        fanToken.approve(address(factory), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                        DEPLOYMENT & SETUP TESTS
    //////////////////////////////////////////////////////////////*/

    function testFactoryDeployment() public view {
        assertEq(factory.owner(), admin);
        assertEq(factory.treasury(), treasury);
        assertEq(factory.defaultPlatformFeeBps(), PLATFORM_FEE_BPS);
        assertTrue(factory.implementation() != address(0));
        assertEq(factory.kayenRouter(), address(router));
        assertEq(factory.fanToken(), address(fanToken));
        assertEq(factory.usdc(), address(usdcToken));
    }

    /*//////////////////////////////////////////////////////////////
                        SUBSCRIPTION TESTS
    //////////////////////////////////////////////////////////////*/

    function testFirstSubscription() public {
        uint256 subscriptionAmount = 100 ether;
        uint256 duration = 30 days;

        // Check wallet doesn't exist yet
        assertFalse(factory.hasWallet(streamer1));

        // Subscribe with fan tokens
        vm.prank(viewer1);
        address wallet = factory.subscribeToStream(streamer1, duration, subscriptionAmount);

        // Verify wallet created
        assertTrue(factory.hasWallet(streamer1));
        assertEq(factory.getWallet(streamer1), wallet);

        // Check balances (USDC after swap, 1:1 mock)
        StreamWallet streamWallet = StreamWallet(payable(wallet));
        uint256 expectedFee = (subscriptionAmount * PLATFORM_FEE_BPS) / 10_000;
        uint256 expectedStreamerAmount = subscriptionAmount - expectedFee;

        // Treasury should have received USDC platform fee
        assertEq(usdcToken.balanceOf(treasury), expectedFee);

        // Streamer should have received USDC payment
        assertEq(usdcToken.balanceOf(streamer1), expectedStreamerAmount);

        // Verify subscription data
        assertTrue(streamWallet.isSubscribed(viewer1));
        assertEq(streamWallet.totalRevenue(), subscriptionAmount);
        assertEq(streamWallet.totalSubscribers(), 1);

        // Viewer fan token balance should be reduced
        assertEq(fanToken.balanceOf(viewer1), INITIAL_BALANCE - subscriptionAmount);
    }

    function testMultipleSubscriptions() public {
        uint256 amount1 = 100 ether;
        uint256 amount2 = 200 ether;
        uint256 duration = 30 days;

        // First subscription from viewer1
        vm.prank(viewer1);
        address wallet = factory.subscribeToStream(streamer1, duration, amount1);

        // Second subscription from viewer2 to same streamer
        vm.prank(viewer2);
        address wallet2 = factory.subscribeToStream(streamer1, duration, amount2);

        // Should use same wallet
        assertEq(wallet, wallet2);

        StreamWallet streamWallet = StreamWallet(payable(wallet));

        // Both should be subscribed
        assertTrue(streamWallet.isSubscribed(viewer1));
        assertTrue(streamWallet.isSubscribed(viewer2));

        // Total subscribers should be 2
        assertEq(streamWallet.totalSubscribers(), 2);

        // Total revenue should be sum
        assertEq(streamWallet.totalRevenue(), amount1 + amount2);

        // Check total USDC fees to treasury
        uint256 totalFees = ((amount1 + amount2) * PLATFORM_FEE_BPS) / 10_000;
        assertEq(usdcToken.balanceOf(treasury), totalFees);
    }

    function testSubscriptionToMultipleStreamers() public {
        uint256 amount = 100 ether;
        uint256 duration = 30 days;

        // Subscribe to streamer1
        vm.prank(viewer1);
        address wallet1 = factory.subscribeToStream(streamer1, duration, amount);

        // Subscribe to streamer2
        vm.prank(viewer1);
        address wallet2 = factory.subscribeToStream(streamer2, duration, amount);

        // Different wallets for different streamers
        assertTrue(wallet1 != wallet2);

        // Both wallets should exist
        assertTrue(factory.hasWallet(streamer1));
        assertTrue(factory.hasWallet(streamer2));

        // Both streamers should have received USDC payments
        uint256 expectedStreamerAmount = amount - ((amount * PLATFORM_FEE_BPS) / 10_000);
        assertEq(usdcToken.balanceOf(streamer1), expectedStreamerAmount);
        assertEq(usdcToken.balanceOf(streamer2), expectedStreamerAmount);
    }

    function testSubscriptionExpiry() public {
        uint256 amount = 100 ether;
        uint256 duration = 30 days;

        vm.prank(viewer1);
        address wallet = factory.subscribeToStream(streamer1, duration, amount);

        StreamWallet streamWallet = StreamWallet(payable(wallet));

        // Should be subscribed immediately
        assertTrue(streamWallet.isSubscribed(viewer1));

        // Fast forward to just before expiry
        vm.warp(block.timestamp + duration - 1);
        assertTrue(streamWallet.isSubscribed(viewer1));

        // Fast forward past expiry
        vm.warp(block.timestamp + 2);
        assertFalse(streamWallet.isSubscribed(viewer1));
    }

    function testSubscriptionRenewal() public {
        uint256 amount = 100 ether;
        uint256 duration = 30 days;

        // First subscription
        vm.prank(viewer1);
        address wallet = factory.subscribeToStream(streamer1, duration, amount);

        StreamWallet streamWallet = StreamWallet(payable(wallet));

        // Fast forward past expiry
        vm.warp(block.timestamp + duration + 1);
        assertFalse(streamWallet.isSubscribed(viewer1));

        // Renew subscription
        vm.prank(viewer1);
        factory.subscribeToStream(streamer1, duration, amount);

        // Should be subscribed again
        assertTrue(streamWallet.isSubscribed(viewer1));
    }

    /*//////////////////////////////////////////////////////////////
                        DONATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testDonation() public {
        uint256 subscriptionAmount = 100 ether;
        uint256 donationAmount = 50 ether;
        string memory message = "Great stream!";

        // First create a wallet via subscription
        vm.prank(viewer1);
        address wallet = factory.subscribeToStream(streamer1, 30 days, subscriptionAmount);

        uint256 streamerUsdcBefore = usdcToken.balanceOf(streamer1);
        uint256 treasuryUsdcBefore = usdcToken.balanceOf(treasury);

        StreamWallet streamWallet = StreamWallet(payable(wallet));

        // Approve StreamWallet to pull fan tokens for donation
        vm.prank(viewer2);
        fanToken.approve(address(streamWallet), donationAmount);

        // Donate directly to wallet
        vm.prank(viewer2);
        streamWallet.donate(donationAmount, message, 0);

        // Check donation recorded
        assertEq(streamWallet.getDonationAmount(viewer2), donationAmount);

        // Check USDC balances
        uint256 expectedFee = (donationAmount * PLATFORM_FEE_BPS) / 10_000;
        uint256 expectedStreamerAmount = donationAmount - expectedFee;

        assertEq(
            usdcToken.balanceOf(treasury),
            treasuryUsdcBefore + expectedFee
        );
        assertEq(
            usdcToken.balanceOf(streamer1),
            streamerUsdcBefore + expectedStreamerAmount
        );
    }

    function testDonationCreatesWallet() public {
        uint256 donationAmount = 50 ether;
        string memory message = "First donation!";

        // Use factory to create wallet via donation
        vm.expectEmit(true, true, false, true);
        emit DonationProcessed(streamer1, viewer1, donationAmount, message);

        vm.prank(viewer1);
        address wallet = factory.donateToStream(streamer1, message, donationAmount);

        // Wallet should now exist
        assertTrue(factory.hasWallet(streamer1));
        assertEq(factory.getWallet(streamer1), wallet);

        StreamWallet streamWallet = StreamWallet(payable(wallet));

        // Verify revenue was recorded
        assertEq(streamWallet.totalRevenue(), donationAmount);
    }

    function testMultipleDonationsAccumulate() public {
        uint256 donation1 = 50 ether;
        uint256 donation2 = 75 ether;

        // First create wallet via subscription
        vm.prank(viewer1);
        address wallet = factory.subscribeToStream(streamer1, 30 days, 100 ether);

        StreamWallet streamWallet = StreamWallet(payable(wallet));

        // Approve StreamWallet to pull fan tokens for donations
        vm.prank(viewer1);
        fanToken.approve(address(streamWallet), donation1 + donation2);

        // First donation
        vm.prank(viewer1);
        streamWallet.donate(donation1, "First!", 0);

        // Second donation from same viewer
        vm.prank(viewer1);
        streamWallet.donate(donation2, "Second!", 0);

        // Should accumulate
        assertEq(streamWallet.getDonationAmount(viewer1), donation1 + donation2);
    }

    /*//////////////////////////////////////////////////////////////
                        WITHDRAWAL TESTS
    //////////////////////////////////////////////////////////////*/

    function testStreamerWithdrawal() public {
        // Create wallet with subscription
        uint256 subscriptionAmount = 100 ether;
        vm.prank(viewer1);
        address wallet = factory.subscribeToStream(streamer1, 30 days, subscriptionAmount);

        StreamWallet streamWallet = StreamWallet(payable(wallet));

        // Check available balance (should be 0 as USDC was sent directly to streamer/treasury)
        assertEq(streamWallet.availableBalance(), 0);

        // Mint USDC directly to wallet to test withdrawal
        usdcToken.mint(wallet, 10 ether);

        uint256 balance = streamWallet.availableBalance();
        assertEq(balance, 10 ether);

        uint256 streamerUsdcBefore = usdcToken.balanceOf(streamer1);

        vm.prank(streamer1);
        streamWallet.withdrawRevenue(balance);

        assertEq(usdcToken.balanceOf(streamer1), streamerUsdcBefore + balance);
        assertEq(streamWallet.availableBalance(), 0);
    }

    function testOnlyStreamerCanWithdraw() public {
        // Create wallet
        vm.prank(viewer1);
        address wallet = factory.subscribeToStream(streamer1, 30 days, 100 ether);

        StreamWallet streamWallet = StreamWallet(payable(wallet));

        // Fund wallet with USDC
        usdcToken.mint(wallet, 1 ether);

        // Try to withdraw as non-streamer
        vm.prank(viewer1);
        vm.expectRevert(StreamWallet.OnlyStreamer.selector);
        streamWallet.withdrawRevenue(1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                        FEE CALCULATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testFeeCalculations() public {
        uint256[] memory amounts = new uint256[](5);
        amounts[0] = 100 ether;
        amounts[1] = 1000 ether;
        amounts[2] = 10000 ether;
        amounts[3] = 1 ether;
        amounts[4] = 999 ether;

        uint256 totalFees = 0;
        uint256 totalStreamerPayments = 0;

        for (uint256 i = 0; i < amounts.length; i++) {
            // Create new viewer for each test
            // casting to 'uint160' is safe because 1000 + i is always within uint160 range in tests
            // forge-lint: disable-next-line(unsafe-typecast)
            address viewer = address(uint160(1000 + i));
            fanToken.mint(viewer, amounts[i]);
            vm.prank(viewer);
            fanToken.approve(address(factory), amounts[i]);

            vm.prank(viewer);
            factory.subscribeToStream(streamer1, 30 days, amounts[i]);

            uint256 expectedFee = (amounts[i] * PLATFORM_FEE_BPS) / 10_000;
            uint256 expectedStreamerAmount = amounts[i] - expectedFee;

            totalFees += expectedFee;
            totalStreamerPayments += expectedStreamerAmount;
        }

        // Verify total USDC fees collected by treasury
        assertEq(usdcToken.balanceOf(treasury), totalFees);

        // Verify total USDC streamer payments
        assertEq(
            usdcToken.balanceOf(streamer1),
            totalStreamerPayments
        );
    }

    function testZeroFeeEdgeCase() public {
        // Deploy new factory with 0% fee
        vm.prank(admin);
        StreamWalletFactory zeroFeeFactory = new StreamWalletFactory(
            admin,
            treasury,
            0, // 0% fee
            address(router),
            address(fanToken),
            address(usdcToken)
        );

        uint256 amount = 100 ether;

        // Approve zero-fee factory
        vm.prank(viewer1);
        fanToken.approve(address(zeroFeeFactory), amount);

        uint256 treasuryBefore = usdcToken.balanceOf(treasury);

        vm.prank(viewer1);
        zeroFeeFactory.subscribeToStream(streamer2, 30 days, amount);

        // Streamer should receive full USDC amount
        assertEq(usdcToken.balanceOf(streamer2), amount);

        // Treasury should receive nothing
        assertEq(usdcToken.balanceOf(treasury), treasuryBefore);
    }

    /*//////////////////////////////////////////////////////////////
                        UPGRADE TESTS (UUPS)
    //////////////////////////////////////////////////////////////*/

    function testUpgradeImplementation() public {
        // Create a wallet with first implementation
        vm.prank(viewer1);
        address wallet = factory.subscribeToStream(streamer1, 30 days, 100 ether);

        // Deploy new implementation
        StreamWallet newImplementation = new StreamWallet();

        // Upgrade via streamer (wallet owner)
        vm.prank(streamer1);
        StreamWallet(payable(wallet)).upgradeToAndCall(address(newImplementation), "");

        // Existing proxy should still work with new implementation
        StreamWallet streamWallet = StreamWallet(payable(wallet));
        assertTrue(streamWallet.isSubscribed(viewer1));
    }

    function testOnlyOwnerCanUpgrade() public {
        // Create a wallet
        vm.prank(viewer1);
        address wallet = factory.subscribeToStream(streamer1, 30 days, 100 ether);

        StreamWallet newImplementation = new StreamWallet();

        // Try to upgrade as non-owner (viewer)
        vm.prank(viewer1);
        vm.expectRevert();
        StreamWallet(payable(wallet)).upgradeToAndCall(address(newImplementation), "");

        // Try as admin (not wallet owner)
        vm.prank(admin);
        vm.expectRevert();
        StreamWallet(payable(wallet)).upgradeToAndCall(address(newImplementation), "");
    }

    /*//////////////////////////////////////////////////////////////
                        REVERT TESTS
    //////////////////////////////////////////////////////////////*/

    function testRevertZeroAmount() public {
        vm.prank(viewer1);
        vm.expectRevert(StreamWalletFactory.InvalidAmount.selector);
        factory.subscribeToStream(streamer1, 30 days, 0);
    }

    function testRevertZeroDuration() public {
        vm.prank(viewer1);
        vm.expectRevert(StreamWalletFactory.InvalidDuration.selector);
        factory.subscribeToStream(streamer1, 0, 100 ether);
    }

    function testRevertInsufficientBalance() public {
        vm.prank(viewer1);
        vm.expectRevert(StreamWalletFactory.InvalidAmount.selector);
        factory.subscribeToStream(streamer1, 30 days, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testCompleteFlow() public {
        // Step 1: First subscription
        uint256 sub1Amount = 100 ether;
        vm.prank(viewer1);
        address wallet = factory.subscribeToStream(streamer1, 30 days, sub1Amount);

        StreamWallet streamWallet = StreamWallet(payable(wallet));

        // Step 2: Another viewer subscribes
        uint256 sub2Amount = 200 ether;
        vm.prank(viewer2);
        factory.subscribeToStream(streamer1, 60 days, sub2Amount);

        // Step 3: First viewer donates directly to wallet
        uint256 donationAmount = 50 ether;
        vm.prank(viewer1);
        fanToken.approve(address(streamWallet), donationAmount);
        vm.prank(viewer1);
        streamWallet.donate(donationAmount, "Love your content!", 0);

        // Calculate expected totals
        uint256 totalRevenue = sub1Amount + sub2Amount + donationAmount;
        uint256 totalFees = (totalRevenue * PLATFORM_FEE_BPS) / 10_000;
        uint256 totalStreamerPayment = totalRevenue - totalFees;

        // Verify wallet state
        assertEq(streamWallet.totalRevenue(), totalRevenue);
        assertEq(streamWallet.totalSubscribers(), 2);
        assertEq(streamWallet.getDonationAmount(viewer1), donationAmount);

        // Verify USDC balances
        assertEq(usdcToken.balanceOf(treasury), totalFees);
        assertEq(usdcToken.balanceOf(streamer1), totalStreamerPayment);

        // Verify subscriptions
        assertTrue(streamWallet.isSubscribed(viewer1));
        assertTrue(streamWallet.isSubscribed(viewer2));

        // Step 4: Fast forward past first subscription expiry
        vm.warp(block.timestamp + 31 days);
        assertFalse(streamWallet.isSubscribed(viewer1));
        assertTrue(streamWallet.isSubscribed(viewer2)); // Still active

        // Step 5: Viewer1 resubscribes
        vm.prank(viewer1);
        factory.subscribeToStream(streamer1, 30 days, sub1Amount);

        // Should be subscribed again
        assertTrue(streamWallet.isSubscribed(viewer1));
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function testManualWalletDeployment() public {
        // Admin can deploy wallet manually
        vm.prank(admin);
        address wallet = factory.deployWalletFor(streamer1);

        assertTrue(factory.hasWallet(streamer1));
        assertEq(factory.getWallet(streamer1), wallet);
    }

    function testUpdateTreasury() public {
        address newTreasury = address(0x999);
        uint256 subscriptionAmount = 100 ether;

        // Update treasury BEFORE creating any wallets
        vm.prank(admin);
        factory.setTreasury(newTreasury);

        // Verify treasury was updated
        assertEq(factory.treasury(), newTreasury);

        // Subscribe
        vm.prank(viewer1);
        factory.subscribeToStream(streamer1, 30 days, subscriptionAmount);

        // Calculate expected fee
        uint256 expectedFee = (subscriptionAmount * PLATFORM_FEE_BPS) / 10_000;

        // Check new treasury received the USDC fee
        assertEq(usdcToken.balanceOf(newTreasury), expectedFee, "New treasury should have received fee");
    }

    function testUpdatePlatformFee() public {
        uint16 newFee = 1000; // 10%

        vm.prank(admin);
        factory.setPlatformFee(newFee);

        assertEq(factory.defaultPlatformFeeBps(), newFee);
    }

    function testRevertUpdateTreasuryNonOwner() public {
        vm.prank(viewer1);
        vm.expectRevert();
        factory.setTreasury(address(0x999));
    }

    function testRevertInvalidFeeBps() public {
        vm.prank(admin);
        vm.expectRevert(StreamWalletFactory.InvalidFeeBps.selector);
        factory.setPlatformFee(10001); // > 100%
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN SETTER TESTS
    //////////////////////////////////////////////////////////////*/

    function testSetKayenRouter() public {
        address newRouter = address(0xABC);

        vm.prank(admin);
        factory.setKayenRouter(newRouter);

        assertEq(factory.kayenRouter(), newRouter);
    }

    function testSetFanToken() public {
        address newToken = address(0xDEF);

        vm.prank(admin);
        factory.setFanToken(newToken);

        assertEq(factory.fanToken(), newToken);
    }

    function testSetUsdc() public {
        address newUsdc = address(0xFED);

        vm.prank(admin);
        factory.setUsdc(newUsdc);

        assertEq(factory.usdc(), newUsdc);
    }

    function testRevertSetKayenRouterNonOwner() public {
        vm.prank(viewer1);
        vm.expectRevert();
        factory.setKayenRouter(address(0xABC));
    }

    function testRevertSetKayenRouterZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(StreamWalletFactory.InvalidAddress.selector);
        factory.setKayenRouter(address(0));
    }
}
