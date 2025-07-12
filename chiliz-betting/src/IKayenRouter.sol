// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
/// @notice Interface minimale compatible UniswapV2 Router
interface IKayenRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}