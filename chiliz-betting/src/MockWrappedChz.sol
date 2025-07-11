// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title MockWrappedChz
/// @notice ERC20 mock to simulate Wrapped CHZ in Foundry tests
contract MockWrappedChz is ERC20, Ownable {
    /// @param name The token’s name
    /// @param symbol The token’s symbol
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        // owner is msg.sender by Ownable
    }

    /// @notice Mint new tokens for testing purposes
    /// @dev Restricted to owner (your test harness)
    /// @param to Recipient address
    /// @param amount Amount of tokens to mint (in wei)
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    } 

    /// @notice Burn tokens (optional)
    /// @dev Restricted to owner
    /// @param from Address whose balance will be burned
    /// @param amount Amount to burn
    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }
}
