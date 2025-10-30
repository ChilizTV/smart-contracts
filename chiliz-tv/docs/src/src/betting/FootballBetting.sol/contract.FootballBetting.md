# FootballBetting
[Git Source](https://github.com/ChilizTV/smart-contracts/blob/5df5cfe0612ac659a912e036eb003da070811361/src/betting/FootballBetting.sol)

**Inherits:**
[MatchBettingBase](/src/betting/MatchBettingBase.sol/abstract.MatchBettingBase.md)

**Author:**
ChilizTV

Parimutuel betting implementation for football matches with 1X2 outcomes

*Extends MatchBettingBase with 3 outcomes: HOME (0), DRAW (1), AWAY (2)
Used via BeaconProxy pattern - each match gets its own proxy instance*


## State Variables
### HOME
Outcome index for home team win


```solidity
uint8 public constant HOME = 0;
```


### DRAW
Outcome index for draw


```solidity
uint8 public constant DRAW = 1;
```


### AWAY
Outcome index for away team win


```solidity
uint8 public constant AWAY = 2;
```


### HOME_FIRST_GOAL
Reserved for future feature: home team scores first goal


```solidity
uint8 public constant HOME_FIRST_GOAL = 3;
```


### AWAY_FIRST_GOAL
Reserved for future feature: away team scores first goal


```solidity
uint8 public constant AWAY_FIRST_GOAL = 4;
```


### NO_GOAL
Reserved for future feature: no goals scored


```solidity
uint8 public constant NO_GOAL = 5;
```


## Functions
### initialize

Initializes a football match betting instance

*Called by BeaconProxy constructor, can only be called once
Sets up 3 outcomes (HOME/DRAW/AWAY) for standard 1X2 betting*


```solidity
function initialize(
    address owner_,
    address token_,
    bytes32 matchId_,
    uint64 cutoffTs_,
    uint16 feeBps_,
    address treasury_
) external initializer;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`owner_`|`address`|Address to receive admin roles (recommended: multisig)|
|`token_`|`address`|ERC20 token address for bets|
|`matchId_`|`bytes32`|Unique match identifier|
|`cutoffTs_`|`uint64`|Unix timestamp when betting closes|
|`feeBps_`|`uint16`|Platform fee in basis points (max 1000 = 10%)|
|`treasury_`|`address`|Address to receive platform fees|


### betHome

Places a bet on home team to win

*Convenience wrapper for placeBet(HOME, amount)*


```solidity
function betHome(uint256 amount) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`amount`|`uint256`|Amount of betToken to stake|


### betDraw

Places a bet on draw result

*Convenience wrapper for placeBet(DRAW, amount)*


```solidity
function betDraw(uint256 amount) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`amount`|`uint256`|Amount of betToken to stake|


### betAway

Places a bet on away team to win

*Convenience wrapper for placeBet(AWAY, amount)*


```solidity
function betAway(uint256 amount) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`amount`|`uint256`|Amount of betToken to stake|


