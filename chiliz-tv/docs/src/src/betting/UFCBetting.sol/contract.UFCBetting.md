# UFCBetting
[Git Source](https://github.com/ChilizTV/smart-contracts/blob/5df5cfe0612ac659a912e036eb003da070811361/src/betting/UFCBetting.sol)

**Inherits:**
[MatchBettingBase](/src/betting/MatchBettingBase.sol/abstract.MatchBettingBase.md)

**Author:**
ChilizTV

Parimutuel betting implementation for UFC/MMA fights with 2-3 outcomes

*Extends MatchBettingBase with RED (0), BLUE (1), optional DRAW (2)
Supports both 2-outcome (no draw) and 3-outcome (draw allowed) configurations
Used via BeaconProxy pattern - each fight gets its own proxy instance*


## State Variables
### RED
Outcome index for Red corner fighter win


```solidity
uint8 public constant RED = 0;
```


### BLUE
Outcome index for Blue corner fighter win


```solidity
uint8 public constant BLUE = 1;
```


### DRAW
Outcome index for draw (if enabled)


```solidity
uint8 public constant DRAW = 2;
```


### RED_TKO
Reserved for future feature: Red corner wins by TKO/KO


```solidity
uint8 public constant RED_TKO = 3;
```


### BLUE_TKO
Reserved for future feature: Blue corner wins by TKO/KO


```solidity
uint8 public constant BLUE_TKO = 4;
```


### allowDraw
Whether draw betting is enabled for this fight

*If false, only RED and BLUE outcomes are valid (2 outcomes)
If true, DRAW is also valid (3 outcomes)*


```solidity
bool public allowDraw;
```


## Functions
### initialize

Initializes a UFC fight betting instance

*Called by BeaconProxy constructor, can only be called once
Sets up 2 outcomes (RED/BLUE) or 3 outcomes (RED/BLUE/DRAW)*


```solidity
function initialize(
    address owner_,
    address token_,
    bytes32 matchId_,
    uint64 cutoffTs_,
    uint16 feeBps_,
    address treasury_,
    bool allowDraw_
) external initializer;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`owner_`|`address`|Address to receive admin roles (recommended: multisig)|
|`token_`|`address`|ERC20 token address for bets|
|`matchId_`|`bytes32`|Unique fight identifier|
|`cutoffTs_`|`uint64`|Unix timestamp when betting closes|
|`feeBps_`|`uint16`|Platform fee in basis points (max 1000 = 10%)|
|`treasury_`|`address`|Address to receive platform fees|
|`allowDraw_`|`bool`|If true, enables DRAW as third outcome; if false, only RED/BLUE|


### betRed

Places a bet on Red corner fighter to win

*Convenience wrapper for placeBet(RED, amount)*


```solidity
function betRed(uint256 amount) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`amount`|`uint256`|Amount of betToken to stake|


### betBlue

Places a bet on Blue corner fighter to win

*Convenience wrapper for placeBet(BLUE, amount)*


```solidity
function betBlue(uint256 amount) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`amount`|`uint256`|Amount of betToken to stake|


### betDraw

Places a bet on draw result

*Convenience wrapper for placeBet(DRAW, amount)
Only available if allowDraw was set to true during initialization*


```solidity
function betDraw(uint256 amount) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`amount`|`uint256`|Amount of betToken to stake|


