pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @notice Simple mock ERC20 for tests with EIP-2612 permit support
contract MockERC20 is ERC20, ERC20Permit {
    constructor() ERC20("Mock", "MCK") ERC20Permit("Mock") {
        // initial supply to deployer for tests
        _mint(msg.sender, 1_000_000 ether);
    }

    /// @notice Mint tokens to an address (test helper)
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}