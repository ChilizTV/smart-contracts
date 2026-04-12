// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IKayenRouter} from "../interfaces/IKayenRouter.sol";

/**
 * @title StreamWallet
 * @notice Smart wallet for managing streaming revenue (subscriptions and donations)
 * @dev Deployed via ERC1967 UUPS proxy by StreamWalletFactory
 */
contract StreamWallet is Initializable, OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable {

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    address public streamer;
    address public treasury;
    uint16 public platformFeeBps; // basis points (e.g., 500 = 5%)
    address public factory;
    address public kayenRouter;
    address public usdc;
    address public swapRouter;

    mapping(address => Subscription) public subscriptions;
    mapping(address => uint256) public lifetimeDonations;

    uint256 public totalRevenue;
    uint256 public totalWithdrawn;
    uint256 public totalSubscribers;

    struct Subscription {
        uint256 amount;
        uint256 startTime;
        uint256 expiryTime;
        bool active;
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event SubscriptionRecorded(
        address indexed subscriber,
        uint256 amount,
        uint256 duration,
        uint256 expiryTime
    );

    event DonationReceived(
        address indexed donor,
        uint256 amount,
        string message,
        uint256 platformFee,
        uint256 streamerAmount
    );

    event RevenueWithdrawn(address indexed streamer, uint256 amount);

    event PlatformFeeCollected(uint256 amount, address indexed treasury);

    event SwapRouterUpdated(address indexed oldRouter, address indexed newRouter);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error OnlyFactory();
    error OnlyStreamer();
    error OnlyAuthorized();
    error InvalidAmount();
    error InvalidAddress();
    error InvalidDuration();
    error InvalidFeeBps();
    error InsufficientBalance();
    error SwapSlippageExceeded();
    error DeadlinePassed();

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyFactory() {
        _onlyFactory();
        _;
    }

    modifier onlyStreamer() {
        _onlyStreamer();
        _;
    }

    modifier onlyAuthorized() {
        _onlyAuthorized();
        _;
    }

    function _onlyFactory() internal view {
        if (msg.sender != factory) revert OnlyFactory();
    }

    function _onlyStreamer() internal view {
        if (msg.sender != streamer) revert OnlyStreamer();
    }

    function _onlyAuthorized() internal view {
        if (msg.sender != factory && msg.sender != swapRouter) revert OnlyAuthorized();
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize the StreamWallet
     * @param streamer_ The streamer address (owner/beneficiary)
     * @param treasury_ The platform treasury address
     * @param platformFeeBps_ Platform fee in basis points
     * @param kayenRouter_ The Kayen DEX router address
     * @param usdc_ The USDC token address
     */
    function initialize(
        address streamer_,
        address treasury_,
        uint16 platformFeeBps_,
        address kayenRouter_,
        address usdc_
    ) external initializer {
        __Ownable_init(streamer_);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        if (platformFeeBps_ > 10_000) revert InvalidFeeBps();

        streamer = streamer_;
        treasury = treasury_;
        platformFeeBps = platformFeeBps_;
        factory = msg.sender;
        kayenRouter = kayenRouter_;
        usdc = usdc_;
    }

    /*//////////////////////////////////////////////////////////////
                          SWAP ROUTER CONFIG
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set the authorized swap router address
     * @param _swapRouter The ChilizSwapRouter address
     */
    function setSwapRouter(address _swapRouter) external {
        if (msg.sender != factory && msg.sender != owner()) revert OnlyAuthorized();
        if (_swapRouter == address(0)) revert InvalidAddress();
        address old = swapRouter;
        swapRouter = _swapRouter;
        emit SwapRouterUpdated(old, _swapRouter);
    }

    /*//////////////////////////////////////////////////////////////
                           SUBSCRIPTION LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Record a subscription and distribute funds
     * @param subscriber The subscriber address
     * @param amount The subscription amount in fan tokens
     * @param duration The subscription duration in seconds
     * @param amountOutMin Minimum USDC to receive from swap (slippage protection)
     * @param token The fan token address to pull and swap
     * @return platformFee The fee portion in fan tokens
     * @return streamerAmount The streamer portion in fan tokens
     */
    function recordSubscription(
        address subscriber,
        uint256 amount,
        uint256 duration,
        uint256 amountOutMin,
        uint256 deadline,
        address token
    )
        external
        onlyFactory
        nonReentrant
        returns (uint256 platformFee, uint256 streamerAmount)
    {
        if (amount == 0) revert InvalidAmount();
        if (duration == 0) revert InvalidDuration();
        if (block.timestamp > deadline) revert DeadlinePassed();

        // Pull fan tokens from factory
        SafeERC20.safeTransferFrom(IERC20(token), msg.sender, address(this), amount);

        // Update subscription
        Subscription storage sub = subscriptions[subscriber];
        uint256 expiryTime;
        if (sub.active && sub.expiryTime > block.timestamp) {
            // Extend from current expiry (don't lose remaining time)
            expiryTime = sub.expiryTime + duration;
        } else {
            // New subscription or expired â€” start from now
            expiryTime = block.timestamp + duration;
        }

        if (!sub.active) {
            totalSubscribers++;
        }

        sub.startTime = sub.active ? sub.startTime : block.timestamp;
        sub.expiryTime = expiryTime;
        sub.active = true;

        // Compute fee split
        platformFee    = (amount * platformFeeBps) / 10_000;
        streamerAmount = amount - platformFee;

        // Track total amount paid (consistent with router path)
        totalRevenue += amount;
        sub.amount   += amount;

        // Approve router if needed
        _ensureRouterApproval(token, amount);

        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = usdc;

        // Swap platform fee portion to USDC and send to treasury
        if (platformFee > 0) {
            IKayenRouter(kayenRouter).swapExactTokensForTokens(
                platformFee,
                0,
                path,
                treasury,
                deadline
            );
            emit PlatformFeeCollected(platformFee, treasury);
        }

        // Swap streamer portion to USDC and send to streamer
        uint256[] memory amounts = IKayenRouter(kayenRouter).swapExactTokensForTokens(
            streamerAmount,
            0,
            path,
            streamer,
            deadline
        );

        // Verify slippage on streamer's USDC output
        uint256 streamerUsdcOut = amounts[amounts.length - 1];
        if (amountOutMin > 0 && streamerUsdcOut < amountOutMin) revert SwapSlippageExceeded();

        emit SubscriptionRecorded(subscriber, streamerUsdcOut, duration, expiryTime);
    }

    /*//////////////////////////////////////////////////////////////
                    SUBSCRIPTION LOGIC (ROUTER PATH)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Record a subscription from the swap router (swap already completed)
     * @dev Only callable by factory or authorized swap router. No token transfers
     *      or swaps occur here â€” purely state tracking.
     * @param subscriber The subscriber address
     * @param totalUsdcAmount The total USDC amount (before fee split, for metrics)
     * @param duration The subscription duration in seconds
     */
    function recordSubscriptionByRouter(
        address subscriber,
        uint256 totalUsdcAmount,
        uint256 duration
    ) external onlyAuthorized nonReentrant {
        if (totalUsdcAmount == 0) revert InvalidAmount();
        if (duration == 0) revert InvalidDuration();

        Subscription storage sub = subscriptions[subscriber];
        uint256 expiryTime;
        if (sub.active && sub.expiryTime > block.timestamp) {
            expiryTime = sub.expiryTime + duration;
        } else {
            expiryTime = block.timestamp + duration;
        }

        if (!sub.active) {
            totalSubscribers++;
        }

        sub.amount += totalUsdcAmount;
        sub.startTime = sub.active ? sub.startTime : block.timestamp;
        sub.expiryTime = expiryTime;
        sub.active = true;

        totalRevenue += totalUsdcAmount;

        emit SubscriptionRecorded(subscriber, totalUsdcAmount, duration, expiryTime);
    }

    /*//////////////////////////////////////////////////////////////
                      DONATION LOGIC (ROUTER PATH)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Record a donation from the swap router (swap already completed)
     * @dev Only callable by factory or authorized swap router. No token transfers
     *      or swaps occur here â€” purely state tracking.
     * @param donor The donor address
     * @param totalUsdcAmount The total USDC donated (before fee split, for metrics)
     * @param platformFee The actual platform fee taken by the router
     * @param streamerAmount The actual amount sent to the streamer
     * @param message Optional donation message
     */
    function recordDonationByRouter(
        address donor,
        uint256 totalUsdcAmount,
        uint256 platformFee,
        uint256 streamerAmount,
        string calldata message
    ) external onlyAuthorized nonReentrant {
        if (totalUsdcAmount == 0) revert InvalidAmount();

        lifetimeDonations[donor] += totalUsdcAmount;
        totalRevenue += totalUsdcAmount;

        emit DonationReceived(donor, totalUsdcAmount, message, platformFee, streamerAmount);
    }

    /*//////////////////////////////////////////////////////////////
                            DONATION LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Accept a donation with optional message
     * @param amount The donation amount in fan tokens
     * @param message Optional message from donor
     * @param amountOutMin Minimum USDC to receive from swap (slippage protection)
     * @param token The fan token address to pull and swap
     * @return platformFee The fee portion in fan tokens
     * @return streamerAmount The streamer portion in fan tokens
     */
    function donate(
        uint256 amount,
        string calldata message,
        uint256 amountOutMin,
        uint256 deadline,
        address token
    )
        external
        nonReentrant
        returns (uint256 platformFee, uint256 streamerAmount)
    {
        return _donateInternal(msg.sender, amount, message, amountOutMin, deadline, token);
    }

    /**
     * @notice Accept a donation on behalf of a specific donor (called by factory)
     * @param donor The actual donor address (for correct attribution)
     * @param amount The donation amount in fan tokens
     * @param message Optional message from donor
     * @param amountOutMin Minimum USDC to receive from swap (slippage protection)
     * @param token The fan token address to pull and swap
     * @return platformFee The fee portion in fan tokens
     * @return streamerAmount The streamer portion in fan tokens
     */
    function donateFor(
        address donor,
        uint256 amount,
        string calldata message,
        uint256 amountOutMin,
        uint256 deadline,
        address token
    )
        external
        onlyFactory
        nonReentrant
        returns (uint256 platformFee, uint256 streamerAmount)
    {
        return _donateInternal(donor, amount, message, amountOutMin, deadline, token);
    }

    function _donateInternal(
        address donor,
        uint256 amount,
        string calldata message,
        uint256 amountOutMin,
        uint256 deadline,
        address token
    ) internal returns (uint256 platformFee, uint256 streamerAmount) {
        if (amount == 0) revert InvalidAmount();
        if (block.timestamp > deadline) revert DeadlinePassed();

        // Pull fan tokens from caller
        SafeERC20.safeTransferFrom(IERC20(token), msg.sender, address(this), amount);

        // Approve router if needed
        _ensureRouterApproval(token, amount);

        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = usdc;

        // Swap ALL fan tokens → USDC → this contract (single swap, minimal price impact)
        uint256 totalUsdc;
        {
            uint256[] memory r = IKayenRouter(kayenRouter).swapExactTokensForTokens(
                amount, amountOutMin, path, address(this), deadline
            );
            totalUsdc = r[r.length - 1];
        }

        // Split USDC — consistent with ChilizSwapRouter fee ratio
        platformFee    = (totalUsdc * platformFeeBps) / 10_000;
        streamerAmount = totalUsdc - platformFee;

        // Update accounting (denominated in USDC)
        lifetimeDonations[donor] += totalUsdc;
        totalRevenue             += totalUsdc;

        // Transfer USDC directly — no second swap needed
        if (platformFee > 0) {
            SafeERC20.safeTransfer(IERC20(usdc), treasury, platformFee);
            emit PlatformFeeCollected(platformFee, treasury);
        }
        if (streamerAmount > 0) {
            SafeERC20.safeTransfer(IERC20(usdc), streamer, streamerAmount);
        }

        emit DonationReceived(
            donor,
            platformFee + streamerAmount,
            message,
            platformFee,
            streamerAmount
        );
    }

    /*//////////////////////////////////////////////////////////////
                           WITHDRAWAL LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Streamer withdraws accumulated revenue
     * @param amount The amount to withdraw
     */
    function withdrawRevenue(uint256 amount) external onlyStreamer nonReentrant {
        if (amount == 0) revert InvalidAmount();

        uint256 available = availableBalance();
        if (amount > available) revert InsufficientBalance();

        totalWithdrawn += amount;
        SafeERC20.safeTransfer(IERC20(usdc), streamer, amount);

        emit RevenueWithdrawn(streamer, amount);
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Check if a user has an active subscription
     * @param user The user address to check
     * @return bool True if subscription is active and not expired
     */
    function isSubscribed(address user) external view returns (bool) {
        Subscription memory sub = subscriptions[user];
        return sub.active && block.timestamp < sub.expiryTime;
    }

    /**
     * @notice Get available balance for withdrawal
     * @return uint256 The available balance
     */
    function availableBalance() public view returns (uint256) {
        return IERC20(usdc).balanceOf(address(this));
    }

    /**
     * @notice Get subscription details for a user
     * @param user The user address
     * @return Subscription struct with subscription details
     */
    function getSubscription(
        address user
    ) external view returns (Subscription memory) {
        return subscriptions[user];
    }

    /**
     * @notice Get lifetime donation amount from a donor
     * @param donor The donor address
     * @return uint256 Total donated amount
     */
    function getDonationAmount(address donor) external view returns (uint256) {
        return lifetimeDonations[donor];
    }

    /*//////////////////////////////////////////////////////////////
                             INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Ensure the Kayen router has sufficient approval to spend a given fan token
     * @param token The fan token to approve
     * @param amount The minimum approval needed
     */
    function _ensureRouterApproval(address token, uint256 amount) internal {
        uint256 currentAllowance = IERC20(token).allowance(address(this), kayenRouter);
        if (currentAllowance < amount) {
            SafeERC20.forceApprove(IERC20(token), kayenRouter, type(uint256).max);
        }
    }

    /*//////////////////////////////////////////////////////////////
                              UUPS UPGRADE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Authorize upgrade — only the factory (platform admin) can upgrade wallets.
     * @dev Prevents streamers from upgrading their own wallet to a malicious implementation
     *      that could steal subscriber funds or bypass fee enforcement.
     *      Upgrades must go through StreamWalletFactory.upgradeWallet().
     */
    function _authorizeUpgrade(address) internal view override {
        if (msg.sender != factory) revert OnlyFactory();
    }
}
