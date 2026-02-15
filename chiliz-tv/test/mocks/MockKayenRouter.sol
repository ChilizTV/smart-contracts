// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IKayenMasterRouterV2} from "../../src/interfaces/IKayenMasterRouterV2.sol";

/**
 * @title MockKayenRouter
 * @notice Deterministic mock of KayenMasterRouterV2 for Foundry tests
 * @dev Simulates CHZ -> USDC swaps at a fixed rate (1 CHZ = 0.10 USDC)
 *      Rate is configurable via setRate()
 */
contract MockKayenRouter is IKayenMasterRouterV2 {
    /// @notice Exchange rate: USDC per 1 CHZ (in USDC decimals, i.e., 6 decimals)
    /// @dev Default: 100_000 = 0.10 USDC per 1 CHZ (18 decimal CHZ -> 6 decimal USDC)
    uint256 public rate = 100_000; // 0.10 USDC per CHZ

    /// @notice USDC mock token used for minting output
    address public usdcToken;

    /// @notice Whether to simulate a swap failure
    bool public shouldFail;

    constructor(address _usdcToken) {
        usdcToken = _usdcToken;
    }

    function setRate(uint256 _rate) external {
        rate = _rate;
    }

    function setShouldFail(bool _shouldFail) external {
        shouldFail = _shouldFail;
    }

    /**
     * @notice Mock: Swap exact CHZ for tokens
     * @dev Mints USDC to `to` based on msg.value * rate / 1e18
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

        // Calculate USDC output: msg.value (18 decimals) * rate (6 decimals) / 1e18
        uint256 usdcOut = (msg.value * rate) / 1e18;
        require(usdcOut >= amountOutMin, "MockRouter: insufficient output");

        // Mint USDC to recipient
        _mintUSDC(to, usdcOut);

        amounts = new uint256[](path.length);
        amounts[0] = msg.value;
        amounts[path.length - 1] = usdcOut;
    }

    /**
     * @notice Mock: Swap CHZ for exact amount of tokens
     * @dev Calculates CHZ needed, mints exact USDC, refunds excess CHZ
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

        // Mint exact USDC to recipient
        _mintUSDC(to, amountOut);

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

    function _mintUSDC(address to, uint256 amount) internal {
        // Call mint on the mock USDC token
        (bool success,) = usdcToken.call(abi.encodeWithSignature("mint(address,uint256)", to, amount));
        require(success, "MockRouter: mint failed");
    }

    receive() external payable {}
}
