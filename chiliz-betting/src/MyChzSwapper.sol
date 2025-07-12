// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./IKayenRouter.sol";

contract MyChzSwapper {
    IKayenRouter public immutable router = IKayenRouter(0xb82b0e988a1FcA39602c5079382D360C870b44c8);

    event SwappedToken(address tokenA, address tokenB, uint256 amount);
    
    /// @notice Swap du CHZ natif contre un FanToken via Kayen Router
    /// @param amountOutMin quantité minimum de FanToken (slippage)
    /// @param path         chemin [WCHZ, …, FanToken]
    function swapChzForFan(uint256 amountOutMin, address[] memory path) external payable {
        require(path.length >= 2, "Path invalide");
        require(path[0] != address(0), "Path[0] zero addr");

        // Appel à la méthode ETH→Tokens
        router.swapExactETHForTokens{value: msg.value}(amountOutMin, path, msg.sender, block.timestamp + 300);
    }

    // Pour recevoir d’éventuels ETH restitués
    receive() external payable {}
}
