// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IKayenMasterRouterV2} from "../../src/interfaces/IKayenMasterRouterV2.sol";
import {IKayenRouter} from "../../src/interfaces/IKayenRouter.sol";

/**
 * @title MockKayenRouter
 * @notice Deterministic mock of KayenMasterRouterV2 + KayenRouter for Foundry tests
 * @dev Simulates CHZ -> USDT and Token -> USDT swaps at a fixed rate (1 CHZ = 0.10 USDT)
 *      Rate is configurable via setRate()
 */
contract MockKayenRouter is IKayenMasterRouterV2, IKayenRouter {
    /// @notice Exchange rate: USDT per 1 CHZ (in USDT decimals, i.e., 6 decimals)
    /// @dev Default: 100_000 = 0.10 USDT per 1 CHZ (18 decimal CHZ -> 6 decimal USDT)
    uint256 public rate = 100_000; // 0.10 USDT per CHZ

    /// @notice USDT mock token used for minting output
    address public usdtToken;

    /// @notice Whether to simulate a swap failure
    bool public shouldFail;

    constructor(address _usdtToken) {
        usdtToken = _usdtToken;
    }

    function setRate(uint256 _rate) external {
        rate = _rate;
    }

    function setShouldFail(bool _shouldFail) external {
        shouldFail = _shouldFail;
    }

    /**
     * @notice Mock: Swap exact CHZ for tokens
     * @dev Mints USDT to `to` based on msg.value * rate / 1e18
     */
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        bool, /* receiveUnwrappedToken */
        address to,
        uint256 deadline
    ) external payable override returns (uint256[] memory amounts) {
        require(!shouldFail, "MockRouter: swap failed");
        require(block.timestamp <= deadline, "MockRouter: expired");
        require(path.length >= 2, "MockRouter: invalid path");
        require(msg.value > 0, "MockRouter: zero value");

        // Calculate USDT output: msg.value (18 decimals) * rate (6 decimals) / 1e18
        uint256 usdtOut = (msg.value * rate) / 1e18;
        require(usdtOut >= amountOutMin, "MockRouter: insufficient output");

        // Mint USDT to recipient
        _mintUSDT(to, usdtOut);

        amounts = new uint256[](path.length);
        amounts[0] = msg.value;
        amounts[path.length - 1] = usdtOut;
    }

    /**
     * @notice Mock: Swap CHZ for exact amount of tokens
     * @dev Calculates CHZ needed, mints exact USDT, refunds excess CHZ
     */
    function swapETHForExactTokens(
        uint256 amountOut,
        address[] calldata path,
        bool, /* receiveUnwrappedToken */
        address to,
        uint256 deadline
    ) external payable override returns (uint256[] memory amounts) {
        require(!shouldFail, "MockRouter: swap failed");
        require(block.timestamp <= deadline, "MockRouter: expired");
        require(path.length >= 2, "MockRouter: invalid path");
        require(amountOut > 0, "MockRouter: zero output");

        // Calculate CHZ needed: amountOut (6 decimals) * 1e18 / rate (6 decimals)
        uint256 chzNeeded = (amountOut * 1e18 + rate - 1) / rate; // Round up
        require(msg.value >= chzNeeded, "MockRouter: insufficient CHZ");

        // Mint exact USDT to recipient
        _mintUSDT(to, amountOut);

        // Refund excess CHZ
        uint256 excess = msg.value - chzNeeded;
        if (excess > 0) {
            (bool success,) = payable(msg.sender).call{value: excess}("");
            require(success, "MockRouter: refund failed");
        }

        amounts = new uint256[](path.length);
        amounts[0] = chzNeeded;
        amounts[path.length - 1] = amountOut;
    }

    function _mintUSDT(address to, uint256 amount) internal {
        // Call mint on the mock USDT token
        (bool success,) = usdtToken.call(abi.encodeWithSignature("mint(address,uint256)", to, amount));
        require(success, "MockRouter: mint failed");
    }

    /**
     * @notice Mock: Swap exact ERC20 tokens for USDT
     * @dev Burns input tokens from this contract, mints USDT to `to` at the same rate
     */
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external override returns (uint256[] memory amounts) {
        require(!shouldFail, "MockRouter: swap failed");
        require(block.timestamp <= deadline, "MockRouter: expired");
        require(path.length >= 2, "MockRouter: invalid path");
        require(amountIn > 0, "MockRouter: zero input");

        // Pull input tokens from sender
        require(IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn), "MockRouter: transfer failed");

        // Calculate USDT output (same rate as CHZ: amountIn * rate / 1e18)
        uint256 usdtOut = (amountIn * rate) / 1e18;
        require(usdtOut >= amountOutMin, "MockRouter: insufficient output");

        // Mint USDT to recipient
        _mintUSDT(to, usdtOut);

        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = usdtOut;
    }

    /**
     * @notice Mock: Get expected output amounts for a swap path
     */
    function getAmountsOut(
        uint256 amountIn,
        address[] calldata path
    ) external view override returns (uint256[] memory amounts) {
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = (amountIn * rate) / 1e18;
    }

    receive() external payable {}
}
