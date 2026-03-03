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
 *         Handles token-to-USDT swaps for **both** betting and streaming modules.
 *
 * @dev Replaces the previous BettingSwapRouter + StreamSwapRouter with a single
 *      contract that centralises all Kayen DEX interactions.
 *
 * Supported Payment Paths (all settle in USDT):
 * ──────────────────────────────────────────────
 * BETTING:
 *   CHZ  (native) -> USDT -> BettingMatch.placeBetUSDTFor  (placeBetWithCHZ)
 *   ERC20         -> USDT -> BettingMatch.placeBetUSDTFor  (placeBetWithToken)
 *   USDT direct   ->         BettingMatch.placeBetUSDTFor  (placeBetWithUSDT)
 *
 * STREAMING (donations & subscriptions):
 *   CHZ  (native) -> USDT -> fee split -> streamer / treasury
 *   ERC20         -> USDT -> fee split -> streamer / treasury
 *   USDT direct   ->         fee split -> streamer / treasury
 *
 * Security Notes:
 *   - This contract requires SWAP_ROUTER_ROLE on each target BettingMatch proxy
 *   - All USDT flows through this contract but is immediately forwarded (no holding)
 *   - Reentrancy protected via OpenZeppelin ReentrancyGuard
 *   - SafeERC20 used for all token transfers
 *   - Strict deadline + slippage validation on every swap
 */
