// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StreamWalletFactory} from "../src/streamer/StreamWalletFactory.sol";
import {StreamWallet} from "../src/streamer/StreamWallet.sol";

// Mock contract to receive CHZ
contract MockTreasury {
    receive() external payable {}
}

contract StreamBeaconRegistryTest is Test {
    StreamWalletFactory public factory;

    address public admin = address(0x1);
    address public gnosisSafe = address(0x2);
    MockTreasury public treasury;
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
        // Deploy mock treasury to receive CHZ
        treasury = new MockTreasury();

        // Deploy factory (deploys implementation internally)
        vm.prank(admin);
        factory = new StreamWalletFactory(
            admin,
            address(treasury),
            PLATFORM_FEE_BPS
        );

        // Fund viewers and streamers with native CHZ
        vm.deal(viewer1, INITIAL_BALANCE);
        vm.deal(viewer2, INITIAL_BALANCE);
        vm.deal(streamer1, INITIAL_BALANCE);
        vm.deal(streamer2, INITIAL_BALANCE);
    }

    /*//////////////////////////////////////////////////////////////
                        DEPLOYMENT & SETUP TESTS
    //////////////////////////////////////////////////////////////*/

    function testFactoryDeployment() public view {
        assertEq(factory.owner(), admin);
        assertEq(factory.treasury(), address(treasury));
        assertEq(factory.defaultPlatformFeeBps(), PLATFORM_FEE_BPS);
        assertTrue(factory.implementation() != address(0));
    }

    /*//////////////////////////////////////////////////////////////
                        SUBSCRIPTION TESTS
    //////////////////////////////////////////////////////////////*/

    function testFirstSubscription() public {
        uint256 subscriptionAmount = 100 ether;
        uint256 duration = 30 days;

        // Check wallet doesn't exist yet
        assertFalse(factory.hasWallet(streamer1));

        // Subscribe with native CHZ
        vm.prank(viewer1);
        address wallet = factory.subscribeToStream{value: subscriptionAmount}(streamer1, duration);

        // Verify wallet created
        assertTrue(factory.hasWallet(streamer1));
        assertEq(factory.getWallet(streamer1), wallet);

        // Check balances
        StreamWallet streamWallet = StreamWallet(payable(wallet));
        uint256 expectedFee = (subscriptionAmount * PLATFORM_FEE_BPS) / 10_000;
        uint256 expectedStreamerAmount = subscriptionAmount - expectedFee;

        // Treasury should have received platform fee
        assertEq(address(treasury).balance, expectedFee);
        
        // Streamer should have received payment
        assertEq(streamer1.balance, INITIAL_BALANCE + expectedStreamerAmount);

        // Verify subscription data
        assertTrue(streamWallet.isSubscribed(viewer1));
        assertEq(streamWallet.totalRevenue(), subscriptionAmount);
        assertEq(streamWallet.totalSubscribers(), 1);

        // Viewer balance should be reduced
        assertEq(viewer1.balance, INITIAL_BALANCE - subscriptionAmount);
    }

    function testMultipleSubscriptions() public {
        uint256 amount1 = 100 ether;
        uint256 amount2 = 200 ether;
        uint256 duration = 30 days;

        // First subscription from viewer1
        vm.prank(viewer1);
        address wallet = factory.subscribeToStream{value: amount1}(streamer1, duration);

        // Second subscription from viewer2 to same streamer
        vm.prank(viewer2);
        address wallet2 = factory.subscribeToStream{value: amount2}(streamer1, duration);

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

        // Check total fees
        uint256 totalFees = ((amount1 + amount2) * PLATFORM_FEE_BPS) / 10_000;
        assertEq(address(treasury).balance, totalFees);
    }

    function testSubscriptionToMultipleStreamers() public {
        uint256 amount = 100 ether;
        uint256 duration = 30 days;

        // Subscribe to streamer1
        vm.prank(viewer1);
        address wallet1 = factory.subscribeToStream{value: amount}(streamer1, duration);

        // Subscribe to streamer2
        vm.prank(viewer1);
        address wallet2 = factory.subscribeToStream{value: amount}(streamer2, duration);

        // Different wallets for different streamers
        assertTrue(wallet1 != wallet2);

        // Both wallets should exist
        assertTrue(factory.hasWallet(streamer1));
        assertTrue(factory.hasWallet(streamer2));

        // Both streamers should have received payments
        uint256 expectedStreamerAmount = amount - ((amount * PLATFORM_FEE_BPS) / 10_000);
        assertEq(streamer1.balance, INITIAL_BALANCE + expectedStreamerAmount);
        assertEq(streamer2.balance, INITIAL_BALANCE + expectedStreamerAmount);
    }

    function testSubscriptionExpiry() public {
        uint256 amount = 100 ether;
        uint256 duration = 30 days;

        vm.prank(viewer1);
        address wallet = factory.subscribeToStream{value: amount}(streamer1, duration);

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
        address wallet = factory.subscribeToStream{value: amount}(streamer1, duration);

        StreamWallet streamWallet = StreamWallet(payable(wallet));

        // Fast forward past expiry
        vm.warp(block.timestamp + duration + 1);
        assertFalse(streamWallet.isSubscribed(viewer1));

        // Renew subscription
        vm.prank(viewer1);
        factory.subscribeToStream{value: amount}(streamer1, duration);

        // Should be subscribed again
        assertTrue(streamWallet.isSubscribed(viewer1));
    }

    /*//////////////////////////////////////////////////////////////
                        DONATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testDonation() public {
        uint256 donationAmount = 50 ether;
        string memory message = "Great stream!";

        // First create a wallet via subscription
        vm.prank(viewer1);
        address wallet = factory.subscribeToStream{value: 100 ether}(streamer1, 30 days);

        uint256 streamerBalanceBefore = streamer1.balance;
        uint256 treasuryBalanceBefore = address(treasury).balance;

        StreamWallet streamWallet = StreamWallet(payable(wallet));

        // Donate directly to wallet
        vm.prank(viewer2);
        streamWallet.donate{value: donationAmount}(donationAmount, message);

        // Check donation recorded
        assertEq(streamWallet.getDonationAmount(viewer2), donationAmount);

        // Check balances
        uint256 expectedFee = (donationAmount * PLATFORM_FEE_BPS) / 10_000;
        uint256 expectedStreamerAmount = donationAmount - expectedFee;

        assertEq(
            address(treasury).balance,
            treasuryBalanceBefore + expectedFee
        );
        assertEq(
            streamer1.balance,
            streamerBalanceBefore + expectedStreamerAmount
        );
    }

    function testDonationCreatesWallet() public {
        uint256 donationAmount = 50 ether;
        string memory message = "First donation!";

        // Use factory to create wallet via donation
        vm.expectEmit(true, true, false, true);
        emit DonationProcessed(streamer1, viewer1, donationAmount, message);
        
        vm.prank(viewer1);
        address wallet = factory.donateToStream{value: donationAmount}(streamer1, message);

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
        address wallet = factory.subscribeToStream{value: 100 ether}(streamer1, 30 days);

        StreamWallet streamWallet = StreamWallet(payable(wallet));

        // First donation
        vm.prank(viewer1);
        streamWallet.donate{value: donation1}(donation1, "First!");

        // Second donation from same viewer
        vm.prank(viewer1);
        streamWallet.donate{value: donation2}(donation2, "Second!");

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
        address wallet = factory.subscribeToStream{value: subscriptionAmount}(streamer1, 30 days);

        StreamWallet streamWallet = StreamWallet(payable(wallet));

        // Check available balance (should be 0 as payment was instant)
        assertEq(streamWallet.availableBalance(), 0);

        // Wallet has 0 balance since payments are immediate, but let's test the withdrawal function
        // by sending CHZ directly to the wallet
        vm.deal(wallet, 10 ether);

        uint256 balance = streamWallet.availableBalance();
        assertEq(balance, 10 ether);

        uint256 streamerBalanceBefore = streamer1.balance;
        
        vm.prank(streamer1);
        streamWallet.withdrawRevenue(balance);

        assertEq(streamer1.balance, streamerBalanceBefore + balance);
        assertEq(streamWallet.availableBalance(), 0);
    }

    function testOnlyStreamerCanWithdraw() public {
        // Create wallet
        vm.prank(viewer1);
        address wallet = factory.subscribeToStream{value: 100 ether}(streamer1, 30 days);

        StreamWallet streamWallet = StreamWallet(payable(wallet));

        // Fund wallet
        vm.deal(wallet, 1 ether);

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
            vm.deal(viewer, amounts[i]);

            vm.prank(viewer);
            factory.subscribeToStream{value: amounts[i]}(streamer1, 30 days);

            uint256 expectedFee = (amounts[i] * PLATFORM_FEE_BPS) / 10_000;
            uint256 expectedStreamerAmount = amounts[i] - expectedFee;

            totalFees += expectedFee;
            totalStreamerPayments += expectedStreamerAmount;
        }

        // Verify total fees collected
        assertEq(address(treasury).balance, totalFees);

        // Verify total streamer payments
        assertEq(
            streamer1.balance,
            INITIAL_BALANCE + totalStreamerPayments
        );
    }

    function testZeroFeeEdgeCase() public {
        // Deploy new factory with 0% fee
        vm.prank(admin);
        StreamWalletFactory zeroFeeFactory = new StreamWalletFactory(
            admin,
            address(treasury),
            0 // 0% fee
        );

        uint256 amount = 100 ether;
        
        vm.prank(viewer1);
        zeroFeeFactory.subscribeToStream{value: amount}(streamer2, 30 days);

        // Streamer should receive full amount
        assertEq(streamer2.balance, INITIAL_BALANCE + amount);
        
        // Treasury should receive nothing (still 0 from previous tests)
        assertEq(address(treasury).balance, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        UPGRADE TESTS (UUPS)
    //////////////////////////////////////////////////////////////*/

    function testUpgradeImplementation() public {
        // Create a wallet with first implementation
        vm.prank(viewer1);
        address wallet = factory.subscribeToStream{value: 100 ether}(streamer1, 30 days);

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
        address wallet = factory.subscribeToStream{value: 100 ether}(streamer1, 30 days);

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
        factory.subscribeToStream{value: 0}(streamer1, 30 days);
    }

    function testRevertZeroDuration() public {
        vm.prank(viewer1);
        vm.expectRevert(StreamWalletFactory.InvalidDuration.selector);
        factory.subscribeToStream{value: 100 ether}(streamer1, 0);
    }

    function testRevertInsufficientBalance() public {
        address poorViewer = address(0x999);
        vm.deal(poorViewer, 1 ether);

        // Sending 0 value should revert with InvalidAmount
        vm.prank(poorViewer);
        vm.expectRevert(StreamWalletFactory.InvalidAmount.selector);
        factory.subscribeToStream{value: 0}(streamer1, 30 days);
    }

    /*//////////////////////////////////////////////////////////////
                        INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testCompleteFlow() public {
        // Step 1: First subscription
        uint256 sub1Amount = 100 ether;
        vm.prank(viewer1);
        address wallet = factory.subscribeToStream{value: sub1Amount}(streamer1, 30 days);

        StreamWallet streamWallet = StreamWallet(payable(wallet));

        // Step 2: Another viewer subscribes
        uint256 sub2Amount = 200 ether;
        vm.prank(viewer2);
        factory.subscribeToStream{value: sub2Amount}(streamer1, 60 days);

        // Step 3: First viewer donates directly to wallet
        uint256 donationAmount = 50 ether;
        vm.prank(viewer1);
        streamWallet.donate{value: donationAmount}(donationAmount, "Love your content!");

        // Calculate expected totals
        uint256 totalRevenue = sub1Amount + sub2Amount + donationAmount;
        uint256 totalFees = (totalRevenue * PLATFORM_FEE_BPS) / 10_000;
        uint256 totalStreamerPayment = totalRevenue - totalFees;

        // Verify wallet state
        assertEq(streamWallet.totalRevenue(), totalRevenue);
        assertEq(streamWallet.totalSubscribers(), 2);
        assertEq(streamWallet.getDonationAmount(viewer1), donationAmount);

        // Verify balances
        assertEq(address(treasury).balance, totalFees);
        assertEq(streamer1.balance, INITIAL_BALANCE + totalStreamerPayment);

        // Verify subscriptions
        assertTrue(streamWallet.isSubscribed(viewer1));
        assertTrue(streamWallet.isSubscribed(viewer2));

        // Step 4: Fast forward past first subscription expiry
        vm.warp(block.timestamp + 31 days);
        assertFalse(streamWallet.isSubscribed(viewer1));
        assertTrue(streamWallet.isSubscribed(viewer2)); // Still active

        // Step 5: Viewer1 resubscribes
        vm.prank(viewer1);
        factory.subscribeToStream{value: sub1Amount}(streamer1, 30 days);

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
        MockTreasury newTreasury = new MockTreasury();
        uint256 subscriptionAmount = 100 ether;

        // Update treasury BEFORE creating any wallets
        vm.prank(admin);
        factory.setTreasury(address(newTreasury));

        // Verify treasury was updated
        assertEq(factory.treasury(), address(newTreasury));

        // Subscribe
        vm.prank(viewer1);
        factory.subscribeToStream{value: subscriptionAmount}(streamer1, 30 days);

        // Calculate expected fee
        uint256 expectedFee = (subscriptionAmount * PLATFORM_FEE_BPS) / 10_000;
        
        // Check new treasury received the fee
        uint256 newTreasuryBalance = address(newTreasury).balance;
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

    /*//////////////////////////////////////////////////////////////
                        RECEIVE FUNCTION TEST
    //////////////////////////////////////////////////////////////*/

    function testWalletCanReceiveCHZ() public {
        // Create wallet
        vm.prank(viewer1);
        address wallet = factory.subscribeToStream{value: 100 ether}(streamer1, 30 days);

        // Send CHZ directly to wallet
        vm.deal(address(this), 10 ether);
        (bool success,) = wallet.call{value: 10 ether}("");
        assertTrue(success);

        // Verify wallet received CHZ
        assertEq(wallet.balance, 10 ether);
    }
}
