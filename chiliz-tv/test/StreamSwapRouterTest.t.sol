// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ChilizSwapRouter} from "../src/swap/ChilizSwapRouter.sol";
import {BettingMatchFactory} from "../src/betting/BettingMatchFactory.sol";
import {StreamWalletFactory} from "../src/streamer/StreamWalletFactory.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockKayenRouter} from "./mocks/MockKayenRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Simple mock fan token for ERC20 swap tests
contract MockFanToken is ERC20 {
    constructor() ERC20("Fan Token", "FAN") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/**
 * @title StreamSwapRouterTest
 * @notice Tests for ChilizSwapRouter streaming functions (CHZ / Token / USDC donations & subscriptions)
 */
contract StreamSwapRouterTest is Test {
    MockUSDC public usdc;
    MockKayenRouter public mockRouter;
    MockFanToken public fanToken;
    ChilizSwapRouter public streamSwapRouter;

    address public treasury = address(0x999);
    address public streamer1 = address(0x4);
    address public viewer1 = address(0x6);
    address public viewer2 = address(0x7);

    address public constant WCHZ = address(0xC42);
    uint16 public constant PLATFORM_FEE_BPS = 500; // 5%

    function setUp() public {
        usdc = new MockUSDC();
        mockRouter = new MockKayenRouter(address(usdc));
        fanToken = new MockFanToken();

        streamSwapRouter = new ChilizSwapRouter(
            address(mockRouter), // masterRouter
            address(mockRouter), // tokenRouter (mock implements both)
            address(usdc),
            WCHZ,
            treasury,
            PLATFORM_FEE_BPS
        );

        vm.deal(viewer1, 100 ether);
        vm.deal(viewer2, 100 ether);

        // Mint fan tokens and USDC for direct-payment tests
        fanToken.mint(viewer1, 1000 ether);
        fanToken.mint(viewer2, 1000 ether);
        usdc.mint(viewer1, 100_000e6);
        usdc.mint(viewer2, 100_000e6);
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // CHZ DONATION / SUBSCRIPTION TESTS
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

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

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // USDC DIRECT DONATION / SUBSCRIPTION TESTS (NO SWAP)
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

    function test_DonateWithUSDC() public {
        uint256 amount = 100e6; // 100 USDC

        vm.startPrank(viewer1);
        usdc.approve(address(streamSwapRouter), amount);
        streamSwapRouter.donateWithUSDC(streamer1, "USDC donation!", amount);
        vm.stopPrank();

        uint256 expectedFee = (amount * PLATFORM_FEE_BPS) / 10_000;
        uint256 expectedStreamer = amount - expectedFee;

        assertEq(usdc.balanceOf(treasury), expectedFee, "Treasury should receive fee");
        assertEq(usdc.balanceOf(streamer1), expectedStreamer, "Streamer should receive donation");
    }

    function test_SubscribeWithUSDC() public {
        uint256 amount = 50e6; // 50 USDC
        uint256 duration = 30 days;

        vm.startPrank(viewer1);
        usdc.approve(address(streamSwapRouter), amount);
        streamSwapRouter.subscribeWithUSDC(streamer1, duration, amount);
        vm.stopPrank();

        uint256 expectedFee = (amount * PLATFORM_FEE_BPS) / 10_000;
        uint256 expectedStreamer = amount - expectedFee;

        assertEq(usdc.balanceOf(treasury), expectedFee);
        assertEq(usdc.balanceOf(streamer1), expectedStreamer);
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // ERC20 TOKEN DONATION / SUBSCRIPTION TESTS
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

    function test_DonateWithToken() public {
        uint256 tokenAmount = 10 ether; // 10 FAN tokens
        // 10 tokens * 0.10 = 1 USDC (mock rate)

        vm.startPrank(viewer1);
        fanToken.approve(address(streamSwapRouter), tokenAmount);
        streamSwapRouter.donateWithToken(
            address(fanToken),
            tokenAmount,
            streamer1,
            "Fan token donation!",
            0,
            block.timestamp + 1 hours
        );
        vm.stopPrank();

        uint256 expectedTotal = 1e6;
        uint256 expectedFee = (expectedTotal * PLATFORM_FEE_BPS) / 10_000;
        uint256 expectedStreamer = expectedTotal - expectedFee;

        assertEq(usdc.balanceOf(treasury), expectedFee, "Treasury should receive fee");
        assertEq(usdc.balanceOf(streamer1), expectedStreamer, "Streamer should receive donation");
    }

    function test_SubscribeWithToken() public {
        uint256 tokenAmount = 10 ether;
        uint256 duration = 30 days;

        vm.startPrank(viewer1);
        fanToken.approve(address(streamSwapRouter), tokenAmount);
        streamSwapRouter.subscribeWithToken(
            address(fanToken),
            tokenAmount,
            streamer1,
            duration,
            0,
            block.timestamp + 1 hours
        );
        vm.stopPrank();

        uint256 expectedTotal = 1e6;
        uint256 expectedFee = (expectedTotal * PLATFORM_FEE_BPS) / 10_000;
        uint256 expectedStreamer = expectedTotal - expectedFee;

        assertEq(usdc.balanceOf(treasury), expectedFee);
        assertEq(usdc.balanceOf(streamer1), expectedStreamer);
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // REVERT TESTS
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

    function test_RevertDonateZeroValue() public {
        vm.prank(viewer1);
        vm.expectRevert(ChilizSwapRouter.ZeroValue.selector);
        streamSwapRouter.donateWithCHZ{value: 0}(
            streamer1, "test", 0, block.timestamp + 1 hours
        );
    }

    function test_RevertDonateZeroAddress() public {
        vm.prank(viewer1);
        vm.expectRevert(ChilizSwapRouter.ZeroAddress.selector);
        streamSwapRouter.donateWithCHZ{value: 1 ether}(
            address(0), "test", 0, block.timestamp + 1 hours
        );
    }

    function test_RevertDonateExpiredDeadline() public {
        vm.prank(viewer1);
        vm.expectRevert(ChilizSwapRouter.DeadlinePassed.selector);
        streamSwapRouter.donateWithCHZ{value: 1 ether}(
            streamer1, "test", 0, block.timestamp - 1
        );
    }

    function test_RevertSubscribeZeroDuration() public {
        vm.prank(viewer1);
        vm.expectRevert(ChilizSwapRouter.ZeroValue.selector);
        streamSwapRouter.subscribeWithCHZ{value: 1 ether}(
            streamer1, 0, 0, block.timestamp + 1 hours
        );
    }

    function test_RevertDonateSlippageTooHigh() public {
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

    // USDC direct reverts
    function test_RevertDonateUSDCZeroAmount() public {
        vm.prank(viewer1);
        vm.expectRevert(ChilizSwapRouter.ZeroValue.selector);
        streamSwapRouter.donateWithUSDC(streamer1, "test", 0);
    }

    function test_RevertDonateUSDCZeroAddress() public {
        vm.prank(viewer1);
        vm.expectRevert(ChilizSwapRouter.ZeroAddress.selector);
        streamSwapRouter.donateWithUSDC(address(0), "test", 1e6);
    }

    function test_RevertSubscribeUSDCZeroDuration() public {
        vm.startPrank(viewer1);
        usdc.approve(address(streamSwapRouter), 1e6);
        vm.expectRevert(ChilizSwapRouter.ZeroValue.selector);
        streamSwapRouter.subscribeWithUSDC(streamer1, 0, 1e6);
        vm.stopPrank();
    }

    // Token reverts
    function test_RevertDonateTokenIsUSDC() public {
        vm.startPrank(viewer1);
        usdc.approve(address(streamSwapRouter), 1e6);
        vm.expectRevert(ChilizSwapRouter.TokenIsUSDC.selector);
        streamSwapRouter.donateWithToken(
            address(usdc), 1e6, streamer1, "test", 0, block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    function test_RevertSubscribeTokenIsUSDC() public {
        vm.startPrank(viewer1);
        usdc.approve(address(streamSwapRouter), 1e6);
        vm.expectRevert(ChilizSwapRouter.TokenIsUSDC.selector);
        streamSwapRouter.subscribeWithToken(
            address(usdc), 1e6, streamer1, 30 days, 0, block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // ADMIN TESTS
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

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
        vm.expectRevert(ChilizSwapRouter.ZeroAddress.selector);
        streamSwapRouter.setTreasury(address(0));
    }

    function test_RevertSetFeeTooHigh() public {
        vm.expectRevert(ChilizSwapRouter.InvalidFeeBps.selector);
        streamSwapRouter.setPlatformFeeBps(10001);
    }

    function test_RevertNonOwnerSetTreasury() public {
        vm.prank(viewer1);
        vm.expectRevert();
        streamSwapRouter.setTreasury(address(0xABC));
    }

    // ══════════════════════════════════════════════════════════════════════════
    // M-02: setMatchFactory — registry validation for bettingMatch addresses
    // ══════════════════════════════════════════════════════════════════════════

    function test_M02_SetMatchFactory_SetsFactory() public {
        BettingMatchFactory bmf = new BettingMatchFactory();
        streamSwapRouter.setMatchFactory(address(bmf));
        assertEq(address(streamSwapRouter.bettingMatchFactory()), address(bmf));
    }

    function test_M02_SetMatchFactory_ZeroReverts() public {
        vm.expectRevert(ChilizSwapRouter.ZeroAddress.selector);
        streamSwapRouter.setMatchFactory(address(0));
    }

    function test_M02_NonOwner_SetMatchFactory_Reverts() public {
        BettingMatchFactory bmf = new BettingMatchFactory();
        vm.prank(viewer1);
        vm.expectRevert();
        streamSwapRouter.setMatchFactory(address(bmf));
    }

    function test_M02_PlaceBetWithUSDC_UnauthorizedMatch_Reverts() public {
        // Register a real factory — the unknown address is NOT in it
        BettingMatchFactory bmf = new BettingMatchFactory();
        streamSwapRouter.setMatchFactory(address(bmf));

        address unknownMatch = address(0xBEEF);
        uint256 betAmount = 10e6;

        vm.startPrank(viewer1);
        usdc.approve(address(streamSwapRouter), betAmount);
        vm.expectRevert(abi.encodeWithSelector(
            ChilizSwapRouter.UnauthorizedBettingMatch.selector,
            unknownMatch
        ));
        streamSwapRouter.placeBetWithUSDC(unknownMatch, 0, 0, betAmount);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // M-04: setStreamWalletFactory — config-order validation
    // ══════════════════════════════════════════════════════════════════════════

    function test_M04_SetStreamWalletFactory_WrongConfig_Reverts() public {
        // Deploy factory with a different (or unset) swapRouter
        StreamWalletFactory swf = new StreamWalletFactory(
            address(this), treasury, 500, address(mockRouter), address(usdc)
        );
        // swf.swapRouter() == address(0), not streamSwapRouter
        vm.expectRevert(ChilizSwapRouter.RouterNotConfiguredOnFactory.selector);
        streamSwapRouter.setStreamWalletFactory(address(swf));
    }

    function test_M04_SetStreamWalletFactory_CorrectConfig_Works() public {
        StreamWalletFactory swf = new StreamWalletFactory(
            address(this), treasury, 500, address(mockRouter), address(usdc)
        );
        // Configure the factory to point to this router first
        swf.setSwapRouter(address(streamSwapRouter));
        // Now registration should succeed
        streamSwapRouter.setStreamWalletFactory(address(swf));
        assertEq(address(streamSwapRouter.streamWalletFactory()), address(swf));
    }
}