contract ChilizSwapRouter is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ══════════════════════════════════════════════════════════════════════════
    // IMMUTABLES
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Kayen DEX master router (native CHZ swaps)
    IKayenMasterRouterV2 public immutable masterRouter;

    /// @notice Kayen DEX token router (ERC20-to-ERC20 swaps)
    IKayenRouter public immutable tokenRouter;

    /// @notice USDT token address
    IERC20 public immutable usdt;

    /// @notice Wrapped CHZ (WCHZ) address
    address public immutable wchz;

    // ══════════════════════════════════════════════════════════════════════════
    // MUTABLE STATE (streaming fee config)
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Platform treasury for streaming fee collection
    address public treasury;

    /// @notice Platform fee in basis points (e.g., 500 = 5%)
    uint16 public platformFeeBps;

    /// @notice StreamWalletFactory for wallet lookup/creation
    StreamWalletFactory public streamWalletFactory;

    // ══════════════════════════════════════════════════════════════════════════
    // EVENTS — BETTING
    // ══════════════════════════════════════════════════════════════════════════

    event BetPlacedViaCHZ(
        address indexed bettingMatch,
        address indexed user,
        uint256 chzSpent,
        uint256 usdtReceived,
        uint256 marketId,
        uint64 selection
    );

    event BetPlacedViaToken(
        address indexed bettingMatch,
        address indexed user,
        address indexed token,
        uint256 tokenSpent,
        uint256 usdtReceived,
        uint256 marketId,
        uint64 selection
    );

    event BetPlacedWithUSDT(
        address indexed bettingMatch,
        address indexed user,
        uint256 amount,
        uint256 marketId,
        uint64 selection
    );

    // ══════════════════════════════════════════════════════════════════════════
    // EVENTS — STREAMING DONATIONS
    // ══════════════════════════════════════════════════════════════════════════

    event DonationWithCHZ(
        address indexed donor,
        address indexed streamer,
        uint256 chzSpent,
        uint256 usdtDonated,
        uint256 platformFee,
        string message
    );

    event DonationWithToken(
        address indexed donor,
        address indexed streamer,
        address indexed token,
        uint256 tokenSpent,
        uint256 usdtDonated,
        uint256 platformFee,
        string message
    );

    event DonationWithUSDTEvent(
        address indexed donor,
        address indexed streamer,
        uint256 amount,
        uint256 platformFee,
        string message
    );

    // ══════════════════════════════════════════════════════════════════════════
    // EVENTS — STREAMING SUBSCRIPTIONS
    // ══════════════════════════════════════════════════════════════════════════

    event SubscriptionWithCHZ(
        address indexed subscriber,
        address indexed streamer,
        uint256 chzSpent,
        uint256 usdtPaid,
        uint256 platformFee,
        uint256 duration
    );

    event SubscriptionWithToken(
        address indexed subscriber,
        address indexed streamer,
        address indexed token,
        uint256 tokenSpent,
        uint256 usdtPaid,
        uint256 platformFee,
        uint256 duration
    );

    event SubscriptionWithUSDTEvent(
        address indexed subscriber,
        address indexed streamer,
        uint256 amount,
        uint256 platformFee,
        uint256 duration
    );

    // ══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ══════════════════════════════════════════════════════════════════════════

    error ZeroAddress();
    error ZeroValue();
    error DeadlinePassed();
    error InvalidFeeBps();
    error TokenIsUSDT();

    // ══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @param _masterRouter Kayen MasterRouterV2 (native CHZ swaps)
     * @param _tokenRouter  Kayen token router (ERC20-to-ERC20 swaps)
     * @param _usdt         USDT token address
     * @param _wchz         Wrapped CHZ (WCHZ) address
     * @param _treasury     Platform treasury address
     * @param _platformFeeBps Platform fee in basis points (max 10 000)
     */
    constructor(
        address _masterRouter,
        address _tokenRouter,
        address _usdt,
        address _wchz,
        address _treasury,
        uint16 _platformFeeBps
    ) Ownable(msg.sender) {
        if (
            _masterRouter == address(0) || _tokenRouter == address(0)
                || _usdt == address(0) || _wchz == address(0) || _treasury == address(0)
        ) revert ZeroAddress();
        if (_platformFeeBps > 10_000) revert InvalidFeeBps();

        masterRouter = IKayenMasterRouterV2(_masterRouter);
        tokenRouter = IKayenRouter(_tokenRouter);
        usdt = IERC20(_usdt);
        wchz = _wchz;
        treasury = _treasury;
        platformFeeBps = _platformFeeBps;
    }

    // ══════════════════════════════════════════════════════════════════════════
    // BETTING — NATIVE CHZ -> USDT -> BET
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Swap exact native CHZ for USDT and place a USDT bet
     * @param bettingMatch Address of the BettingMatch proxy
     * @param marketId     Market identifier
     * @param selection    User's pick (outcome ID)
     * @param amountOutMin Minimum USDT to accept (slippage protection)
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

        uint256 usdtReceived = _swapCHZToUSDT(msg.value, amountOutMin, deadline);
        _placeBetOnBehalf(bettingMatch, marketId, selection, usdtReceived);

        emit BetPlacedViaCHZ(bettingMatch, msg.sender, msg.value, usdtReceived, marketId, selection);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // BETTING — USDT DIRECT -> BET (NO SWAP)
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Place a bet directly with USDT (no swap needed)
     * @param bettingMatch Address of the BettingMatch proxy
     * @param marketId     Market identifier
     * @param selection    User's pick (outcome ID)
     * @param amount       USDT amount to bet (caller must approve first)
     */
    function placeBetWithUSDT(
        address bettingMatch,
        uint256 marketId,
        uint64 selection,
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) revert ZeroValue();
        if (bettingMatch == address(0)) revert ZeroAddress();

        usdt.safeTransferFrom(msg.sender, address(this), amount);
        _placeBetOnBehalf(bettingMatch, marketId, selection, amount);

        emit BetPlacedWithUSDT(bettingMatch, msg.sender, amount, marketId, selection);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // BETTING — ERC20 TOKEN -> USDT -> BET
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Swap any ERC20 token for USDT and place a USDT bet
     * @param token        ERC20 token to swap (WCHZ, fan token, etc.)
     * @param amount       Amount of tokens to spend
     * @param bettingMatch Address of the BettingMatch proxy
     * @param marketId     Market identifier
     * @param selection    User's pick (outcome ID)
     * @param amountOutMin Minimum USDT to accept (slippage protection)
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
        if (token == address(usdt)) revert TokenIsUSDT();
        if (block.timestamp > deadline) revert DeadlinePassed();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 usdtReceived = _swapTokensToUSDT(token, amount, amountOutMin, deadline);
        _placeBetOnBehalf(bettingMatch, marketId, selection, usdtReceived);

        emit BetPlacedViaToken(bettingMatch, msg.sender, token, amount, usdtReceived, marketId, selection);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // STREAMING — NATIVE CHZ -> USDT -> DONATE / SUBSCRIBE
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Donate to a streamer: swap CHZ -> USDT and send to streamer/treasury
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

        uint256 usdtReceived = _swapCHZToUSDT(msg.value, amountOutMin, deadline);
        (uint256 fee, uint256 streamerAmt) = _splitAndTransfer(streamer, usdtReceived);

        // Record donation in StreamWallet
        _recordDonation(streamer, msg.sender, usdtReceived, fee, streamerAmt, message);

        emit DonationWithCHZ(msg.sender, streamer, msg.value, usdtReceived, fee, message);
    }

    /**
     * @notice Subscribe to a streamer: swap CHZ -> USDT and send to streamer/treasury
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

        uint256 usdtReceived = _swapCHZToUSDT(msg.value, amountOutMin, deadline);
        (uint256 fee,) = _splitAndTransfer(streamer, usdtReceived);

        // Record subscription in StreamWallet
        _recordSubscription(streamer, msg.sender, usdtReceived, duration);

        emit SubscriptionWithCHZ(msg.sender, streamer, msg.value, usdtReceived, fee, duration);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // STREAMING — USDT DIRECT -> DONATE / SUBSCRIBE (NO SWAP)
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Donate to a streamer directly with USDT (no swap)
     */
    function donateWithUSDT(
        address streamer,
        string calldata message,
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) revert ZeroValue();
        if (streamer == address(0)) revert ZeroAddress();

        usdt.safeTransferFrom(msg.sender, address(this), amount);
        (uint256 fee, uint256 streamerAmt) = _splitAndTransfer(streamer, amount);

        // Record donation in StreamWallet
        _recordDonation(streamer, msg.sender, amount, fee, streamerAmt, message);

        emit DonationWithUSDTEvent(msg.sender, streamer, amount, fee, message);
    }

    /**
     * @notice Subscribe to a streamer directly with USDT (no swap)
     */
    function subscribeWithUSDT(
        address streamer,
        uint256 duration,
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) revert ZeroValue();
        if (streamer == address(0)) revert ZeroAddress();
        if (duration == 0) revert ZeroValue();

        usdt.safeTransferFrom(msg.sender, address(this), amount);
        (uint256 fee,) = _splitAndTransfer(streamer, amount);

        // Record subscription in StreamWallet
        _recordSubscription(streamer, msg.sender, amount, duration);

        emit SubscriptionWithUSDTEvent(msg.sender, streamer, amount, fee, duration);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // STREAMING — ERC20 TOKEN -> USDT -> DONATE / SUBSCRIBE
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Donate to a streamer: swap any ERC20 -> USDT and send to streamer/treasury
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
        if (token == address(usdt)) revert TokenIsUSDT();
        if (block.timestamp > deadline) revert DeadlinePassed();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 usdtReceived = _swapTokensToUSDT(token, amount, amountOutMin, deadline);
        (uint256 fee, uint256 streamerAmt) = _splitAndTransfer(streamer, usdtReceived);

        // Record donation in StreamWallet
        _recordDonation(streamer, msg.sender, usdtReceived, fee, streamerAmt, message);

        emit DonationWithToken(msg.sender, streamer, token, amount, usdtReceived, fee, message);
    }

    /**
     * @notice Subscribe to a streamer: swap any ERC20 -> USDT and send to streamer/treasury
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
        if (token == address(usdt)) revert TokenIsUSDT();
        if (duration == 0) revert ZeroValue();
        if (block.timestamp > deadline) revert DeadlinePassed();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 usdtReceived = _swapTokensToUSDT(token, amount, amountOutMin, deadline);
        (uint256 fee,) = _splitAndTransfer(streamer, usdtReceived);

        // Record subscription in StreamWallet
        _recordSubscription(streamer, msg.sender, usdtReceived, duration);

        emit SubscriptionWithToken(msg.sender, streamer, token, amount, usdtReceived, fee, duration);
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

    function setStreamWalletFactory(address _factory) external onlyOwner {
        if (_factory == address(0)) revert ZeroAddress();
        streamWalletFactory = StreamWalletFactory(_factory);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // INTERNAL — SWAP HELPERS
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @dev Swap exact native CHZ to USDT via Kayen master router
     */
    function _swapCHZToUSDT(
        uint256 chzAmount,
        uint256 amountOutMin,
        uint256 deadline
    ) internal returns (uint256 usdtReceived) {
        address[] memory path = new address[](2);
        path[0] = wchz;
        path[1] = address(usdt);

        uint256[] memory amounts = masterRouter.swapExactETHForTokens{value: chzAmount}(
            amountOutMin,
            path,
            false,
            address(this),
            deadline
        );

        usdtReceived = amounts[amounts.length - 1];
    }

    /**
     * @dev Approve token router and execute ERC20 -> USDT swap
     */
    function _swapTokensToUSDT(
        address token,
        uint256 amount,
        uint256 amountOutMin,
        uint256 deadline
    ) internal returns (uint256 usdtReceived) {
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = address(usdt);

        IERC20(token).forceApprove(address(tokenRouter), amount);

        uint256[] memory amounts = tokenRouter.swapExactTokensForTokens(
            amount,
            amountOutMin,
            path,
            address(this),
            deadline
        );

        usdtReceived = amounts[amounts.length - 1];
    }

    // ══════════════════════════════════════════════════════════════════════════
    // INTERNAL — DELIVERY HELPERS
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @dev Transfer USDT to betting contract and place bet on behalf of user
     */
    function _placeBetOnBehalf(
        address bettingMatch,
        uint256 marketId,
        uint64 selection,
        uint256 amount
    ) internal {
        usdt.safeTransfer(bettingMatch, amount);
        BettingMatch(payable(bettingMatch)).placeBetUSDTFor(msg.sender, marketId, selection, amount);
    }

    /**
     * @dev Split USDT between streamer and treasury, then transfer
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
            usdt.safeTransfer(treasury, fee);
        }
        usdt.safeTransfer(streamer, streamerAmount);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // INTERNAL — STREAM WALLET RECORDING HELPERS
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @dev Get or create a StreamWallet and record a subscription
     */
    function _recordSubscription(
        address streamer,
        address subscriber,
        uint256 usdtAmount,
        uint256 duration
    ) internal {
        if (address(streamWalletFactory) != address(0)) {
            address wallet = streamWalletFactory.getOrCreateWallet(streamer);
            StreamWallet(payable(wallet)).recordSubscriptionByRouter(
                subscriber,
                usdtAmount,
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
        uint256 usdtAmount,
        uint256 platformFee,
        uint256 streamerAmount,
        string calldata message
    ) internal {
        if (address(streamWalletFactory) != address(0)) {
            address wallet = streamWalletFactory.getOrCreateWallet(streamer);
            StreamWallet(payable(wallet)).recordDonationByRouter(
                donor,
                usdtAmount,
                platformFee,
                streamerAmount,
                message
            );
        }
    }

    /// @notice Receive refunded CHZ from router
    receive() external payable {}
}
