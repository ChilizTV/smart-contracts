// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IKayenMasterRouterV2} from "../interfaces/IKayenMasterRouterV2.sol";
import {IKayenRouter} from "../interfaces/IKayenRouter.sol";

/**
 * @title StreamSwapRouter
 * @notice Universal swap router for streaming donations and subscriptions.
 *         Accepts CHZ (native), WCHZ, fan tokens, any ERC20, or USDC directly,
 *         always settling in USDC which is forwarded to the streamer/treasury.
 * @dev Mirrors the BettingSwapRouter payment-path pattern:
 *
 * Supported Payment Paths:
 * - CHZ (native) → USDC → streamer/treasury  (donateWithCHZ / subscribeWithCHZ)
 * - WCHZ / Fan Token / ERC20 → USDC → streamer/treasury  (donateWithToken / subscribeWithToken)
 * - USDC direct → streamer/treasury  (donateWithUSDC / subscribeWithUSDC, no swap)
 *
 * Frontend Integration Notes:
 * - Native CHZ:  `donateWithCHZ{value: chzAmount}(streamer, message, minUSDCOut, deadline)`
 * - ERC20 token: `donateWithToken(token, amount, streamer, message, minUSDCOut, deadline)` (approve first)
 * - USDC direct: `donateWithUSDC(streamer, message, amount)` (approve first, no swap)
 * - Same pattern for `subscribeWith*` variants
 * - `minUSDCOut`: minimum USDC to accept (6 decimals, slippage protection)
 * - `deadline`: unix timestamp for swap expiry
 */
