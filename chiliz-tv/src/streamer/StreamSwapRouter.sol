// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IKayenMasterRouterV2} from "../interfaces/IKayenMasterRouterV2.sol";

/**
 * @title StreamSwapRouter
 * @notice Swaps native CHZ to USDC via Kayen DEX for streaming donations and subscriptions
 * @dev This contract handles CHZ→USDC swap and forwards USDC to the recipient (streamer/treasury).
 *      The streaming system (StreamWallet) currently operates in native CHZ. This router
 *      provides an alternative USDC path where USDC is sent directly to the streamer/treasury.
 *
 * Frontend Integration Notes:
 * - Call `donateWithCHZ{value: chzAmount}(streamer, message, minUSDCOut, deadline)` 
 * - Call `subscribeWithCHZ{value: chzAmount}(streamer, duration, minUSDCOut, deadline)`
 * - `minUSDCOut`: minimum USDC to accept (6 decimals, slippage protection)
 * - `deadline`: unix timestamp for swap expiry
 * - Build path: [WCHZ_ADDRESS, USDC_ADDRESS]
 */
contract StreamSwapRouter is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    IKayenMasterRouterV2 public immutable router;
    IERC20 public immutable usdc;
    address public immutable wchz;

    /// @notice Platform treasury for fee collection
    address public treasury;
    
    /// @notice Platform fee in basis points (e.g., 500 = 5%)
    uint16 public platformFeeBps;

    event DonationWithCHZ(
        address indexed donor,
        address indexed streamer,
        uint256 chzSpent,
        uint256 usdcDonated,
        uint256 platformFee,
        string message
    );

    event SubscriptionWithCHZ(
        address indexed subscriber,
        address indexed streamer,
        uint256 chzSpent,
        uint256 usdcPaid,
        uint256 platformFee,
        uint256 duration
    );

    error ZeroAddress();
    error ZeroValue();
    error DeadlinePassed();
    error InvalidFeeBps();

    constructor(
        address _router,
        address _usdc,
        address _wchz,
        address _treasury,
        uint16 _platformFeeBps
    ) Ownable(msg.sender) {
        if (_router == address(0) || _usdc == address(0) || _wchz == address(0) || _treasury == address(0)) {
            revert ZeroAddress();
        }
        if (_platformFeeBps > 10_000) revert InvalidFeeBps();
        router = IKayenMasterRouterV2(_router);
        usdc = IERC20(_usdc);
        wchz = _wchz;
        treasury = _treasury;
        platformFeeBps = _platformFeeBps;
    }

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

        // Split between streamer and treasury
        uint256 fee = (usdcReceived * platformFeeBps) / 10_000;
        uint256 streamerAmount = usdcReceived - fee;

        if (fee > 0) {
            usdc.safeTransfer(treasury, fee);
        }
        usdc.safeTransfer(streamer, streamerAmount);

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

        // Split between streamer and treasury
        uint256 fee = (usdcReceived * platformFeeBps) / 10_000;
        uint256 streamerAmount = usdcReceived - fee;

        if (fee > 0) {
            usdc.safeTransfer(treasury, fee);
        }
        usdc.safeTransfer(streamer, streamerAmount);

        emit SubscriptionWithCHZ(msg.sender, streamer, msg.value, usdcReceived, fee, duration);
    }

    /**
     * @dev Swap exact CHZ to USDC via Kayen router
     */
    function _swapCHZToUSDC(
        uint256 chzAmount,
        uint256 amountOutMin,
        uint256 deadline
    ) internal returns (uint256 usdcReceived) {
        address[] memory path = new address[](2);
        path[0] = wchz;
        path[1] = address(usdc);

        uint256[] memory amounts = router.swapExactETHForTokens{value: chzAmount}(
            amountOutMin,
            path,
            false,
            address(this),
            deadline
        );

        usdcReceived = amounts[amounts.length - 1];
    }

    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        treasury = _treasury;
    }

    function setPlatformFeeBps(uint16 _feeBps) external onlyOwner {
        if (_feeBps > 10_000) revert InvalidFeeBps();
        platformFeeBps = _feeBps;
    }

    receive() external payable {}
}
