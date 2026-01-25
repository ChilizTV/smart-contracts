# AggregatorV3Interface
[Git Source](https://github.com/ChilizTV/smart-contracts/blob/a4742235a0eb66bd4bec629003d5109eab4558a0/src/interfaces/AggregatorV3Interface.sol)

Interface for Chainlink Price Feeds

*Copied from @chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol*


## Functions
### decimals


```solidity
function decimals() external view returns (uint8);
```

### description


```solidity
function description() external view returns (string memory);
```

### version


```solidity
function version() external view returns (uint256);
```

### getRoundData


```solidity
function getRoundData(uint80 _roundId)
    external
    view
    returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
```

### latestRoundData


```solidity
function latestRoundData()
    external
    view
    returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
```

