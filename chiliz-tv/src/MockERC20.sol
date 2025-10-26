pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Simple mock ERC20 for tests (inherits OZ ERC20 and adds mint)
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MCK") {
        // initial supply to deployer for tests
        _mint(msg.sender, 1_000_000 ether);
    }

    /// @notice Mint tokens to an address (test helper)
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}