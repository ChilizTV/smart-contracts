# IUFCInit
[Git Source](https://github.com/ChilizTV/smart-contracts/blob/5df5cfe0612ac659a912e036eb003da070811361/src/interfaces/IUFCInit.sol)

Interface for UFCBetting initialization and betting functions

*Used by MatchHubBeaconFactory to encode initialization call data for BeaconProxy*


## Functions
### initialize

Initializes a UFCBetting contract instance


```solidity
function initialize(
    address owner_,
    address token_,
    bytes32 matchId_,
    uint64 cutoffTs_,
    uint16 feeBps_,
    address treasury_,
    bool allowDraw_
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
|`allowDraw_`|`bool`|Whether to enable draw betting (3 outcomes vs 2)|


### betRed

Places a bet on Red corner fighter


```solidity
function betRed(uint256 amount) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`amount`|`uint256`|Amount of tokens to stake|


### betBlue

Places a bet on Blue corner fighter


```solidity
function betBlue(uint256 amount) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`amount`|`uint256`|Amount of tokens to stake|


### betDraw

Places a bet on draw (only if enabled)


```solidity
function betDraw(uint256 amount) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`amount`|`uint256`|Amount of tokens to stake|


