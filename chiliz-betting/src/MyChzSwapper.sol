// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./IKayenRouter.sol";

/// @title MyChzSwapper
/// @notice Swaps native CHZ for FanTokens via the Kayen (UniswapV2-style) Router on Chiliz Chain
contract MyChzSwapper {
    /// @notice Router interface (UniswapV2-style) for swapping tokens
    IKayenRouter public immutable router;

    /// @notice Emitted after a successful swap
    /// @param tokenIn  Address of the input token (WCHZ or native wrapped)
    /// @param tokenOut Address of the output token (FanToken)
    /// @param amount   Amount of tokens received
    event SwappedToken(address indexed tokenIn, address indexed tokenOut, uint256 amount);

    /// @param _router Address of the Kayen Router contract
    constructor(address _router) {
        require(_router != address(0), "Router address cannot be zero");
        router = IKayenRouter(_router);
    }

    /// @notice Swaps native CHZ for a FanToken
    /// @dev User must send native CHZ as msg.value; the router handles wrapping and swapping
    /// @param amountOutMin Minimum amount of FanToken expected (slippage protection)
    /// @param path         Token address path: [WCHZ, ..., FanToken]
    function swapChzForFan(
        uint256 amountOutMin,
        address[] calldata path
    ) external payable {
        require(msg.value > 0, "Must send CHZ");
        require(path.length >= 2, "Invalid path length");
        require(path[0] != address(0) && path[path.length - 1] != address(0), "Zero address in path");

        // Perform the swap: native CHZ -> FanToken
        uint256[] memory amounts = router.swapExactETHForTokens{ value: msg.value }(
            amountOutMin,
            path,
            msg.sender,
            block.timestamp + 300 // deadline: now + 5 minutes
        );

        // Emit event with input (wrapped) and output token addresses and received amount
        emit SwappedToken(path[0], path[path.length - 1], amounts[amounts.length - 1]);
    }

    /// @notice Fallback to accept native CHZ deposits
    receive() external payable {}
}
