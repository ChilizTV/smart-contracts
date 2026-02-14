// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {StreamSwapRouter} from "../src/streamer/StreamSwapRouter.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockKayenRouter} from "./mocks/MockKayenRouter.sol";

/**
 * @title StreamSwapRouterTest
 * @notice Tests for StreamSwapRouter (CHZ→USDC donations/subscriptions)
 */
contract StreamSwapRouterTest is Test {
    MockUSDC public usdc;
    MockKayenRouter public mockRouter;
    StreamSwapRouter public streamSwapRouter;

    address public treasury = address(0x999);
    address public streamer1 = address(0x4);
    address public viewer1 = address(0x6);
    address public viewer2 = address(0x7);

    address public constant WCHZ = address(0xC42);
    uint16 public constant PLATFORM_FEE_BPS = 500; // 5%

    function setUp() public {
        usdc = new MockUSDC();
        mockRouter = new MockKayenRouter(address(usdc));

        streamSwapRouter = new StreamSwapRouter(
            address(mockRouter),
            address(usdc),
            WCHZ,
            treasury,
            PLATFORM_FEE_BPS
        );

        vm.deal(viewer1, 100 ether);
        vm.deal(viewer2, 100 ether);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // DONATION TESTS
    // ══════════════════════════════════════════════════════════════════════════

    function test_DonateWithCHZ() public {
        // 10 CHZ * 0.10 = 1 USDC, 5% fee = 0.05 USDC to treasury, 0.95 USDC to streamer
        vm.prank(viewer1);
        streamSwapRouter.donateWithCHZ{value: 10 ether}(
            streamer1,
            "Great stream!",
            0,
            block.timestamp + 1 hours
        );

        uint256 expectedTotal = 1e6; // 1 USDC
        uint256 expectedFee = (expectedTotal * PLATFORM_FEE_BPS) / 10_000;
        uint256 expectedStreamer = expectedTotal - expectedFee;

        assertEq(usdc.balanceOf(treasury), expectedFee, "Treasury should receive fee");
        assertEq(usdc.balanceOf(streamer1), expectedStreamer, "Streamer should receive donation");
    }

    function test_SubscribeWithCHZ() public {
        uint256 duration = 30 days;

        vm.prank(viewer1);
        streamSwapRouter.subscribeWithCHZ{value: 10 ether}(
            streamer1,
            duration,
            0,
            block.timestamp + 1 hours
        );

        uint256 expectedTotal = 1e6;
        uint256 expectedFee = (expectedTotal * PLATFORM_FEE_BPS) / 10_000;
        uint256 expectedStreamer = expectedTotal - expectedFee;

        assertEq(usdc.balanceOf(treasury), expectedFee);
        assertEq(usdc.balanceOf(streamer1), expectedStreamer);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // REVERT TESTS
    // ══════════════════════════════════════════════════════════════════════════

    function test_RevertDonateZeroValue() public {
        vm.prank(viewer1);
        vm.expectRevert(StreamSwapRouter.ZeroValue.selector);
        streamSwapRouter.donateWithCHZ{value: 0}(
            streamer1, "test", 0, block.timestamp + 1 hours
        );
    }

    function test_RevertDonateZeroAddress() public {
        vm.prank(viewer1);
        vm.expectRevert(StreamSwapRouter.ZeroAddress.selector);
        streamSwapRouter.donateWithCHZ{value: 1 ether}(
            address(0), "test", 0, block.timestamp + 1 hours
        );
    }

    function test_RevertDonateExpiredDeadline() public {
        vm.prank(viewer1);
        vm.expectRevert(StreamSwapRouter.DeadlinePassed.selector);
        streamSwapRouter.donateWithCHZ{value: 1 ether}(
            streamer1, "test", 0, block.timestamp - 1
        );
    }

    function test_RevertSubscribeZeroDuration() public {
        vm.prank(viewer1);
        vm.expectRevert(StreamSwapRouter.ZeroValue.selector);
        streamSwapRouter.subscribeWithCHZ{value: 1 ether}(
            streamer1, 0, 0, block.timestamp + 1 hours
        );
    }

    function test_RevertDonateSlippageTooHigh() public {
        // 1 ether * 0.10 = 0.1 USDC, but request 1 USDC min
        vm.prank(viewer1);
        vm.expectRevert("MockRouter: insufficient output");
        streamSwapRouter.donateWithCHZ{value: 1 ether}(
            streamer1, "test", 1e6, block.timestamp + 1 hours
        );
    }

    function test_RevertDonateSwapFailure() public {
        mockRouter.setShouldFail(true);

        vm.prank(viewer1);
        vm.expectRevert("MockRouter: swap failed");
        streamSwapRouter.donateWithCHZ{value: 1 ether}(
            streamer1, "test", 0, block.timestamp + 1 hours
        );
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ADMIN TESTS
    // ══════════════════════════════════════════════════════════════════════════

    function test_SetTreasury() public {
        address newTreasury = address(0xABC);
        streamSwapRouter.setTreasury(newTreasury);
        assertEq(streamSwapRouter.treasury(), newTreasury);
    }

    function test_SetPlatformFee() public {
        streamSwapRouter.setPlatformFeeBps(1000); // 10%
        assertEq(streamSwapRouter.platformFeeBps(), 1000);
    }

    function test_RevertSetTreasuryZero() public {
        vm.expectRevert(StreamSwapRouter.ZeroAddress.selector);
        streamSwapRouter.setTreasury(address(0));
    }

    function test_RevertSetFeeTooHigh() public {
        vm.expectRevert(StreamSwapRouter.InvalidFeeBps.selector);
        streamSwapRouter.setPlatformFeeBps(10001);
    }

    function test_RevertNonOwnerSetTreasury() public {
        vm.prank(viewer1);
        vm.expectRevert();
        streamSwapRouter.setTreasury(address(0xABC));
    }
}
