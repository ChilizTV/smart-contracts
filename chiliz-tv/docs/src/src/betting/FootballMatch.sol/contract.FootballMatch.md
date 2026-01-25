# FootballMatch
[Git Source](https://github.com/ChilizTV/smart-contracts/blob/a4742235a0eb66bd4bec629003d5109eab4558a0/src/betting/FootballMatch.sol)

**Inherits:**
[BettingMatch](/src/betting/BettingMatch.sol/abstract.BettingMatch.md)

Football-specific betting contract with markets like Winner, GoalsCount, FirstScorer, etc.


## State Variables
### footballMarkets
Mapping: marketId → FootballMarket


```solidity
mapping(uint256 => FootballMarket) public footballMarkets;
```


## Functions
### constructor

**Note:**
oz-upgrades-unsafe-allow: constructor


```solidity
constructor();
```

### initialize

Initialize a football match


```solidity
function initialize(string memory _matchName, address _owner) external initializer;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_matchName`|`string`|descriptive name (e.g., "Barcelona vs Real Madrid")|
|`_owner`|`address`|owner/admin address|


### addMarket

Add a new football market


```solidity
function addMarket(string calldata marketType, uint256 odds) external override onlyRole(ADMIN_ROLE);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketType`|`string`|string representation of FootballMarketType (e.g., "Winner", "GoalsCount")|
|`odds`|`uint256`|multiplier ×100 (e.g., 200 = 2.0x)|


### _storeBet

Internal function to store a football bet


```solidity
function _storeBet(uint256 marketId, address user, uint256 amount, uint256 selection) internal override;
```

### _resolveMarketInternal

Internal function to resolve a football market


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

Get football market details


```solidity
function getMarket(uint256 marketId)
    external
    view
    override
    returns (string memory marketType, uint256 odds, State state, uint256 result);
```

### getBet

Get user's bet on a football market


```solidity
function getBet(uint256 marketId, address user)
    external
    view
    override
    returns (uint256 amount, uint256 selection, bool claimed);
```

### _parseFootballMarketType

Parse string to FootballMarketType enum


```solidity
function _parseFootballMarketType(string calldata marketType) internal pure returns (FootballMarketType);
```

### _footballMarketTypeToString

Convert FootballMarketType enum to string


```solidity
function _footballMarketTypeToString(FootballMarketType mtype) internal pure returns (string memory);
```

### _cancelMarketInternal

Internal function to cancel a football market


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
### FootballMarket
A football-specific market


```solidity
struct FootballMarket {
    FootballMarketType mtype;
    uint256 odds;
    State state;
    uint256 result;
    bool cancelled;
    mapping(address => Bet) bets;
}
```

## Enums
### FootballMarketType
Types of markets available for football


```solidity
enum FootballMarketType {
    Winner,
    GoalsCount,
    FirstScorer,
    BothTeamsScore,
    HalfTimeResult,
    CorrectScore
}
```

