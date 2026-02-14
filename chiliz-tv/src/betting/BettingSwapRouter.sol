// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IKayenMasterRouterV2} from "../interfaces/IKayenMasterRouterV2.sol";
import {BettingMatch} from "../betting/BettingMatch.sol";

/**
 * @title BettingSwapRouter
 * @notice Wrapper that swaps native CHZ to USDC via Kayen DEX and places bets on BettingMatch
 * @dev Users send CHZ (native), it is swapped to USDC, then the USDC bet is placed
 *      on the target betting contract. This contract does NOT hold funds.
 * 
 * Frontend Integration Notes:
 * - Call `placeBetWithCHZ{value: chzAmount}(matchAddr, marketId, selection, minUSDCOut, deadline)`
 * - `chzAmount`: native CHZ to spend
 * - `minUSDCOut`: minimum USDC to accept (slippage protection, in 6 decimals)
 * - `deadline`: unix timestamp deadline for the swap
 * - Build path: [WCHZ_ADDRESS, USDC_ADDRESS] for direct swap
 * - Transaction state: check for BetPlacedViaCHZ event
 */
contract BettingSwapRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Kayen DEX router address
    IKayenMasterRouterV2 public immutable router;

    /// @notice USDC token address
    IERC20 public immutable usdc;

    /// @notice Wrapped CHZ (WCHZ) address used as path[0] for Kayen router
    address public immutable wchz;

    /// @notice Emitted when a bet is placed via CHZ swap
    event BetPlacedViaCHZ(
        address indexed bettingMatch,
        address indexed user,
        uint256 chzSpent,
        uint256 usdcReceived,
        uint256 marketId,
        uint64 selection
    );

    error ZeroAddress();
    error ZeroValue();
    error SwapFailed();
    error DeadlinePassed();

    constructor(address _router, address _usdc, address _wchz) {
        if (_router == address(0) || _usdc == address(0) || _wchz == address(0)) revert ZeroAddress();
        router = IKayenMasterRouterV2(_router);
        usdc = IERC20(_usdc);
        wchz = _wchz;
    }

    /**
     * @notice Swap exact CHZ for USDC and place a USDC bet
     * @param bettingMatch Address of the BettingMatch (FootballMatch/BasketballMatch) proxy
     * @param marketId Market identifier
     * @param selection User's pick (outcome ID)
     * @param amountOutMin Minimum USDC to accept (slippage protection)
     * @param deadline Unix timestamp deadline for the swap
     */
    function placeBetWithCHZ(
        address bettingMatch,
        uint256 marketId,
        uint64 selection,
        uint256 amountOutMin,
        uint256 deadline
    ) external payable nonReentrant {
        if (msg.value == 0) revert ZeroValue();
        if (block.timestamp > deadline) revert DeadlinePassed();

        // Build swap path: WCHZ -> USDC
        address[] memory path = new address[](2);
        path[0] = wchz;
        path[1] = address(usdc);

        // Swap CHZ to USDC via Kayen router
        uint256[] memory amounts = router.swapExactETHForTokens{value: msg.value}(
            amountOutMin,
            path,
            false, // receive as ERC20 (not unwrapped)
            address(this), // USDC comes to this contract first
            deadline
        );

        uint256 usdcReceived = amounts[amounts.length - 1];

        // Approve betting contract to spend USDC
        usdc.forceApprove(bettingMatch, usdcReceived);

        // Place the USDC bet on behalf of user
        // Note: placeBetUSDC uses msg.sender for the bet, but we call it from this contract.
        // The bet will be recorded for this contract. We need the betting contract to support
        // placing on behalf of users, OR we use a different approach.
        // Since BettingMatch.placeBetUSDC uses msg.sender, we transfer USDC to user 
        // and let them call it, OR we add a placeBetUSDCFor function.
        // Best approach: transfer USDC to user, user approves and calls directly.
        // However, that's 2 tx. Instead, let's transfer to user and call placeBetUSDC
        // using the betting contract directly. We'll add a `placeBetUSDCFor` function.
        
        // Transfer USDC to the user first, then have them interact
        // Actually, the cleanest approach: transfer USDC directly to betting contract
        // and call placeBetUSDCFor
        _placeBetOnBehalf(bettingMatch, marketId, selection, usdcReceived);

        emit BetPlacedViaCHZ(bettingMatch, msg.sender, msg.value, usdcReceived, marketId, selection);
    }

    /**
     * @dev Internal: place USDC bet on behalf of the original msg.sender
     */
    function _placeBetOnBehalf(
        address bettingMatch,
        uint256 marketId,
        uint64 selection,
        uint256 amount
    ) internal {
        // Transfer USDC to the betting contract directly
        usdc.safeTransfer(bettingMatch, amount);
        
        // Call placeBetUSDCFor on the betting contract
        BettingMatch(payable(bettingMatch)).placeBetUSDCFor(msg.sender, marketId, selection, amount);
    }

    /// @notice Receive refunded CHZ from router (swapETHForExactTokens may refund dust)
    receive() external payable {}
}
