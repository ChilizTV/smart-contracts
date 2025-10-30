# MockERC20
[Git Source](https://github.com/ChilizTV/smart-contracts/blob/5df5cfe0612ac659a912e036eb003da070811361/src/MockERC20.sol)

**Inherits:**
ERC20, ERC20Permit

Simple mock ERC20 for tests with EIP-2612 permit support


## Functions
### constructor


```solidity
constructor() ERC20("Mock", "MCK") ERC20Permit("Mock");
```

### mint

Mint tokens to an address (test helper)


```solidity
function mint(address to, uint256 amount) external;
```

