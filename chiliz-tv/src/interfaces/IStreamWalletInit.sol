// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IStreamWalletInit
 * @notice Interface for StreamWallet initialization
 * @dev Used by StreamWalletFactory to initialize new StreamWallet proxies
 */
interface IStreamWalletInit {
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
    ) external;
}
