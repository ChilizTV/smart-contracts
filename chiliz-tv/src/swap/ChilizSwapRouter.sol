// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IKayenMasterRouterV2} from "../interfaces/IKayenMasterRouterV2.sol";
import {IKayenRouter} from "../interfaces/IKayenRouter.sol";
import {BettingMatch} from "../betting/BettingMatch.sol";
import {StreamWallet} from "../streamer/StreamWallet.sol";
import {StreamWalletFactory} from "../streamer/StreamWalletFactory.sol";

/**
 * @title ChilizSwapRouter
 * @author ChilizTV
 * @notice Unified swap router for the entire ChilizTV platform.
 *         Handles token-to-USDC swaps for **both** betting and streaming modules.
 *
 * @dev Replaces the previous BettingSwapRouter + StreamSwapRouter with a single
 *      contract that centralises all Kayen DEX interactions.
 *
 * Supported Payment Paths (all settle in USDC):
 * â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
 * BETTING:
 *   CHZ  (native) -> USDC -> BettingMatch.placeBetUSDCFor  (placeBetWithCHZ)
 *   ERC20         -> USDC -> BettingMatch.placeBetUSDCFor  (placeBetWithToken)
 *   USDC direct   ->         BettingMatch.placeBetUSDCFor  (placeBetWithUSDC)
 *
 * STREAMING (donations & subscriptions):
 *   CHZ  (native) -> USDC -> fee split -> streamer / treasury
 *   ERC20         -> USDC -> fee split -> streamer / treasury
 *   USDC direct   ->         fee split -> streamer / treasury
 *
 * Security Notes:
 *   - This contract requires SWAP_ROUTER_ROLE on each target BettingMatch proxy
 *   - All USDC flows through this contract but is immediately forwarded (no holding)
 *   - Reentrancy protected via OpenZeppelin ReentrancyGuard
 *   - SafeERC20 used for all token transfers
 *   - Strict deadline + slippage validation on every swap
 */
