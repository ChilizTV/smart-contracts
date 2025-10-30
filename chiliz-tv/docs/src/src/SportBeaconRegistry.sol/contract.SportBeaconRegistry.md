# SportBeaconRegistry
[Git Source](https://github.com/ChilizTV/smart-contracts/blob/5df5cfe0612ac659a912e036eb003da070811361/src/SportBeaconRegistry.sol)

**Inherits:**
Ownable

**Author:**
ChilizTV

Central registry managing UpgradeableBeacons for different sport betting implementations

*Maintains one beacon per sport type (identified by bytes32 hash)
Enables upgrading all match instances of a sport simultaneously via beacon pattern
Examples: keccak256("FOOTBALL"), keccak256("UFC"), keccak256("BASKETBALL")*


## State Variables
### _beacons
Mapping from sport identifier to its UpgradeableBeacon

*sport hash => beacon contract*


```solidity
mapping(bytes32 => UpgradeableBeacon) private _beacons;
```


## Functions
### constructor

Initializes the registry with an owner


```solidity
constructor(address initialOwner) Ownable(initialOwner);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`initialOwner`|`address`|Address that will own the registry (recommended: Gnosis Safe multisig)|


### checkNullAddress

Ensures address is not zero


```solidity
modifier checkNullAddress(address _addr);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_addr`|`address`|Address to check|


### setSportImplementation

Creates a new beacon or upgrades an existing one for a sport

*If beacon doesn't exist, creates new UpgradeableBeacon
If beacon exists, upgrades it to new implementation
All existing BeaconProxies for this sport will use new implementation*


```solidity
function setSportImplementation(bytes32 sport, address implementation)
    external
    onlyOwner
    checkNullAddress(implementation);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`sport`|`bytes32`|Sport identifier (e.g., keccak256("FOOTBALL"))|
|`implementation`|`address`|Address of the new logic contract (must be non-zero)|


### getBeacon

Returns the beacon address for a sport


```solidity
function getBeacon(bytes32 sport) external view returns (address);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`sport`|`bytes32`|Sport identifier hash|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`address`|Beacon contract address (address(0) if not set)|


### getImplementation

Returns the current implementation address for a sport

*Reverts if beacon doesn't exist (zero address check)*


```solidity
function getImplementation(bytes32 sport) external view checkNullAddress(address(_beacons[sport])) returns (address);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`sport`|`bytes32`|Sport identifier hash|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`address`|Current implementation contract address|


## Events
### SportBeaconCreated
Emitted when a new sport beacon is created


```solidity
event SportBeaconCreated(bytes32 indexed sport, address indexed beacon, address indexed implementation);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`sport`|`bytes32`|Sport identifier hash|
|`beacon`|`address`|Address of the new UpgradeableBeacon|
|`implementation`|`address`|Initial implementation address|

### SportBeaconUpgraded
Emitted when a sport's implementation is upgraded


```solidity
event SportBeaconUpgraded(bytes32 indexed sport, address indexed newImplementation);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`sport`|`bytes32`|Sport identifier hash|
|`newImplementation`|`address`|Address of the new implementation|

## Errors
### NullAddressImplementation
Thrown when a zero address is provided for implementation


```solidity
error NullAddressImplementation();
```