contract StreamSwapRouter is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    /// @notice Kayen DEX master router (for native CHZ swaps)
    IKayenMasterRouterV2 public immutable masterRouter;

    /// @notice Kayen DEX token router (for ERC20-to-ERC20 swaps)
    IKayenRouter public immutable tokenRouter;

    /// @notice USDC token address
    IERC20 public immutable usdc;

    /// @notice Wrapped CHZ (WCHZ) address
    address public immutable wchz;

    /// @notice Platform treasury for fee collection
    address public treasury;
    
    /// @notice Platform fee in basis points (e.g., 500 = 5%)
    uint16 public platformFeeBps;

    // ── Events ───────────────────────────────────────────────────────────────

    /// @notice Emitted when a donation is made via native CHZ swap
    event DonationWithCHZ(
        address indexed donor,
        address indexed streamer,
        uint256 chzSpent,
        uint256 usdcDonated,
        uint256 platformFee,
        string message
    );

    /// @notice Emitted when a donation is made via ERC20 token swap
    event DonationWithToken(
        address indexed donor,
        address indexed streamer,
        address indexed token,
        uint256 tokenSpent,
        uint256 usdcDonated,
        uint256 platformFee,
        string message
    );

    /// @notice Emitted when a donation is made directly with USDC (no swap)
    event DonationWithUSDCEvent(
        address indexed donor,
        address indexed streamer,
        uint256 amount,
        uint256 platformFee,
        string message
    );

    /// @notice Emitted when a subscription is paid via native CHZ swap
    event SubscriptionWithCHZ(
        address indexed subscriber,
        address indexed streamer,
        uint256 chzSpent,
        uint256 usdcPaid,
        uint256 platformFee,
        uint256 duration
    );

    /// @notice Emitted when a subscription is paid via ERC20 token swap
    event SubscriptionWithToken(
        address indexed subscriber,
        address indexed streamer,
        address indexed token,
        uint256 tokenSpent,
        uint256 usdcPaid,
        uint256 platformFee,
        uint256 duration
    );

    /// @notice Emitted when a subscription is paid directly with USDC (no swap)
    event SubscriptionWithUSDCEvent(
        address indexed subscriber,
        address indexed streamer,
        uint256 amount,
        uint256 platformFee,
        uint256 duration
    );

    // ── Errors ───────────────────────────────────────────────────────────────

    error ZeroAddress();
    error ZeroValue();
    error DeadlinePassed();
    error InvalidFeeBps();
    error TokenIsUSDC();

    constructor(
        address _masterRouter,
        address _tokenRouter,
        address _usdc,
        address _wchz,
        address _treasury,
        uint16 _platformFeeBps
    ) Ownable(msg.sender) {
        if (_masterRouter == address(0) || _tokenRouter == address(0)
            || _usdc == address(0) || _wchz == address(0) || _treasury == address(0)) {
            revert ZeroAddress();
        }
        if (_platformFeeBps > 10_000) revert InvalidFeeBps();
        masterRouter = IKayenMasterRouterV2(_masterRouter);
        tokenRouter = IKayenRouter(_tokenRouter);
        usdc = IERC20(_usdc);
        wchz = _wchz;
        treasury = _treasury;
        platformFeeBps = _platformFeeBps;
    }

    // ══════════════════════════════════════════════════════════════════════════
    // NATIVE CHZ → USDC → DONATE / SUBSCRIBE
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Donate to a streamer: swap CHZ→USDC and send USDC to streamer/treasury
     * @param streamer Recipient streamer address
     * @param message Donation message
     * @param amountOutMin Minimum USDC to accept (slippage protection)
     * @param deadline Unix timestamp deadline
     */
    function donateWithCHZ(
        address streamer,
        string calldata message,
        uint256 amountOutMin,
        uint256 deadline
    ) external payable nonReentrant {
        if (msg.value == 0) revert ZeroValue();
        if (streamer == address(0)) revert ZeroAddress();
        if (block.timestamp > deadline) revert DeadlinePassed();

        uint256 usdcReceived = _swapCHZToUSDC(msg.value, amountOutMin, deadline);
        (uint256 fee, uint256 streamerAmount) = _splitAndTransfer(streamer, usdcReceived);

        emit DonationWithCHZ(msg.sender, streamer, msg.value, usdcReceived, fee, message);
    }

    /**
     * @notice Subscribe to a streamer: swap CHZ→USDC and send USDC to streamer/treasury
     * @param streamer Recipient streamer address
     * @param duration Subscription duration in seconds
     * @param amountOutMin Minimum USDC to accept (slippage protection)
     * @param deadline Unix timestamp deadline
     */
    function subscribeWithCHZ(
        address streamer,
        uint256 duration,
        uint256 amountOutMin,
        uint256 deadline
    ) external payable nonReentrant {
        if (msg.value == 0) revert ZeroValue();
        if (streamer == address(0)) revert ZeroAddress();
        if (duration == 0) revert ZeroValue();
        if (block.timestamp > deadline) revert DeadlinePassed();

        uint256 usdcReceived = _swapCHZToUSDC(msg.value, amountOutMin, deadline);
        (uint256 fee,) = _splitAndTransfer(streamer, usdcReceived);

        emit SubscriptionWithCHZ(msg.sender, streamer, msg.value, usdcReceived, fee, duration);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // USDC DIRECT → DONATE / SUBSCRIBE (NO SWAP)
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Donate to a streamer directly with USDC — no swap needed
     * @param streamer Recipient streamer address
     * @param message Donation message
     * @param amount USDC amount to donate (caller must approve this contract first)
     */
    function donateWithUSDC(
        address streamer,
        string calldata message,
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) revert ZeroValue();
        if (streamer == address(0)) revert ZeroAddress();

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        (uint256 fee,) = _splitAndTransfer(streamer, amount);

        emit DonationWithUSDCEvent(msg.sender, streamer, amount, fee, message);
    }

    /**
     * @notice Subscribe to a streamer directly with USDC — no swap needed
     * @param streamer Recipient streamer address
     * @param duration Subscription duration in seconds
     * @param amount USDC amount to pay (caller must approve this contract first)
     */
    function subscribeWithUSDC(
        address streamer,
        uint256 duration,
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) revert ZeroValue();
        if (streamer == address(0)) revert ZeroAddress();
        if (duration == 0) revert ZeroValue();

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        (uint256 fee,) = _splitAndTransfer(streamer, amount);

        emit SubscriptionWithUSDCEvent(msg.sender, streamer, amount, fee, duration);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ERC20 (WCHZ / FAN TOKEN / ANY) → USDC → DONATE / SUBSCRIBE
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Donate to a streamer: swap any ERC20 → USDC and send to streamer/treasury
     * @param token The ERC20 token to swap (WCHZ, fan token, etc.)
     * @param amount Amount of tokens to spend
     * @param streamer Recipient streamer address
     * @param message Donation message
     * @param amountOutMin Minimum USDC to accept (slippage protection)
     * @param deadline Unix timestamp deadline
     */
    function donateWithToken(
        address token,
        uint256 amount,
        address streamer,
        string calldata message,
        uint256 amountOutMin,
        uint256 deadline
    ) external nonReentrant {
        if (amount == 0) revert ZeroValue();
        if (token == address(0) || streamer == address(0)) revert ZeroAddress();
        if (token == address(usdc)) revert TokenIsUSDC();
        if (block.timestamp > deadline) revert DeadlinePassed();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 usdcReceived = _swapTokensToUSDC(token, amount, amountOutMin, deadline);
        (uint256 fee,) = _splitAndTransfer(streamer, usdcReceived);

        emit DonationWithToken(msg.sender, streamer, token, amount, usdcReceived, fee, message);
    }

    /**
     * @notice Subscribe to a streamer: swap any ERC20 → USDC and send to streamer/treasury
     * @param token The ERC20 token to swap (WCHZ, fan token, etc.)
     * @param amount Amount of tokens to spend
     * @param streamer Recipient streamer address
     * @param duration Subscription duration in seconds
     * @param amountOutMin Minimum USDC to accept (slippage protection)
     * @param deadline Unix timestamp deadline
     */
    function subscribeWithToken(
        address token,
        uint256 amount,
        address streamer,
        uint256 duration,
        uint256 amountOutMin,
        uint256 deadline
    ) external nonReentrant {
        if (amount == 0) revert ZeroValue();
        if (token == address(0) || streamer == address(0)) revert ZeroAddress();
        if (token == address(usdc)) revert TokenIsUSDC();
        if (duration == 0) revert ZeroValue();
        if (block.timestamp > deadline) revert DeadlinePassed();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 usdcReceived = _swapTokensToUSDC(token, amount, amountOutMin, deadline);
        (uint256 fee,) = _splitAndTransfer(streamer, usdcReceived);

        emit SubscriptionWithToken(msg.sender, streamer, token, amount, usdcReceived, fee, duration);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // INTERNAL HELPERS
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @dev Swap exact native CHZ to USDC via Kayen master router
     */
    function _swapCHZToUSDC(
        uint256 chzAmount,
        uint256 amountOutMin,
        uint256 deadline
    ) internal returns (uint256 usdcReceived) {
        address[] memory path = new address[](2);
        path[0] = wchz;
        path[1] = address(usdc);

        uint256[] memory amounts = masterRouter.swapExactETHForTokens{value: chzAmount}(
            amountOutMin,
            path,
            false,
            address(this),
            deadline
        );

        usdcReceived = amounts[amounts.length - 1];
    }

    /**
     * @dev Approve token router and execute ERC20 → USDC swap
     */
    function _swapTokensToUSDC(
        address token,
        uint256 amount,
        uint256 amountOutMin,
        uint256 deadline
    ) internal returns (uint256 usdcReceived) {
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = address(usdc);

        IERC20(token).forceApprove(address(tokenRouter), amount);

        uint256[] memory amounts = tokenRouter.swapExactTokensForTokens(
            amount,
            amountOutMin,
            path,
            address(this),
            deadline
        );

        usdcReceived = amounts[amounts.length - 1];
    }

    /**
     * @dev Split USDC between streamer and treasury, then transfer
     * @return fee Platform fee amount
     * @return streamerAmount Amount sent to streamer
     */
    function _splitAndTransfer(
        address streamer,
        uint256 totalAmount
    ) internal returns (uint256 fee, uint256 streamerAmount) {
        fee = (totalAmount * platformFeeBps) / 10_000;
        streamerAmount = totalAmount - fee;

        if (fee > 0) {
            usdc.safeTransfer(treasury, fee);
        }
        usdc.safeTransfer(streamer, streamerAmount);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ADMIN
    // ══════════════════════════════════════════════════════════════════════════

    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        treasury = _treasury;
    }

    function setPlatformFeeBps(uint16 _feeBps) external onlyOwner {
        if (_feeBps > 10_000) revert InvalidFeeBps();
        platformFeeBps = _feeBps;
    }

    /// @notice Receive refunded CHZ from router
    receive() external payable {}
}
