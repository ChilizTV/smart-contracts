// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IKayenMasterRouterV2} from "../interfaces/IKayenMasterRouterV2.sol";
import {IKayenRouter} from "../interfaces/IKayenRouter.sol";
import {BettingMatch} from "../betting/BettingMatch.sol";

/**
 * @title BettingSwapRouter
 * @notice Universal swap-and-bet router: accepts CHZ (native), WCHZ, fan tokens, or any ERC20,
 *         swaps to USDC via Kayen DEX, and places the bet on a BettingMatch contract.
 * @dev Users can bet with ANY token. The router always converts to USDC first.
 * 
 * Supported Payment Paths:
 * - CHZ (native) → USDC → BettingMatch.placeBetUSDCFor  (placeBetWithCHZ)
 * - WCHZ (ERC20) → USDC → BettingMatch.placeBetUSDCFor  (placeBetWithToken)
 * - Fan Token    → USDC → BettingMatch.placeBetUSDCFor  (placeBetWithToken)
 * - Any ERC20    → USDC → BettingMatch.placeBetUSDCFor  (placeBetWithToken)
 * - USDC direct  → BettingMatch.placeBetUSDCFor          (placeBetWithUSDC, no swap)
 * 
 * Frontend Integration Notes:
 * - Native CHZ:  `placeBetWithCHZ{value: chzAmount}(matchAddr, marketId, selection, minUSDCOut, deadline)`
 * - ERC20 token: `placeBetWithToken(tokenAddr, amount, matchAddr, marketId, selection, minUSDCOut, deadline)`
 *   (caller must approve this contract first)
 * - USDC direct: `placeBetWithUSDC(matchAddr, marketId, selection, amount)`
 *   (caller must approve this contract first, no swap involved)
 * - Build path: for multi-hop, pass custom path ending in USDC
 * - Transaction state: check for BetPlacedViaCHZ / BetPlacedViaToken / BetPlacedWithUSDC events
 * 
 * Security Notes:
 * - This contract requires SWAP_ROUTER_ROLE on target BettingMatch contracts
 * - All USDC flows through this contract but is immediately forwarded (no holding)
 * - Reentrancy protected via OpenZeppelin ReentrancyGuard
 */