contract ChilizSwapRouter is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // IMMUTABLES
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

    /// @notice Kayen DEX master router (native CHZ swaps)
    IKayenMasterRouterV2 public immutable masterRouter;

    /// @notice Kayen DEX token router (ERC20-to-ERC20 swaps)
    IKayenRouter public immutable tokenRouter;

    /// @notice USDC token address
    IERC20 public immutable usdc;

    /// @notice Wrapped CHZ (WCHZ) address
    address public immutable wchz;

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // MUTABLE STATE (streaming fee config)
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

    /// @notice Platform treasury for streaming fee collection
    address public treasury;

    /// @notice Platform fee in basis points (e.g., 500 = 5%)
    uint16 public platformFeeBps;

    /// @notice StreamWalletFactory for wallet lookup/creation
    StreamWalletFactory public streamWalletFactory;

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // EVENTS â€” BETTING
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

    event BetPlacedViaCHZ(
        address indexed bettingMatch,
        address indexed user,
        uint256 chzSpent,
        uint256 usdcReceived,
        uint256 marketId,
        uint64 selection
    );

    event BetPlacedViaToken(
        address indexed bettingMatch,
        address indexed user,
        address indexed token,
        uint256 tokenSpent,
        uint256 usdcReceived,
        uint256 marketId,
        uint64 selection
    );

    event BetPlacedWithUSDC(
        address indexed bettingMatch,
        address indexed user,
        uint256 amount,
        uint256 marketId,
        uint64 selection
    );

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // EVENTS â€” STREAMING DONATIONS
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

    event DonationWithCHZ(
        address indexed donor,
        address indexed streamer,
        uint256 chzSpent,
        uint256 usdcDonated,
        uint256 platformFee,
        string message
    );

    event DonationWithToken(
        address indexed donor,
        address indexed streamer,
        address indexed token,
        uint256 tokenSpent,
        uint256 usdcDonated,
        uint256 platformFee,
        string message
    );

    event DonationWithUSDCEvent(
        address indexed donor,
        address indexed streamer,
        uint256 amount,
        uint256 platformFee,
        string message
    );

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // EVENTS â€” STREAMING SUBSCRIPTIONS
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

    event SubscriptionWithCHZ(
        address indexed subscriber,
        address indexed streamer,
        uint256 chzSpent,
        uint256 usdcPaid,
        uint256 platformFee,
        uint256 duration
    );

    event SubscriptionWithToken(
        address indexed subscriber,
        address indexed streamer,
        address indexed token,
        uint256 tokenSpent,
        uint256 usdcPaid,
        uint256 platformFee,
        uint256 duration
    );

    event SubscriptionWithUSDCEvent(
        address indexed subscriber,
        address indexed streamer,
        uint256 amount,
        uint256 platformFee,
        uint256 duration
    );

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // ERRORS
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

    error ZeroAddress();
    error ZeroValue();
    error DeadlinePassed();
    error InvalidFeeBps();
    error TokenIsUSDC();

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // CONSTRUCTOR
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

    /**
     * @param _masterRouter Kayen MasterRouterV2 (native CHZ swaps)
     * @param _tokenRouter  Kayen token router (ERC20-to-ERC20 swaps)
     * @param _usdc         USDC token address
     * @param _wchz         Wrapped CHZ (WCHZ) address
     * @param _treasury     Platform treasury address
     * @param _platformFeeBps Platform fee in basis points (max 10 000)
     */
    constructor(
        address _masterRouter,
        address _tokenRouter,
        address _usdc,
        address _wchz,
        address _treasury,
        uint16 _platformFeeBps
    ) Ownable(msg.sender) {
        if (
            _masterRouter == address(0) || _tokenRouter == address(0)
                || _usdc == address(0) || _wchz == address(0) || _treasury == address(0)
        ) revert ZeroAddress();
        if (_platformFeeBps > 10_000) revert InvalidFeeBps();

        masterRouter = IKayenMasterRouterV2(_masterRouter);
        tokenRouter = IKayenRouter(_tokenRouter);
        usdc = IERC20(_usdc);
        wchz = _wchz;
        treasury = _treasury;
        platformFeeBps = _platformFeeBps;
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // BETTING â€” NATIVE CHZ -> USDC -> BET
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

    /**
     * @notice Swap exact native CHZ for USDC and place a USDC bet
     * @param bettingMatch Address of the BettingMatch proxy
     * @param marketId     Market identifier
     * @param selection    User's pick (outcome ID)
     * @param amountOutMin Minimum USDC to accept (slippage protection)
     * @param deadline     Unix timestamp deadline for the swap
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

        uint256 usdcReceived = _swapCHZToUSDC(msg.value, amountOutMin, deadline);
        _placeBetOnBehalf(bettingMatch, marketId, selection, usdcReceived);

        emit BetPlacedViaCHZ(bettingMatch, msg.sender, msg.value, usdcReceived, marketId, selection);
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // BETTING â€” USDC DIRECT -> BET (NO SWAP)
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

    /**
     * @notice Place a bet directly with USDC (no swap needed)
     * @param bettingMatch Address of the BettingMatch proxy
     * @param marketId     Market identifier
     * @param selection    User's pick (outcome ID)
     * @param amount       USDC amount to bet (caller must approve first)
     */
    function placeBetWithUSDC(
        address bettingMatch,
        uint256 marketId,
        uint64 selection,
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) revert ZeroValue();
        if (bettingMatch == address(0)) revert ZeroAddress();

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        _placeBetOnBehalf(bettingMatch, marketId, selection, amount);

        
        emit BetPlacedWithUSDC(bettingMatch, msg.sender, amount, marketId, selection);
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // BETTING â€” ERC20 TOKEN -> USDC -> BET
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

    /**
     * @notice Swap any ERC20 token for USDC and place a USDC bet
     * @param token        ERC20 token to swap (WCHZ, fan token, etc.)
     * @param amount       Amount of tokens to spend
     * @param bettingMatch Address of the BettingMatch proxy
     * @param marketId     Market identifier
     * @param selection    User's pick (outcome ID)
     * @param amountOutMin Minimum USDC to accept (slippage protection)
     * @param deadline     Unix timestamp for swap expiry
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

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 usdcReceived = _swapTokensToUSDC(token, amount, amountOutMin, deadline);
        _placeBetOnBehalf(bettingMatch, marketId, selection, usdcReceived);

        emit BetPlacedViaToken(bettingMatch, msg.sender, token, amount, usdcReceived, marketId, selection);
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // STREAMING â€” NATIVE CHZ -> USDC -> DONATE / SUBSCRIBE
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

    /**
     * @notice Donate to a streamer: swap CHZ -> USDC and send to streamer/treasury
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
        (uint256 fee, uint256 streamerAmt) = _splitAndTransfer(streamer, usdcReceived);

        // Record donation in StreamWallet
        _recordDonation(streamer, msg.sender, usdcReceived, fee, streamerAmt, message);

        emit DonationWithCHZ(msg.sender, streamer, msg.value, usdcReceived, fee, message);
    }

    /**
     * @notice Subscribe to a streamer: swap CHZ -> USDC and send to streamer/treasury
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

        // Record subscription in StreamWallet
        _recordSubscription(streamer, msg.sender, usdcReceived, duration);

        emit SubscriptionWithCHZ(msg.sender, streamer, msg.value, usdcReceived, fee, duration);
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // STREAMING â€” USDC DIRECT -> DONATE / SUBSCRIBE (NO SWAP)
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

    /**
     * @notice Donate to a streamer directly with USDC (no swap)
     */
    function donateWithUSDC(
        address streamer,
        string calldata message,
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) revert ZeroValue();
        if (streamer == address(0)) revert ZeroAddress();

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        (uint256 fee, uint256 streamerAmt) = _splitAndTransfer(streamer, amount);

        // Record donation in StreamWallet
        _recordDonation(streamer, msg.sender, amount, fee, streamerAmt, message);

        emit DonationWithUSDCEvent(msg.sender, streamer, amount, fee, message);
    }

    /**
     * @notice Subscribe to a streamer directly with USDC (no swap)
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

        // Record subscription in StreamWallet
        _recordSubscription(streamer, msg.sender, amount, duration);

        emit SubscriptionWithUSDCEvent(msg.sender, streamer, amount, fee, duration);
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // STREAMING â€” ERC20 TOKEN -> USDC -> DONATE / SUBSCRIBE
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

    /**
     * @notice Donate to a streamer: swap any ERC20 -> USDC and send to streamer/treasury
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
        (uint256 fee, uint256 streamerAmt) = _splitAndTransfer(streamer, usdcReceived);

        // Record donation in StreamWallet
        _recordDonation(streamer, msg.sender, usdcReceived, fee, streamerAmt, message);

        emit DonationWithToken(msg.sender, streamer, token, amount, usdcReceived, fee, message);
    }

    /**
     * @notice Subscribe to a streamer: swap any ERC20 -> USDC and send to streamer/treasury
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

        // Record subscription in StreamWallet
        _recordSubscription(streamer, msg.sender, usdcReceived, duration);

        emit SubscriptionWithToken(msg.sender, streamer, token, amount, usdcReceived, fee, duration);
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // ADMIN
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        treasury = _treasury;
    }

    function setPlatformFeeBps(uint16 _feeBps) external onlyOwner {
        if (_feeBps > 10_000) revert InvalidFeeBps();
        platformFeeBps = _feeBps;
    }

    function setStreamWalletFactory(address _factory) external onlyOwner {
        if (_factory == address(0)) revert ZeroAddress();
        streamWalletFactory = StreamWalletFactory(_factory);
    }

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // INTERNAL â€” SWAP HELPERS
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

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
     * @dev Approve token router and execute ERC20 -> USDC swap
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

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // INTERNAL â€” DELIVERY HELPERS
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

    /**
     * @dev Transfer USDC to betting contract and place bet on behalf of user
     */
    function _placeBetOnBehalf(
        address bettingMatch,
        uint256 marketId,
        uint64 selection,
        uint256 amount
    ) internal {
        usdc.safeTransfer(bettingMatch, amount);
        BettingMatch(payable(bettingMatch)).placeBetUSDCFor(msg.sender, marketId, selection, amount);
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

    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
    // INTERNAL â€” STREAM WALLET RECORDING HELPERS
    // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

    /**
     * @dev Get or create a StreamWallet and record a subscription
     */
    function _recordSubscription(
        address streamer,
        address subscriber,
        uint256 usdcAmount,
        uint256 duration
    ) internal {
        if (address(streamWalletFactory) != address(0)) {
            address wallet = streamWalletFactory.getOrCreateWallet(streamer);
            StreamWallet(payable(wallet)).recordSubscriptionByRouter(
                subscriber,
                usdcAmount,
                duration
            );
        }
    }

    /**
     * @dev Get or create a StreamWallet and record a donation
     */
    function _recordDonation(
        address streamer,
        address donor,
        uint256 usdcAmount,
        uint256 platformFee,
        uint256 streamerAmount,
        string calldata message
    ) internal {
        if (address(streamWalletFactory) != address(0)) {
            address wallet = streamWalletFactory.getOrCreateWallet(streamer);
            StreamWallet(payable(wallet)).recordDonationByRouter(
                donor,
                usdcAmount,
                platformFee,
                streamerAmount,
                message
            );
        }
    }

    /// @notice Receive refunded CHZ from router
    receive() external payable {}
}
