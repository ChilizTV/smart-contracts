# IFootballInit
[Git Source](https://github.com/ChilizTV/smart-contracts/blob/5df5cfe0612ac659a912e036eb003da070811361/src/interfaces/IFootballInit.sol)

Interface for FootballBetting initialization and betting functions

*Used by MatchHubBeaconFactory to encode initialization call data for BeaconProxy*


## Functions
### initialize

Initializes a FootballBetting contract instance


```solidity
function initialize(
    address owner_,
    address token_,
    bytes32 matchId_,
    uint64 cutoffTs_,
    uint16 feeBps_,
    address treasury_
) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`owner_`|`address`|Address to receive admin roles|
|`token_`|`address`|ERC20 token for betting|
|`matchId_`|`bytes32`|Unique match identifier|
|`cutoffTs_`|`uint64`|Betting cutoff timestamp|
|`feeBps_`|`uint16`|Platform fee in basis points|
|`treasury_`|`address`|Address to receive fees|


### betHome

Places a bet on home team to win


```solidity
function betHome(uint256 amount) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`amount`|`uint256`|Amount of tokens to stake|


### betDraw

Places a bet on draw


```solidity
function betDraw(uint256 amount) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`amount`|`uint256`|Amount of tokens to stake|


### betAway

Places a bet on away team to win


```solidity
function betAway(uint256 amount) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`amount`|`uint256`|Amount of tokens to stake|


