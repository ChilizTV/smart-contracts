// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
    address public fanToken;
    address public usdc;

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

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error OnlyFactory();
    error OnlyStreamer();
    error InvalidAmount();
    error InvalidDuration();
    error InsufficientBalance();
    error SwapSlippageExceeded();

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

    function _onlyFactory() internal view {
        if (msg.sender != factory) revert OnlyFactory();
    }

    function _onlyStreamer() internal view {
        if (msg.sender != streamer) revert OnlyStreamer();
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
     * @param fanToken_ The fan token (ERC20) address
     * @param usdc_ The USDC token address
     */
    function initialize(
        address streamer_,
        address treasury_,
        uint16 platformFeeBps_,
        address kayenRouter_,
        address fanToken_,
        address usdc_
    ) external initializer {
        __Ownable_init(streamer_);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        streamer = streamer_;
        treasury = treasury_;
        platformFeeBps = platformFeeBps_;
        factory = msg.sender;
        kayenRouter = kayenRouter_;
        fanToken = fanToken_;
        usdc = usdc_;
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
     * @return platformFee The fee portion in fan tokens
     * @return streamerAmount The streamer portion in fan tokens
     */
    function recordSubscription(
        address subscriber,
        uint256 amount,
        uint256 duration,
        uint256 amountOutMin
    )
        external
        onlyFactory
        nonReentrant
        returns (uint256 platformFee, uint256 streamerAmount)
    {
        if (amount == 0) revert InvalidAmount();
        if (duration == 0) revert InvalidDuration();

        // Pull fan tokens from factory
        require(IERC20(fanToken).transferFrom(msg.sender, address(this), amount), "Fan token transfer failed");

        // Calculate split
        platformFee = (amount * platformFeeBps) / 10_000;
        streamerAmount = amount - platformFee;

        // Update subscription
        Subscription storage sub = subscriptions[subscriber];
        uint256 expiryTime;
        if (sub.active && sub.expiryTime > block.timestamp) {
            // Extend from current expiry (don't lose remaining time)
            expiryTime = sub.expiryTime + duration;
        } else {
            // New subscription or expired — start from now
            expiryTime = block.timestamp + duration;
        }

        if (!sub.active) {
            totalSubscribers++;
        }

        sub.amount += amount;
        sub.startTime = sub.active ? sub.startTime : block.timestamp;
        sub.expiryTime = expiryTime;
        sub.active = true;

        // Update metrics
        totalRevenue += amount;

        // Approve router if needed
        _ensureRouterApproval(amount);

        address[] memory path = new address[](2);
        path[0] = fanToken;
        path[1] = usdc;

        // Swap platform fee portion to USDC and send to treasury
        if (platformFee > 0) {
            IKayenRouter(kayenRouter).swapExactTokensForTokens(
                platformFee,
                0,
                path,
                treasury,
                block.timestamp
            );
            emit PlatformFeeCollected(platformFee, treasury);
        }

        // Swap streamer portion to USDC and send to streamer
        uint256[] memory amounts = IKayenRouter(kayenRouter).swapExactTokensForTokens(
            streamerAmount,
            0,
            path,
            streamer,
            block.timestamp
        );

        // Verify slippage on streamer's USDC output
        if (amountOutMin > 0 && amounts[amounts.length - 1] < amountOutMin) revert SwapSlippageExceeded();

        emit SubscriptionRecorded(subscriber, amount, duration, expiryTime);
    }

    /*//////////////////////////////////////////////////////////////
                            DONATION LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Accept a donation with optional message
     * @param amount The donation amount in fan tokens
     * @param message Optional message from donor
     * @param amountOutMin Minimum USDC to receive from swap (slippage protection)
     * @return platformFee The fee portion in fan tokens
     * @return streamerAmount The streamer portion in fan tokens
     */
    function donate(
        uint256 amount,
        string calldata message,
        uint256 amountOutMin
    )
        external
        nonReentrant
        returns (uint256 platformFee, uint256 streamerAmount)
    {
        if (amount == 0) revert InvalidAmount();

        // Pull fan tokens from sender
        require(IERC20(fanToken).transferFrom(msg.sender, address(this), amount), "Fan token transfer failed");

        // Calculate split
        platformFee = (amount * platformFeeBps) / 10_000;
        streamerAmount = amount - platformFee;

        // Update metrics
        lifetimeDonations[msg.sender] += amount;
        totalRevenue += amount;

        // Approve router if needed
        _ensureRouterApproval(amount);

        address[] memory path = new address[](2);
        path[0] = fanToken;
        path[1] = usdc;

        // Swap platform fee portion to USDC and send to treasury
        if (platformFee > 0) {
            IKayenRouter(kayenRouter).swapExactTokensForTokens(
                platformFee,
                0,
                path,
                treasury,
                block.timestamp
            );
            emit PlatformFeeCollected(platformFee, treasury);
        }

        // Swap streamer portion to USDC and send to streamer
        uint256[] memory amounts = IKayenRouter(kayenRouter).swapExactTokensForTokens(
            streamerAmount,
            0,
            path,
            streamer,
            block.timestamp
        );

        // Verify slippage
        if (amountOutMin > 0 && amounts[amounts.length - 1] < amountOutMin) revert SwapSlippageExceeded();

        emit DonationReceived(
            msg.sender,
            amount,
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
        require(IERC20(usdc).transfer(streamer, amount), "USDC transfer failed");

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
     * @notice Ensure the Kayen router has sufficient approval to spend fan tokens
     * @param amount The minimum approval needed
     */
    function _ensureRouterApproval(uint256 amount) internal {
        uint256 currentAllowance = IERC20(fanToken).allowance(address(this), kayenRouter);
        if (currentAllowance < amount) {
            require(IERC20(fanToken).approve(kayenRouter, type(uint256).max), "Router approval failed");
        }
    }

    /*//////////////////////////////////////////////////////////////
                              UUPS UPGRADE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Authorize upgrade (only streamer/owner can upgrade)
     * @param newImplementation The new implementation address
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
