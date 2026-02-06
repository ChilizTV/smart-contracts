# BasketballMatch
[Git Source](https://github.com/ChilizTV/smart-contracts/blob/a4742235a0eb66bd4bec629003d5109eab4558a0/src/betting/BasketballMatch.sol)

**Inherits:**
[BettingMatch](/src/betting/BettingMatch.sol/abstract.BettingMatch.md)

Basketball-specific betting contract with markets like Winner, TotalPoints, PointSpread, etc.


## State Variables
### basketballMarkets
Mapping: marketId → BasketballMarket


```solidity
mapping(uint256 => BasketballMarket) public basketballMarkets;
```


## Functions
### constructor

**Note:**
oz-upgrades-unsafe-allow: constructor


```solidity
constructor();
```

### initialize

Initialize a basketball match


```solidity
function initialize(string memory _matchName, address _owner) external initializer;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_matchName`|`string`|descriptive name (e.g., "Lakers vs Celtics")|
|`_owner`|`address`|owner/admin address|


### addMarket

Add a new basketball market


```solidity
function addMarket(string calldata marketType, uint256 odds) external override onlyRole(ADMIN_ROLE);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketType`|`string`|string representation of BasketballMarketType|
|`odds`|`uint256`|multiplier ×100 (e.g., 180 = 1.8x)|


### _storeBet

Internal function to store a basketball bet


```solidity
function _storeBet(uint256 marketId, address user, uint256 amount, uint256 selection) internal override;
```

### _resolveMarketInternal

Internal function to resolve a basketball market


```solidity
function _resolveMarketInternal(uint256 marketId, uint256 result) internal override;
```

### _getMarketAndBet

Internal helper to get market and bet data for claim logic


```solidity
function _getMarketAndBet(uint256 marketId, address user)
    internal
    view
    override
    returns (uint256 odds, State state, uint256 result, Bet storage userBet);
```

### getMarket

Get basketball market details


```solidity
function getMarket(uint256 marketId)
    external
    view
    override
    returns (string memory marketType, uint256 odds, State state, uint256 result);
```

### getBet

Get user's bet on a basketball market


```solidity
function getBet(uint256 marketId, address user)
    external
    view
    override
    returns (uint256 amount, uint256 selection, bool claimed);
```

### _parseBasketballMarketType

Parse string to BasketballMarketType enum


```solidity
function _parseBasketballMarketType(string calldata marketType) internal pure returns (BasketballMarketType);
```

### _basketballMarketTypeToString

Convert BasketballMarketType enum to string


```solidity
function _basketballMarketTypeToString(BasketballMarketType mtype) internal pure returns (string memory);
```

### _cancelMarketInternal

Internal function to cancel a basketball market


```solidity
function _cancelMarketInternal(uint256 marketId) internal override;
```

### _getMarketCancellationStatus

Internal function to check if market is cancelled and get bet


```solidity
function _getMarketCancellationStatus(uint256 marketId, address user)
    internal
    view
    override
    returns (Bet storage userBet, bool isCancelled);
```

## Structs
### BasketballMarket
A basketball-specific market


```solidity
struct BasketballMarket {
    BasketballMarketType mtype;
    uint256 odds;
    State state;
    uint256 result;
    bool cancelled;
    mapping(address => Bet) bets;
}
```

## Enums
### BasketballMarketType
Types of markets available for basketball


```solidity
enum BasketballMarketType {
    Winner,
    TotalPoints,
    PointSpread,
    QuarterWinner,
    FirstToScore,
    HighestScoringQuarter
}
```

