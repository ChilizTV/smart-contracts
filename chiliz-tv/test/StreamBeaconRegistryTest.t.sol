// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {StreamBeaconRegistry} from "../src/streamer/StreamBeaconRegistry.sol";
import {StreamWalletFactory} from "../src/streamer/StreamWalletFactory.sol";
import {StreamWallet} from "../src/streamer/StreamWallet.sol";
import {MockERC20} from "../src/MockERC20.sol";

contract StreamBeaconRegistryTest is Test {
    StreamBeaconRegistry public registry;
    StreamWalletFactory public factory;
    StreamWallet public implementation;
    MockERC20 public token;

    address public admin = address(0x1);
    address public gnosisSafe = address(0x2);
    address public treasury = address(0xA);
    address public streamer1 = address(0x4);
    address public streamer2 = address(0x5);
    address public viewer1 = address(0x6);
    address public viewer2 = address(0x7);

    uint16 public constant PLATFORM_FEE_BPS = 500; // 5%
    uint256 public constant INITIAL_BALANCE = 1000e18;

    event BeaconCreated(address indexed beacon, address indexed implementation);
    event BeaconUpgraded(address indexed newImplementation);
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
        // Deploy token
        token = new MockERC20();

        // Deploy registry with Safe as owner
        vm.prank(gnosisSafe);
        registry = new StreamBeaconRegistry(gnosisSafe);

        // Deploy implementation
        implementation = new StreamWallet();

        // Set implementation via Safe
        vm.prank(gnosisSafe);
        registry.setImplementation(address(implementation));

        // Deploy factory with admin as owner
        vm.prank(admin);
        factory = new StreamWalletFactory(
            admin,
            address(registry),
            address(token),
            treasury,
            PLATFORM_FEE_BPS
        );

        // Fund viewers and streamers
        token.mint(viewer1, INITIAL_BALANCE);
        token.mint(viewer2, INITIAL_BALANCE);
        token.mint(streamer1, INITIAL_BALANCE);
        token.mint(streamer2, INITIAL_BALANCE);
    }

    /*//////////////////////////////////////////////////////////////
                        DEPLOYMENT & SETUP TESTS
    //////////////////////////////////////////////////////////////*/

    function testRegistryDeployment() public view {
        assertEq(registry.owner(), gnosisSafe);
        assertTrue(registry.isInitialized());
        assertEq(registry.getImplementation(), address(implementation));
    }

    function testFactoryDeployment() public view {
        assertEq(factory.owner(), admin);
        assertEq(address(factory.registry()), address(registry));
        assertEq(address(factory.token()), address(token));
        assertEq(factory.treasury(), treasury);
        assertEq(factory.defaultPlatformFeeBps(), PLATFORM_FEE_BPS);
    }

    /*//////////////////////////////////////////////////////////////
                        SUBSCRIPTION TESTS
    //////////////////////////////////////////////////////////////*/

    function testFirstSubscription() public {
        uint256 subscriptionAmount = 100e18;
        uint256 duration = 30 days;

        // Approve factory
        vm.prank(viewer1);
        token.approve(address(factory), subscriptionAmount);

        // Check wallet doesn't exist yet
        assertFalse(factory.hasWallet(streamer1));

        // Subscribe (we'll check events after to get the actual wallet address)
        vm.prank(viewer1);
        address wallet = factory.subscribeToStream(streamer1, subscriptionAmount, duration);

        // Verify wallet created
        assertTrue(factory.hasWallet(streamer1));
        assertEq(factory.getWallet(streamer1), wallet);

        // Check balances
        StreamWallet streamWallet = StreamWallet(wallet);
        uint256 expectedFee = (subscriptionAmount * PLATFORM_FEE_BPS) / 10_000;
        uint256 expectedStreamerAmount = subscriptionAmount - expectedFee;

        // Treasury should have received platform fee
        assertEq(token.balanceOf(treasury), expectedFee);
        
        // Streamer should have received payment
        assertEq(token.balanceOf(streamer1), INITIAL_BALANCE + expectedStreamerAmount);

        // Verify subscription data
        assertTrue(streamWallet.isSubscribed(viewer1));
        assertEq(streamWallet.totalRevenue(), subscriptionAmount);
        assertEq(streamWallet.totalSubscribers(), 1);

        // Viewer balance should be reduced
        assertEq(token.balanceOf(viewer1), INITIAL_BALANCE - subscriptionAmount);
    }

    function testMultipleSubscriptions() public {
        uint256 amount1 = 100e18;
        uint256 amount2 = 200e18;
        uint256 duration = 30 days;

        // First subscription from viewer1
        vm.prank(viewer1);
        token.approve(address(factory), amount1);
        vm.prank(viewer1);
        address wallet = factory.subscribeToStream(streamer1, amount1, duration);

        // Second subscription from viewer2 to same streamer
        vm.prank(viewer2);
        token.approve(address(factory), amount2);
        vm.prank(viewer2);
        address wallet2 = factory.subscribeToStream(streamer1, amount2, duration);

        // Should use same wallet
        assertEq(wallet, wallet2);

        StreamWallet streamWallet = StreamWallet(wallet);

        // Both should be subscribed
        assertTrue(streamWallet.isSubscribed(viewer1));
        assertTrue(streamWallet.isSubscribed(viewer2));

        // Total subscribers should be 2
        assertEq(streamWallet.totalSubscribers(), 2);

        // Total revenue should be sum
        assertEq(streamWallet.totalRevenue(), amount1 + amount2);

        // Check total fees
        uint256 totalFees = ((amount1 + amount2) * PLATFORM_FEE_BPS) / 10_000;
        assertEq(token.balanceOf(treasury), totalFees);
    }

    function testSubscriptionToMultipleStreamers() public {
        uint256 amount = 100e18;
        uint256 duration = 30 days;

        // Subscribe to streamer1
        vm.prank(viewer1);
        token.approve(address(factory), amount);
        vm.prank(viewer1);
        address wallet1 = factory.subscribeToStream(streamer1, amount, duration);

        // Subscribe to streamer2
        vm.prank(viewer1);
        token.approve(address(factory), amount);
        vm.prank(viewer1);
        address wallet2 = factory.subscribeToStream(streamer2, amount, duration);

        // Different wallets for different streamers
        assertTrue(wallet1 != wallet2);

        // Both wallets should exist
        assertTrue(factory.hasWallet(streamer1));
        assertTrue(factory.hasWallet(streamer2));

        // Both streamers should have received payments
        uint256 expectedStreamerAmount = amount - ((amount * PLATFORM_FEE_BPS) / 10_000);
        assertEq(token.balanceOf(streamer1), INITIAL_BALANCE + expectedStreamerAmount);
        assertEq(token.balanceOf(streamer2), INITIAL_BALANCE + expectedStreamerAmount);
    }

    function testSubscriptionExpiry() public {
        uint256 amount = 100e18;
        uint256 duration = 30 days;

        vm.prank(viewer1);
        token.approve(address(factory), amount);
        vm.prank(viewer1);
        address wallet = factory.subscribeToStream(streamer1, amount, duration);

        StreamWallet streamWallet = StreamWallet(wallet);

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
        uint256 amount = 100e18;
        uint256 duration = 30 days;

        // First subscription
        vm.prank(viewer1);
        token.approve(address(factory), amount);
        vm.prank(viewer1);
        address wallet = factory.subscribeToStream(streamer1, amount, duration);

        StreamWallet streamWallet = StreamWallet(wallet);

        // Fast forward past expiry
        vm.warp(block.timestamp + duration + 1);
        assertFalse(streamWallet.isSubscribed(viewer1));

        // Renew subscription
        vm.prank(viewer1);
        token.approve(address(factory), amount);
        vm.prank(viewer1);
        factory.subscribeToStream(streamer1, amount, duration);

        // Should be subscribed again
        assertTrue(streamWallet.isSubscribed(viewer1));
    }

    /*//////////////////////////////////////////////////////////////
                    EIP-2612 PERMIT TESTS
    //////////////////////////////////////////////////////////////*/

    function testSubscribeWithPermit() public {
        uint256 pk = 0x1234;
        address user = vm.addr(pk);
        token.mint(user, INITIAL_BALANCE);

        bytes32 hash = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), keccak256(abi.encode(keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"), user, address(factory), 100e18, 0, block.timestamp + 1 hours))));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, hash);

        vm.prank(user);
        address wallet = factory.subscribeToStreamWithPermit(streamer1, 100e18, 30 days, block.timestamp + 1 hours, v, r, s);

        assertTrue(factory.hasWallet(streamer1));
        assertTrue(StreamWallet(wallet).isSubscribed(user));
    }

    function testDonateWithPermit() public {
        uint256 pk = 0x5678;
        address user = vm.addr(pk);
        token.mint(user, INITIAL_BALANCE);

        bytes32 hash = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), keccak256(abi.encode(keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"), user, address(factory), 50e18, 0, block.timestamp + 1 hours))));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, hash);

        vm.prank(user);
        address wallet = factory.donateToStreamWithPermit(streamer1, 50e18, "Permit!", block.timestamp + 1 hours, v, r, s);

        assertTrue(factory.hasWallet(streamer1));
        assertEq(StreamWallet(wallet).totalRevenue(), 50e18);
    }

    function testPermitExpiredDeadline() public {
        uint256 pk = 0x9999;
        address user = vm.addr(pk);
        token.mint(user, INITIAL_BALANCE);

        uint256 pastDeadline = block.timestamp - 1;
        bytes32 hash = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), keccak256(abi.encode(keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"), user, address(factory), 100e18, 0, pastDeadline))));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, hash);

        vm.prank(user);
        vm.expectRevert();
        factory.subscribeToStreamWithPermit(streamer1, 100e18, 30 days, pastDeadline, v, r, s);
    }

    /*//////////////////////////////////////////////////////////////
                        DONATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testDonation() public {
        uint256 donationAmount = 50e18;
        string memory message = "Great stream!";

        // First create a wallet via subscription
        vm.prank(viewer1);
        token.approve(address(factory), 100e18);
        vm.prank(viewer1);
        address wallet = factory.subscribeToStream(streamer1, 100e18, 30 days);

        uint256 streamerBalanceBefore = token.balanceOf(streamer1);
        uint256 treasuryBalanceBefore = token.balanceOf(treasury);

        StreamWallet streamWallet = StreamWallet(wallet);

        // Donate directly to wallet (not through factory)
        vm.prank(viewer2);
        token.approve(wallet, donationAmount);
        
        vm.prank(viewer2);
        streamWallet.donate(donationAmount, message);

        // Check donation recorded
        assertEq(streamWallet.getDonationAmount(viewer2), donationAmount);

        // Check balances
        uint256 expectedFee = (donationAmount * PLATFORM_FEE_BPS) / 10_000;
        uint256 expectedStreamerAmount = donationAmount - expectedFee;

        assertEq(
            token.balanceOf(treasury),
            treasuryBalanceBefore + expectedFee
        );
        assertEq(
            token.balanceOf(streamer1),
            streamerBalanceBefore + expectedStreamerAmount
        );
    }

    function testDonationCreatesWallet() public {
        uint256 donationAmount = 50e18;
        string memory message = "First donation!";

        // Use factory to create wallet via donation
        vm.prank(viewer1);
        token.approve(address(factory), donationAmount);
        
        vm.expectEmit(true, true, false, true);
        emit DonationProcessed(streamer1, viewer1, donationAmount, message);
        
        vm.prank(viewer1);
        address wallet = factory.donateToStream(streamer1, donationAmount, message);

        // Wallet should now exist
        assertTrue(factory.hasWallet(streamer1));
        assertEq(factory.getWallet(streamer1), wallet);

        StreamWallet streamWallet = StreamWallet(wallet);
        
        // Note: donation tracking is tied to msg.sender which is the factory
        // So we check the wallet received revenue
        assertEq(streamWallet.totalRevenue(), donationAmount);
    }

    function testMultipleDonationsAccumulate() public {
        uint256 donation1 = 50e18;
        uint256 donation2 = 75e18;

        // First create wallet via subscription
        vm.prank(viewer1);
        token.approve(address(factory), 100e18);
        vm.prank(viewer1);
        address wallet = factory.subscribeToStream(streamer1, 100e18, 30 days);

        StreamWallet streamWallet = StreamWallet(wallet);

        // First donation
        vm.prank(viewer1);
        token.approve(wallet, donation1);
        vm.prank(viewer1);
        streamWallet.donate(donation1, "First!");

        // Second donation from same viewer
        vm.prank(viewer1);
        token.approve(wallet, donation2);
        vm.prank(viewer1);
        streamWallet.donate(donation2, "Second!");

        // Should accumulate
        assertEq(streamWallet.getDonationAmount(viewer1), donation1 + donation2);
    }

    /*//////////////////////////////////////////////////////////////
                        WITHDRAWAL TESTS
    //////////////////////////////////////////////////////////////*/

    function testStreamerWithdrawal() public {
        // Create wallet with subscription
        uint256 subscriptionAmount = 100e18;
        vm.prank(viewer1);
        token.approve(address(factory), subscriptionAmount);
        vm.prank(viewer1);
        address wallet = factory.subscribeToStream(streamer1, subscriptionAmount, 30 days);

        StreamWallet streamWallet = StreamWallet(wallet);

        // Check available balance (should be 0 as payment was instant)
        assertEq(streamWallet.availableBalance(), 0);

        // Now donate directly to wallet to create balance
        uint256 donationAmount = 50e18;
        vm.prank(viewer2);
        token.approve(wallet, donationAmount);
        vm.prank(viewer2);
        streamWallet.donate(donationAmount, "Test");

        // After donation, streamer should have received payment
        // But let's test withdrawal for any remaining balance
        uint256 balance = streamWallet.availableBalance();
        
        if (balance > 0) {
            uint256 streamerBalanceBefore = token.balanceOf(streamer1);
            
            vm.prank(streamer1);
            streamWallet.withdrawRevenue(balance);

            assertEq(token.balanceOf(streamer1), streamerBalanceBefore + balance);
            assertEq(streamWallet.availableBalance(), 0);
        }
    }

    function testOnlyStreamerCanWithdraw() public {
        // Create wallet
        vm.prank(viewer1);
        token.approve(address(factory), 100e18);
        vm.prank(viewer1);
        address wallet = factory.subscribeToStream(streamer1, 100e18, 30 days);

        StreamWallet streamWallet = StreamWallet(wallet);

        // Try to withdraw as non-streamer
        vm.prank(viewer1);
        vm.expectRevert(StreamWallet.OnlyStreamer.selector);
        streamWallet.withdrawRevenue(1e18);
    }

    /*//////////////////////////////////////////////////////////////
                        FEE CALCULATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testFeeCalculations() public {
        uint256[] memory amounts = new uint256[](5);
        amounts[0] = 100e18;
        amounts[1] = 1000e18;
        amounts[2] = 10000e18;
        amounts[3] = 1e18;
        amounts[4] = 999e18;

        uint256 totalFees = 0;
        uint256 totalStreamerPayments = 0;

        for (uint256 i = 0; i < amounts.length; i++) {
            // Create new viewer for each test
            address viewer = address(uint160(1000 + i));
            token.mint(viewer, amounts[i]);

            vm.prank(viewer);
            token.approve(address(factory), amounts[i]);
            vm.prank(viewer);
            factory.subscribeToStream(streamer1, amounts[i], 30 days);

            uint256 expectedFee = (amounts[i] * PLATFORM_FEE_BPS) / 10_000;
            uint256 expectedStreamerAmount = amounts[i] - expectedFee;

            totalFees += expectedFee;
            totalStreamerPayments += expectedStreamerAmount;
        }

        // Verify total fees collected
        assertEq(token.balanceOf(treasury), totalFees);

        // Verify total streamer payments
        assertEq(
            token.balanceOf(streamer1),
            INITIAL_BALANCE + totalStreamerPayments
        );
    }

    function testZeroFeeEdgeCase() public {
        // Deploy new factory with 0% fee
        vm.prank(admin);
        StreamWalletFactory zeroFeeFactory = new StreamWalletFactory(
            admin,
            address(registry),
            address(token),
            treasury,
            0 // 0% fee
        );

        uint256 amount = 100e18;
        
        vm.prank(viewer1);
        token.approve(address(zeroFeeFactory), amount);
        vm.prank(viewer1);
        zeroFeeFactory.subscribeToStream(streamer2, amount, 30 days);

        // Streamer should receive full amount
        assertEq(token.balanceOf(streamer2), INITIAL_BALANCE + amount);
        
        // Treasury should receive nothing
        assertEq(token.balanceOf(treasury), 0);
    }

    /*//////////////////////////////////////////////////////////////
                        UPGRADE TESTS
    //////////////////////////////////////////////////////////////*/

    function testUpgradeImplementation() public {
        // Create a wallet with first implementation
        vm.prank(viewer1);
        token.approve(address(factory), 100e18);
        vm.prank(viewer1);
        address wallet = factory.subscribeToStream(streamer1, 100e18, 30 days);

        // Deploy new implementation
        StreamWallet newImplementation = new StreamWallet();

        // Upgrade via Safe
        vm.expectEmit(true, false, false, false);
        emit BeaconUpgraded(address(newImplementation));

        vm.prank(gnosisSafe);
        registry.setImplementation(address(newImplementation));

        // Verify upgrade
        assertEq(registry.getImplementation(), address(newImplementation));

        // Existing proxy should still work with new implementation
        StreamWallet streamWallet = StreamWallet(wallet);
        assertTrue(streamWallet.isSubscribed(viewer1));
    }

    function testOnlySafeCanUpgrade() public {
        StreamWallet newImplementation = new StreamWallet();

        // Try to upgrade as non-owner
        vm.prank(admin);
        vm.expectRevert();
        registry.setImplementation(address(newImplementation));

        // Try as viewer
        vm.prank(viewer1);
        vm.expectRevert();
        registry.setImplementation(address(newImplementation));
    }

    /*//////////////////////////////////////////////////////////////
                        REVERT TESTS
    //////////////////////////////////////////////////////////////*/

    function testRevertZeroAmount() public {
        vm.prank(viewer1);
        vm.expectRevert(StreamWalletFactory.InvalidAmount.selector);
        factory.subscribeToStream(streamer1, 0, 30 days);
    }

    function testRevertZeroDuration() public {
        vm.prank(viewer1);
        token.approve(address(factory), 100e18);
        vm.prank(viewer1);
        vm.expectRevert(StreamWalletFactory.InvalidDuration.selector);
        factory.subscribeToStream(streamer1, 100e18, 0);
    }

    function testRevertInsufficientAllowance() public {
        vm.prank(viewer1);
        vm.expectRevert();
        factory.subscribeToStream(streamer1, 100e18, 30 days);
    }

    function testRevertInsufficientBalance() public {
        address poorViewer = address(0x999);
        
        vm.prank(poorViewer);
        token.approve(address(factory), 100e18);
        vm.prank(poorViewer);
        vm.expectRevert();
        factory.subscribeToStream(streamer1, 100e18, 30 days);
    }

    /*//////////////////////////////////////////////////////////////
                        INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testCompleteFlow() public {
        // Step 1: First subscription
        uint256 sub1Amount = 100e18;
        vm.prank(viewer1);
        token.approve(address(factory), sub1Amount);
        vm.prank(viewer1);
        address wallet = factory.subscribeToStream(streamer1, sub1Amount, 30 days);

        StreamWallet streamWallet = StreamWallet(wallet);

        // Step 2: Another viewer subscribes
        uint256 sub2Amount = 200e18;
        vm.prank(viewer2);
        token.approve(address(factory), sub2Amount);
        vm.prank(viewer2);
        factory.subscribeToStream(streamer1, sub2Amount, 60 days);

        // Step 3: First viewer donates directly to wallet
        uint256 donationAmount = 50e18;
        vm.prank(viewer1);
        token.approve(wallet, donationAmount);
        vm.prank(viewer1);
        streamWallet.donate(donationAmount, "Love your content!");

        // Calculate expected totals
        uint256 totalRevenue = sub1Amount + sub2Amount + donationAmount;
        uint256 totalFees = (totalRevenue * PLATFORM_FEE_BPS) / 10_000;
        uint256 totalStreamerPayment = totalRevenue - totalFees;

        // Verify wallet state
        assertEq(streamWallet.totalRevenue(), totalRevenue);
        assertEq(streamWallet.totalSubscribers(), 2);
        assertEq(streamWallet.getDonationAmount(viewer1), donationAmount);

        // Verify balances
        assertEq(token.balanceOf(treasury), totalFees);
        assertEq(token.balanceOf(streamer1), INITIAL_BALANCE + totalStreamerPayment);

        // Verify subscriptions
        assertTrue(streamWallet.isSubscribed(viewer1));
        assertTrue(streamWallet.isSubscribed(viewer2));

        // Step 4: Fast forward past first subscription expiry
        vm.warp(block.timestamp + 31 days);
        assertFalse(streamWallet.isSubscribed(viewer1));
        assertTrue(streamWallet.isSubscribed(viewer2)); // Still active

        // Step 5: Viewer1 resubscribes
        vm.prank(viewer1);
        token.approve(address(factory), sub1Amount);
        vm.prank(viewer1);
        factory.subscribeToStream(streamer1, sub1Amount, 30 days);

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
        uint256 subscriptionAmount = 100e18;

        // Update treasury BEFORE creating any wallets
        vm.prank(admin);
        factory.setTreasury(newTreasury);

        // Verify treasury was updated
        assertEq(factory.treasury(), newTreasury);

        // Approve and subscribe
        vm.prank(viewer1);
        token.approve(address(factory), subscriptionAmount);
        
        vm.prank(viewer1);
        factory.subscribeToStream(streamer1, subscriptionAmount, 30 days);

        // Calculate expected fee
        uint256 expectedFee = (subscriptionAmount * PLATFORM_FEE_BPS) / 10_000;
        
        // Check new treasury received the fee
        uint256 newTreasuryBalance = token.balanceOf(newTreasury);
        assertEq(newTreasuryBalance, expectedFee, "New treasury should have received fee");
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
}