contract BettingSwapRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Kayen DEX master router (for native CHZ swaps)
    IKayenMasterRouterV2 public immutable masterRouter;

    /// @notice Kayen DEX token router (for ERC20-to-ERC20 swaps)
    IKayenRouter public immutable tokenRouter;

    /// @notice USDC token address
    IERC20 public immutable usdc;

    /// @notice Wrapped CHZ (WCHZ) address used as path[0] for native CHZ swaps
    address public immutable wchz;

    /// @notice Emitted when a bet is placed via native CHZ swap
    event BetPlacedViaCHZ(
        address indexed bettingMatch,
        address indexed user,
        uint256 chzSpent,
        uint256 usdcReceived,
        uint256 marketId,
        uint64 selection
    );

    /// @notice Emitted when a bet is placed via ERC20 token swap
    event BetPlacedViaToken(
        address indexed bettingMatch,
        address indexed user,
        address indexed token,
        uint256 tokenSpent,
        uint256 usdcReceived,
        uint256 marketId,
        uint64 selection
    );

    /// @notice Emitted when a bet is placed directly with USDC (no swap)
    event BetPlacedWithUSDC(
        address indexed bettingMatch,
        address indexed user,
        uint256 amount,
        uint256 marketId,
        uint64 selection
    );

    error ZeroAddress();
    error ZeroValue();
    error SwapFailed();
    error DeadlinePassed();
    error InvalidPath();
    error TokenIsUSDC();

    constructor(address _masterRouter, address _tokenRouter, address _usdc, address _wchz) {
        if (_masterRouter == address(0) || _tokenRouter == address(0) 
            || _usdc == address(0) || _wchz == address(0)) revert ZeroAddress();
        masterRouter = IKayenMasterRouterV2(_masterRouter);
        tokenRouter = IKayenRouter(_tokenRouter);
        usdc = IERC20(_usdc);
        wchz = _wchz;
    }

    // ══════════════════════════════════════════════════════════════════════════
    // NATIVE CHZ → USDC → BET
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Swap exact native CHZ for USDC and place a USDC bet
     * @param bettingMatch Address of the BettingMatch proxy
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

        // Swap CHZ to USDC via Kayen master router
        uint256[] memory amounts = masterRouter.swapExactETHForTokens{value: msg.value}(
            amountOutMin,
            path,
            false, // receive as ERC20 (not unwrapped)
            address(this), // USDC comes to this contract first
            deadline
        );

        uint256 usdcReceived = amounts[amounts.length - 1];

        // Place the USDC bet on behalf of user
        _placeBetOnBehalf(bettingMatch, marketId, selection, usdcReceived);

        emit BetPlacedViaCHZ(bettingMatch, msg.sender, msg.value, usdcReceived, marketId, selection);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // USDC DIRECT → BET (NO SWAP)
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Place a bet directly with USDC — no swap needed
     * @param bettingMatch Address of the BettingMatch proxy
     * @param marketId Market identifier
     * @param selection User's pick (outcome ID)
     * @param amount USDC amount to bet (caller must approve this contract first)
     */
    function placeBetWithUSDC(
        address bettingMatch,
        uint256 marketId,
        uint64 selection,
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) revert ZeroValue();
        if (bettingMatch == address(0)) revert ZeroAddress();

        // Pull USDC from user
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        // Place the USDC bet on behalf of user
        _placeBetOnBehalf(bettingMatch, marketId, selection, amount);

        emit BetPlacedWithUSDC(bettingMatch, msg.sender, amount, marketId, selection);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ERC20 (WCHZ / FAN TOKEN / ANY) → USDC → BET
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Swap any ERC20 token for USDC and place a USDC bet (direct pair: token → USDC)
     * @param token The ERC20 token to swap (WCHZ, fan token, etc.)
     * @param amount Amount of tokens to spend
     * @param bettingMatch Address of the BettingMatch proxy
     * @param marketId Market identifier
     * @param selection User's pick (outcome ID)
     * @param amountOutMin Minimum USDC to accept (slippage protection)
     * @param deadline Unix timestamp deadline for the swap
     */
    function placeBetWithToken(
        address token,
        uint256 amount,
        address bettingMatch,
        uint256 marketId,
        uint64 selection,
        uint256 amountOutMin,
        uint256 deadline
    ) external nonReentrant {
        if (amount == 0) revert ZeroValue();
        if (token == address(0) || bettingMatch == address(0)) revert ZeroAddress();
        if (token == address(usdc)) revert TokenIsUSDC();
        if (block.timestamp > deadline) revert DeadlinePassed();

        // Pull tokens from user
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Build direct swap path: token → USDC
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = address(usdc);

        uint256 usdcReceived = _swapTokensToUSDC(token, amount, path, amountOutMin, deadline);

        // Place the USDC bet on behalf of user
        _placeBetOnBehalf(bettingMatch, marketId, selection, usdcReceived);

        emit BetPlacedViaToken(bettingMatch, msg.sender, token, amount, usdcReceived, marketId, selection);
    }


    // ══════════════════════════════════════════════════════════════════════════
    // INTERNAL HELPERS
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @dev Approve token router and execute ERC20 → USDC swap
     */
    function _swapTokensToUSDC(
        address token,
        uint256 amount,
        address[] memory path,
        uint256 amountOutMin,
        uint256 deadline
    ) internal returns (uint256 usdcReceived) {
        // Approve router to spend tokens
        IERC20(token).forceApprove(address(tokenRouter), amount);

        uint256[] memory amounts = tokenRouter.swapExactTokensForTokens(
            amount,
            amountOutMin,
            path,
            address(this), // USDC arrives here
            deadline
        );

        usdcReceived = amounts[amounts.length - 1];
    }

    /**
     * @dev Transfer USDC to betting contract and place bet on behalf of user
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
