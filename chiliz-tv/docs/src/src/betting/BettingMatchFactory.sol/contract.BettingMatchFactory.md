# BettingMatchFactory
[Git Source](https://github.com/ChilizTV/smart-contracts/blob/a4742235a0eb66bd4bec629003d5109eab4558a0/src/betting/BettingMatchFactory.sol)

**Inherits:**
Ownable

Factory contract to deploy UUPS-upgradeable sport-specific match proxies


## State Variables
### allMatches
List of all deployed match proxy addresses


```solidity
address[] public allMatches;
```


### matchSportType
Mapping from match address to its sport type


```solidity
mapping(address => SportType) public matchSportType;
```


### footballImplementation
Immutable implementation contracts deployed once


```solidity
address private immutable footballImplementation;
```


### basketballImplementation

```solidity
address private immutable basketballImplementation;
```


## Functions
### constructor

Deploy implementations and initialize factory


```solidity
constructor() Ownable(msg.sender);
```

### createFootballMatch

Deploy a new FootballMatch proxy and initialize it


```solidity
function createFootballMatch(string calldata _matchName, address _owner) external returns (address proxy);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_matchName`|`string`|The name of the match|
|`_owner`|`address`|The owner of the match contract|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`proxy`|`address`|Address of the newly deployed proxy|


### createBasketballMatch

Deploy a new BasketballMatch proxy and initialize it


```solidity
function createBasketballMatch(string calldata _matchName, address _owner) external returns (address proxy);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_matchName`|`string`|The name of the match|
|`_owner`|`address`|The owner of the match contract|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`proxy`|`address`|Address of the newly deployed proxy|


### getAllMatches

Retrieve all deployed proxy addresses


```solidity
function getAllMatches() external view returns (address[] memory);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`address[]`|Array of match proxy addresses|


### getSportType

Get the sport type of a specific match


```solidity
function getSportType(address matchAddress) external view returns (SportType);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`matchAddress`|`address`|The address of the match contract|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`SportType`|The sport type (FOOTBALL or BASKETBALL)|


## Events
### MatchCreated
Emitted when a new match proxy is created


```solidity
event MatchCreated(address indexed proxy, SportType sportType, address indexed owner);
```

## Enums
### SportType
Sport types supported by the factory


```solidity
enum SportType {
    FOOTBALL,
    BASKETBALL
}
```

