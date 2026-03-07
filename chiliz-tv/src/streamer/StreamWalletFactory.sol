// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {StreamWallet} from "./StreamWallet.sol";
import {IStreamWalletInit} from "../interfaces/IStreamWalletInit.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title StreamWalletFactory
 * @notice Factory for deploying StreamWallet UUPS proxies for streamers
 * @dev Uses ERC1967 proxy pattern matching betting system architecture
 */
contract StreamWalletFactory is ReentrancyGuard, Ownable {

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    address private immutable STREAM_WALLET_IMPLEMENTATION;
    mapping(address => address) public streamerWallets; // streamer => wallet
    address public treasury;
    uint16 public defaultPlatformFeeBps; // e.g., 500 = 5%
    address public kayenRouter;
    address public usdc;
    address public swapRouter;

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

    event KayenRouterUpdated(address indexed oldRouter, address indexed newRouter);

    event UsdcUpdated(address indexed oldUsdc, address indexed newUsdc);

    event SwapRouterUpdated(address indexed oldRouter, address indexed newRouter);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidAmount();
    error InvalidDuration();
    error InvalidAddress();
    error InvalidFeeBps();
    error WalletAlreadyExists();
    error Unauthorized();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Initialize the factory and deploy implementation
     * @param initialOwner The owner of the factory
     * @param treasury_ The platform treasury address
     * @param defaultPlatformFeeBps_ Default platform fee in basis points
     * @param kayenRouter_ The Kayen DEX router address
     * @param usdc_ The USDC token address
     */
    constructor(
        address initialOwner,
        address treasury_,
        uint16 defaultPlatformFeeBps_,
        address kayenRouter_,
        address usdc_
    ) Ownable(initialOwner) {
        if (treasury_ == address(0)) revert InvalidAddress();
        if (defaultPlatformFeeBps_ > 10_000) revert InvalidFeeBps();

        STREAM_WALLET_IMPLEMENTATION = address(new StreamWallet());
        treasury = treasury_;
        defaultPlatformFeeBps = defaultPlatformFeeBps_;
        kayenRouter = kayenRouter_;
        usdc = usdc_;
    }

    /*//////////////////////////////////////////////////////////////
                           SUBSCRIPTION LOGIC
    //////////////////////////////////////////////////////////////**/

    /**
     * @notice Subscribe to a streamer (creates wallet if needed)
     * @param streamer The streamer address
     * @param duration The subscription duration in seconds
     * @param amount The token amount for subscription
     * @param token The ERC20 token address to use for payment (swapped to USDC)
     * @return wallet The StreamWallet address
     */
    function subscribeToStream(
        address streamer,
        uint256 duration,
        uint256 amount,
        address token
    ) external nonReentrant returns (address wallet) {
        if (amount == 0) revert InvalidAmount();
        if (duration == 0) revert InvalidDuration();
        if (streamer == address(0)) revert InvalidAddress();

        // Transfer tokens from subscriber to this contract
        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "Token transfer failed");

        // Get or create wallet
        wallet = streamerWallets[streamer];
        if (wallet == address(0)) {
            wallet = _deployStreamWallet(streamer);
            streamerWallets[streamer] = wallet;
        }

        // Approve StreamWallet to pull tokens
        require(IERC20(token).approve(wallet, amount), "Approval failed");

        // Record subscription (wallet pulls tokens and swaps to USDC)
        StreamWallet(payable(wallet)).recordSubscription(msg.sender, amount, duration, 0, token);

        emit SubscriptionProcessed(streamer, msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                            DONATION LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Send a donation to a streamer (creates wallet if needed)
     * @param streamer The streamer address
     * @param message Optional message from donor
     * @param amount The token amount for donation
     * @param token The ERC20 token address to use for payment (swapped to USDC)
     * @return wallet The StreamWallet address
     */
    function donateToStream(
        address streamer,
        string calldata message,
        uint256 amount,
        address token
    ) external nonReentrant returns (address wallet) {
        if (amount == 0) revert InvalidAmount();
        if (streamer == address(0)) revert InvalidAddress();

        // Transfer tokens from donor to this contract
        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "Token transfer failed");

        // Get or create wallet
        wallet = streamerWallets[streamer];
        if (wallet == address(0)) {
            wallet = _deployStreamWallet(streamer);
            streamerWallets[streamer] = wallet;
        }

        // Approve StreamWallet to pull tokens
        require(IERC20(token).approve(wallet, amount), "Approval failed");

        // Process donation through wallet (wallet pulls tokens and swaps to USDC)
        StreamWallet(payable(wallet)).donateFor(msg.sender, amount, message, 0, token);

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
        // Prepare initialization data
        bytes memory initData = abi.encodeWithSelector(
            IStreamWalletInit.initialize.selector,
            streamer,
            treasury,
            defaultPlatformFeeBps,
            kayenRouter,
            usdc
        );
        // Deploy ERC1967 UUPS proxy
        wallet = address(new ERC1967Proxy(STREAM_WALLET_IMPLEMENTATION, initData));

        // Set swap router on the new wallet if configured
        if (swapRouter != address(0)) {
            StreamWallet(payable(wallet)).setSwapRouter(swapRouter);
        }

        emit StreamWalletCreated(streamer, wallet);
 
    }

    /**
     * @notice Get or create a StreamWallet for a streamer
     * @dev Used by ChilizSwapRouter to ensure a wallet exists before recording
     * @param streamer The streamer address
     * @return wallet The StreamWallet proxy address
     */
    function getOrCreateWallet(address streamer) external returns (address wallet) {
        if (msg.sender != owner() && msg.sender != swapRouter) revert Unauthorized();
        if (streamer == address(0)) revert InvalidAddress();

        wallet = streamerWallets[streamer];
        if (wallet == address(0)) {
            wallet = _deployStreamWallet(streamer);
            streamerWallets[streamer] = wallet;
        }
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

    /**
     * @notice Update the Kayen DEX router address
     * @param newRouter The new router address
     */
    function setKayenRouter(address newRouter) external onlyOwner {
        if (newRouter == address(0)) revert InvalidAddress();

        address oldRouter = kayenRouter;
        kayenRouter = newRouter;

        emit KayenRouterUpdated(oldRouter, newRouter);
    }

    /**
     * @notice Update the USDC token address
     * @param newUsdc The new USDC address
     */
    function setUsdc(address newUsdc) external onlyOwner {
        if (newUsdc == address(0)) revert InvalidAddress();

        address oldUsdc = usdc;
        usdc = newUsdc;

        emit UsdcUpdated(oldUsdc, newUsdc);
    }

    /**
     * @notice Update the authorized swap router address
     * @param _swapRouter The ChilizSwapRouter address
     */
    function setSwapRouter(address _swapRouter) external onlyOwner {
        if (_swapRouter == address(0)) revert InvalidAddress();

        address oldRouter = swapRouter;
        swapRouter = _swapRouter;

        emit SwapRouterUpdated(oldRouter, _swapRouter);
    }

    /**
     * @notice Get the wallet address for a streamer
     * @param streamer The streamer address
     * @return wallet The wallet address (address(0) if not deployed)
     */
    function getWallet(address streamer) external view returns (address) {
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

    /**
     * @notice Get current implementation address
     * @return Current StreamWallet implementation
     */
    function implementation() external view returns (address) {
        return STREAM_WALLET_IMPLEMENTATION;
    }
}
