// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";

/**
 * @title PriceOracle
 * @author ChilizTV
 * @notice Helper library for converting CHZ amounts to USD values using Chainlink price feeds
 * @dev Implements security checks for stale prices and invalid data
 */
library PriceOracle {
    /// @notice Maximum age for price data (1 hour)
    uint256 public constant MAX_PRICE_AGE = 1 hours;

    /// @notice Thrown when price feed returns invalid data
    error InvalidPriceData();
    
    /// @notice Thrown when price data is too old
    error StalePriceData();
    
    /// @notice Thrown when price is negative or zero
    error InvalidPrice();

    /**
     * @notice Get the current CHZ/USD price from Chainlink oracle
     * @param priceFeed Chainlink price feed contract
     * @return price Current CHZ/USD price (8 decimals)
     * @dev Includes comprehensive security checks for data validity
     */
    function getPrice(AggregatorV3Interface priceFeed) internal view returns (uint256 price) {
        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();

        // Check that the round was completed
        if (answeredInRound < roundId) revert InvalidPriceData();
        
        // Check price freshness (not older than MAX_PRICE_AGE)
        if (block.timestamp - updatedAt > MAX_PRICE_AGE) revert StalePriceData();
        
        // Check price is positive
        if (answer <= 0) revert InvalidPrice();

        return uint256(answer);
    }

    /**
     * @notice Convert CHZ amount to USD value
     * @param chzAmount Amount in CHZ (18 decimals)
     * @param priceFeed Chainlink price feed contract
     * @return usdValue Value in USD (8 decimals, e.g., 500000000 = $5.00)
     * @dev Formula: (chzAmount * chzPriceUsd8decimals) / 1e18
     */
    function chzToUsd(
        uint256 chzAmount,
        AggregatorV3Interface priceFeed
    ) internal view returns (uint256 usdValue) {
        uint256 chzPriceUsd = getPrice(priceFeed);
        
        // CHZ: 18 decimals, Price: 8 decimals
        // Result: 8 decimals (standard for USD)
        return (chzAmount * chzPriceUsd) / 1e18;
    }

    /**
     * @notice Convert USD amount to CHZ value
     * @param usdAmount Amount in USD (8 decimals)
     * @param priceFeed Chainlink price feed contract
     * @return chzValue Value in CHZ (18 decimals)
     * @dev Formula: (usdAmount * 1e18) / chzPriceUsd8decimals
     */
    function usdToChz(
        uint256 usdAmount,
        AggregatorV3Interface priceFeed
    ) internal view returns (uint256 chzValue) {
        uint256 chzPriceUsd = getPrice(priceFeed);
        
        // USD: 8 decimals, Price: 8 decimals
        // Result: 18 decimals (CHZ native decimals)
        return (usdAmount * 1e18) / chzPriceUsd;
    }

    /**
     * @notice Check if CHZ amount meets minimum USD value
     * @param chzAmount Amount in CHZ (18 decimals)
     * @param minUsdValue Minimum required USD value (8 decimals)
     * @param priceFeed Chainlink price feed contract
     * @return true if amount meets or exceeds minimum, false otherwise
     */
    function meetsMinimumUsd(
        uint256 chzAmount,
        uint256 minUsdValue,
        AggregatorV3Interface priceFeed
    ) internal view returns (bool) {
        uint256 usdValue = chzToUsd(chzAmount, priceFeed);
        return usdValue >= minUsdValue;
    }
}
