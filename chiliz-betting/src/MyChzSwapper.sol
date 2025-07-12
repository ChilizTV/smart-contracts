// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./IKayenRouter.sol";

contract MyChzSwapper {
    IERC20 public immutable wChz = IERC20(0x678c34581db0a7808d0aC669d7025f1408C9a3C6);
    IKayenRouter public immutable router = IKayenRouter(0xb82b0e988a1FcA39602c5079382D360C870b44c8);

    /// @notice Swap wCHZ contre un FanToken via Kayen Router
    /// @param amountIn     quantité de wCHZ à échanger (en wei)
    /// @param amountOutMin slippage minimal de FanToken attendu
    /// @param path         tableau d'adresses [wChz, ..., FanToken]
    function swapChzForFan(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path
    ) external {
        require(path.length >= 2, "Path invalide");
        require(path[0] == address(wChz), "Doit commencer par WCHZ");

        // 1) Transfert des wCHZ depuis l'utilisateur vers ce contrat
        wChz.transferFrom(msg.sender, address(this), amountIn);

        // 2) Approve du Kayen Router
        wChz.approve(address(router), amountIn);

        // 3) Appel au Router pour swap
        //    le `to` est msg.sender pour que les FanTokens arrivent directement au user
        router.swapExactTokensForTokens(
            amountIn,
            amountOutMin,
            path,
            msg.sender,
            block.timestamp + 300  // deadline = maintenant + 5 minutes
        );
    }
}
