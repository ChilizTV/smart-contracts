// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {StreamWallet} from "./StreamWallet.sol";
import {StreamBeaconRegistry} from "./StreamBeaconRegistry.sol";
import {IStreamWalletInit} from "../interfaces/IStreamWalletInit.sol";

/**
 * @title StreamWalletFactory
 * @notice Factory for deploying StreamWallet proxies for streamers
 * @dev Uses BeaconProxy pattern via StreamBeaconRegistry for upgradeability
 */
contract StreamWalletFactory is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    StreamBeaconRegistry public immutable registry;
    mapping(address => address) public streamerWallets; // streamer => wallet
    address public treasury;
    uint16 public defaultPlatformFeeBps; // e.g., 500 = 5%
    IERC20 public token;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event StreamWalletCreated(
        address indexed streamer,
        address indexed wallet
    );

    event SubscriptionProcessed(
        address indexed streamer,
        address indexed subscriber,
        uint256 amount
    );

    event DonationProcessed(
        address indexed streamer,
        address indexed donor,
        uint256 amount,
        string message
    );

    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    event PlatformFeeUpdated(uint16 oldFeeBps, uint16 newFeeBps);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidAmount();
    error InvalidDuration();
    error InvalidAddress();
    error InvalidFeeBps();
    error WalletAlreadyExists();
    error BeaconNotSet();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize the factory
     * @param initialOwner The owner of the factory
     * @param registryAddr The StreamBeaconRegistry address
     * @param token_ The payment token address
     * @param treasury_ The platform treasury address
     * @param defaultPlatformFeeBps_ Default platform fee in basis points
     */
    constructor(
        address initialOwner,
        address registryAddr,
        address token_,
        address treasury_,
        uint16 defaultPlatformFeeBps_
    ) Ownable(initialOwner) {
        if (registryAddr == address(0)) revert InvalidAddress();
        if (token_ == address(0)) revert InvalidAddress();
        if (treasury_ == address(0)) revert InvalidAddress();
        if (defaultPlatformFeeBps_ > 10_000) revert InvalidFeeBps();

        registry = StreamBeaconRegistry(registryAddr);
        token = IERC20(token_);
        treasury = treasury_;
        defaultPlatformFeeBps = defaultPlatformFeeBps_;
    }

    /*//////////////////////////////////////////////////////////////
                           SUBSCRIPTION LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Subscribe to a streamer (creates wallet if needed)
     * @param streamer The streamer address
     * @param amount The subscription amount
     * @param duration The subscription duration in seconds
     * @return wallet The StreamWallet address
     */
    function subscribeToStream(
        address streamer,
        uint256 amount,
        uint256 duration
    ) external nonReentrant returns (address wallet) {
        if (amount == 0) revert InvalidAmount();
        if (duration == 0) revert InvalidDuration();
        if (streamer == address(0)) revert InvalidAddress();

        // Get or create wallet
        wallet = streamerWallets[streamer];
        if (wallet == address(0)) {
            wallet = _deployStreamWallet(streamer);
            streamerWallets[streamer] = wallet;
        }

        // Transfer tokens from subscriber to wallet
        token.safeTransferFrom(msg.sender, wallet, amount);

        // Record subscription and split payment
        StreamWallet(wallet).recordSubscription(msg.sender, amount, duration);

        emit SubscriptionProcessed(streamer, msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                            DONATION LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Send a donation to a streamer (creates wallet if needed)
     * @param streamer The streamer address
     * @param amount The donation amount
     * @param message Optional message from donor
     * @return wallet The StreamWallet address
     */
    function donateToStream(
        address streamer,
        uint256 amount,
        string calldata message
    ) external nonReentrant returns (address wallet) {
        if (amount == 0) revert InvalidAmount();
        if (streamer == address(0)) revert InvalidAddress();

        // Get or create wallet
        wallet = streamerWallets[streamer];
        if (wallet == address(0)) {
            wallet = _deployStreamWallet(streamer);
            streamerWallets[streamer] = wallet;
        }

        // Transfer tokens from donor to this contract, then approve wallet
        token.safeTransferFrom(msg.sender, address(this), amount);
        token.forceApprove(wallet, amount);

        // Process donation through wallet
        StreamWallet(wallet).donate(amount, message);

        emit DonationProcessed(streamer, msg.sender, amount, message);
    }

    /*//////////////////////////////////////////////////////////////
                          WALLET DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploy a StreamWallet for a streamer
     * @param streamer The streamer address
     * @return wallet The deployed wallet address
     */
    function _deployStreamWallet(
        address streamer
    ) internal returns (address wallet) {
        // Get beacon from registry
        address beacon = registry.getBeacon();
        if (beacon == address(0)) revert BeaconNotSet();

        // Prepare initialization data
        bytes memory initData = abi.encodeWithSelector(
            IStreamWalletInit.initialize.selector,
            streamer,
            address(token),
            treasury,
            defaultPlatformFeeBps
        );

        // Deploy BeaconProxy
        wallet = address(new BeaconProxy(beacon, initData));

        emit StreamWalletCreated(streamer, wallet);
    }

    /**
     * @notice Manually deploy a wallet for a streamer (admin only)
     * @param streamer The streamer address
     * @return wallet The deployed wallet address
     */
    function deployWalletFor(
        address streamer
    ) external onlyOwner returns (address wallet) {
        if (streamer == address(0)) revert InvalidAddress();
        if (streamerWallets[streamer] != address(0))
            revert WalletAlreadyExists();

        wallet = _deployStreamWallet(streamer);
        streamerWallets[streamer] = wallet;
    }

    /*//////////////////////////////////////////////////////////////
                           ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Update the treasury address
     * @param newTreasury The new treasury address
     */
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert InvalidAddress();

        address oldTreasury = treasury;
        treasury = newTreasury;

        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    /**
     * @notice Update the default platform fee
     * @param newFeeBps The new fee in basis points
     */
    function setPlatformFee(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > 10_000) revert InvalidFeeBps();

        uint16 oldFeeBps = defaultPlatformFeeBps;
        defaultPlatformFeeBps = newFeeBps;

        emit PlatformFeeUpdated(oldFeeBps, newFeeBps);
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get the wallet address for a streamer
     * @param streamer The streamer address
     * @return wallet The wallet address (address(0) if not deployed)
     */
    function getWallet(address streamer) external view returns (address wallet) {
        return streamerWallets[streamer];
    }

    /**
     * @notice Check if a streamer has a wallet
     * @param streamer The streamer address
     * @return bool True if wallet exists
     */
    function hasWallet(address streamer) external view returns (bool) {
        return streamerWallets[streamer] != address(0);
    }
}
