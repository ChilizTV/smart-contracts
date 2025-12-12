// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {StreamWallet} from "./StreamWallet.sol";
import {IStreamWalletInit} from "../interfaces/IStreamWalletInit.sol";

/**
 * @title StreamWalletFactory
 * @notice Factory for deploying StreamWallet UUPS proxies for streamers
 * @dev Uses ERC1967 proxy pattern matching betting system architecture
 */
contract StreamWalletFactory is ReentrancyGuard, Ownable {

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    address private immutable streamWalletImplementation;
    mapping(address => address) public streamerWallets; // streamer => wallet
    address public treasury;
    uint16 public defaultPlatformFeeBps; // e.g., 500 = 5%

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

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Initialize the factory and deploy implementation
     * @param initialOwner The owner of the factory
     * @param treasury_ The platform treasury address
     * @param defaultPlatformFeeBps_ Default platform fee in basis points
     */
    constructor(
        address initialOwner,
        address treasury_,
        uint16 defaultPlatformFeeBps_
    ) Ownable(initialOwner) {
        if (treasury_ == address(0)) revert InvalidAddress();
        if (defaultPlatformFeeBps_ > 10_000) revert InvalidFeeBps();

        streamWalletImplementation = address(new StreamWallet());
        treasury = treasury_;
        defaultPlatformFeeBps = defaultPlatformFeeBps_;
    }

    /*//////////////////////////////////////////////////////////////
                           SUBSCRIPTION LOGIC
    //////////////////////////////////////////////////////////////**/

    /**
     * @notice Subscribe to a streamer (creates wallet if needed)
     * @param streamer The streamer address
     * @param duration The subscription duration in seconds
     * @return wallet The StreamWallet address
     */
    function subscribeToStream(
        address streamer,
        uint256 duration
    ) external payable nonReentrant returns (address wallet) {
        uint256 amount = msg.value;
        if (amount == 0) revert InvalidAmount();
        if (duration == 0) revert InvalidDuration();
        if (streamer == address(0)) revert InvalidAddress();

        // Get or create wallet
        wallet = streamerWallets[streamer];
        if (wallet == address(0)) {
            wallet = _deployStreamWallet(streamer);
            streamerWallets[streamer] = wallet;
        }

        // Record subscription and split payment (forward CHZ to wallet)
        StreamWallet(payable(wallet)).recordSubscription{value: amount}(msg.sender, amount, duration);

        emit SubscriptionProcessed(streamer, msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                            DONATION LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Send a donation to a streamer (creates wallet if needed)
     * @param streamer The streamer address
     * @param message Optional message from donor
     * @return wallet The StreamWallet address
     */
    function donateToStream(
        address streamer,
        string calldata message
    ) external payable nonReentrant returns (address wallet) {
        uint256 amount = msg.value;
        if (amount == 0) revert InvalidAmount();
        if (streamer == address(0)) revert InvalidAddress();

        // Get or create wallet
        wallet = streamerWallets[streamer];
        if (wallet == address(0)) {
            wallet = _deployStreamWallet(streamer);
            streamerWallets[streamer] = wallet;
        }

        // Process donation through wallet (forward CHZ)
        StreamWallet(payable(wallet)).donate{value: amount}(amount, message);

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
            defaultPlatformFeeBps
        );
        // Deploy ERC1967 UUPS proxy
        wallet = address(new ERC1967Proxy(streamWalletImplementation, initData));

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
        return streamWalletImplementation;
    }
}
