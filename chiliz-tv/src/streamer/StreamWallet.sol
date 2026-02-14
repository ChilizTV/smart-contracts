// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

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
     */
    function initialize(
        address streamer_,
        address treasury_,
        uint16 platformFeeBps_
    ) external initializer {
        __Ownable_init(streamer_);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        streamer = streamer_;
        treasury = treasury_;
        platformFeeBps = platformFeeBps_;
        factory = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////
                           SUBSCRIPTION LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Record a subscription and distribute funds
     * @param subscriber The subscriber address
     * @param amount The subscription amount
     * @param duration The subscription duration in seconds
     * @return platformFee The fee sent to treasury
     * @return streamerAmount The amount sent to streamer
     */
    function recordSubscription(
        address subscriber,
        uint256 amount,
        uint256 duration
    )
        external
        payable
        onlyFactory
        nonReentrant
        returns (uint256 platformFee, uint256 streamerAmount)
    {
        if (amount == 0) revert InvalidAmount();
        if (duration == 0) revert InvalidDuration();

        // Calculate split
        platformFee = (amount * platformFeeBps) / 10_000;
        streamerAmount = amount - platformFee;

        // Update subscription
        uint256 expiryTime = block.timestamp + duration;
        Subscription storage sub = subscriptions[subscriber];

        if (!sub.active) {
            totalSubscribers++;
        }

        sub.amount = amount;
        sub.startTime = block.timestamp;
        sub.expiryTime = expiryTime;
        sub.active = true;

        // Update metrics
        totalRevenue += amount;

        // Transfer platform fee to treasury
        if (platformFee > 0) {
            (bool successTreasury, ) = treasury.call{value: platformFee}("");
            require(successTreasury, "Treasury transfer failed");
            emit PlatformFeeCollected(platformFee, treasury);
        }

        // Transfer streamer amount
        (bool successStreamer, ) = streamer.call{value: streamerAmount}("");
        require(successStreamer, "Streamer transfer failed");

        emit SubscriptionRecorded(subscriber, amount, duration, expiryTime);
    }

    /*//////////////////////////////////////////////////////////////
                            DONATION LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Accept a donation with optional message
     * @param amount The donation amount
     * @param message Optional message from donor
     * @return platformFee The fee sent to treasury
     * @return streamerAmount The amount sent to streamer
     */
    function donate(
        uint256 amount,
        string calldata message
    )
        external
        payable
        nonReentrant
        returns (uint256 platformFee, uint256 streamerAmount)
    {
        if (amount == 0) revert InvalidAmount();

        // Calculate split
        platformFee = (amount * platformFeeBps) / 10_000;
        streamerAmount = amount - platformFee;

        // Update metrics
        lifetimeDonations[msg.sender] += amount;
        totalRevenue += amount;

        // Transfer platform fee to treasury
        if (platformFee > 0) {
            (bool successTreasury, ) = treasury.call{value: platformFee}("");
            require(successTreasury, "Treasury transfer failed");
            emit PlatformFeeCollected(platformFee, treasury);
        }

        // Transfer to streamer
        (bool successStreamer, ) = streamer.call{value: streamerAmount}("");
        require(successStreamer, "Streamer transfer failed");

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
        (bool success, ) = streamer.call{value: amount}("");
        require(success, "Streamer transfer failed");

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
        return address(this).balance;
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

    /**
     * @notice Receive function to accept native CHZ
     */
    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                              UUPS UPGRADE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Authorize upgrade (only streamer/owner can upgrade)
     * @param newImplementation The new implementation address
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
