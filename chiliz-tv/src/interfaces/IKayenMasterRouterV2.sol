// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title IKayenMasterRouterV2
 * @notice Interface for the FanX/Kayen DEX router on Chiliz chain
 * @dev Reference: https://github.com/FanX-Protocol/kayen-dex-contract/blob/main/src/KayenMasterRouterV2.sol
 *      path[0] must be WETH (wrapped CHZ on Chiliz)
 */
interface IKayenMasterRouterV2 {
    /**
     * @notice Swap exact native CHZ for tokens (e.g., USDC)
     * @param amountOutMin Minimum output tokens (slippage protection)
     * @param path Swap path; path[0] = WCHZ, path[last] = output token
     * @param receiveUnwrappedToken Whether to unwrap the output token
     * @param to Recipient of output tokens
     * @param deadline Unix timestamp deadline
     * @return amounts Array of amounts for each step in the path
     */
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        bool receiveUnwrappedToken,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    /**
     * @notice Swap native CHZ for exact amount of output tokens
     * @param amountOut Exact output tokens desired
     * @param path Swap path; path[0] = WCHZ, path[last] = output token
     * @param receiveUnwrappedToken Whether to unwrap the output token
     * @param to Recipient of output tokens
     * @param deadline Unix timestamp deadline
     * @return amounts Array of amounts for each step in the path
     */
    function swapETHForExactTokens(
        uint256 amountOut,
        address[] calldata path,
        bool receiveUnwrappedToken,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);
}
