# MatchHubBeaconFactory
[Git Source](https://github.com/ChilizTV/smart-contracts/blob/5df5cfe0612ac659a912e036eb003da070811361/src/matchhub/MatchHubBeaconFactory.sol)

**Inherits:**
Ownable

**Author:**
ChilizTV

Factory contract for creating sport-specific match betting instances via BeaconProxy

*Each match gets its own BeaconProxy pointing to sport-specific beacon
Enables per-match instances while allowing global upgrades through beacons
Only owner can create matches (typically backend service or multisig)*


## State Variables
### registry
Reference to the SportBeaconRegistry containing all sport beacons


```solidity
SportBeaconRegistry public immutable registry;
```


### SPORT_FOOTBALL
Sport identifier for Football (1X2 betting)


```solidity
bytes32 public constant SPORT_FOOTBALL = keccak256("FOOTBALL");
```


### SPORT_UFC
Sport identifier for UFC/MMA (2-3 outcome betting)


```solidity
bytes32 public constant SPORT_UFC = keccak256("UFC");
```


## Functions
### constructor

Initializes the factory with owner and registry


```solidity
constructor(address initialOwner, address registryAddr) Ownable(initialOwner);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`initialOwner`|`address`|Address that can create matches (recommended: backend service or multisig)|
|`registryAddr`|`address`|Address of the SportBeaconRegistry|


### createFootballMatch

Creates a new Football match betting instance

*Creates BeaconProxy pointing to Football beacon with 1X2 outcomes
Reverts if Football beacon not set in registry*


```solidity
function createFootballMatch(
    address owner_,
    address token_,
    bytes32 matchId_,
    uint64 cutoffTs_,
    uint16 feeBps_,
    address treasury_
) external onlyOwner returns (address proxy);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`owner_`|`address`|Address to receive admin roles on the match|
|`token_`|`address`|ERC20 token for betting|
|`matchId_`|`bytes32`|Unique match identifier|
|`cutoffTs_`|`uint64`|Betting cutoff timestamp|
|`feeBps_`|`uint16`|Platform fee in basis points|
|`treasury_`|`address`|Address to receive fees|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`proxy`|`address`|Address of the created BeaconProxy|


### createUFCMatch

Creates a new UFC/MMA match betting instance

*Creates BeaconProxy pointing to UFC beacon with 2 or 3 outcomes
Reverts if UFC beacon not set in registry*


```solidity
function createUFCMatch(
    address owner_,
    address token_,
    bytes32 matchId_,
    uint64 cutoffTs_,
    uint16 feeBps_,
    address treasury_,
    bool allowDraw_
) external onlyOwner returns (address proxy);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`owner_`|`address`|Address to receive admin roles on the match|
|`token_`|`address`|ERC20 token for betting|
|`matchId_`|`bytes32`|Unique match identifier|
|`cutoffTs_`|`uint64`|Betting cutoff timestamp|
|`feeBps_`|`uint16`|Platform fee in basis points|
|`treasury_`|`address`|Address to receive fees|
|`allowDraw_`|`bool`|If true, enables 3 outcomes (RED/BLUE/DRAW); if false, 2 outcomes (RED/BLUE)|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`proxy`|`address`|Address of the created BeaconProxy|


## Events
### MatchHubCreated
Emitted when a new match betting instance is created


```solidity
event MatchHubCreated(bytes32 indexed sport, address indexed proxy, bytes32 indexed matchId, address owner);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`sport`|`bytes32`|Sport identifier hash|
|`proxy`|`address`|Address of the newly created BeaconProxy|
|`matchId`|`bytes32`|Unique match identifier|
|`owner`|`address`|Address granted admin roles on the match|

