# StreamBeaconRegistry
[Git Source](https://github.com/ChilizTV/smart-contracts/blob/5df5cfe0612ac659a912e036eb003da070811361/src/streamer/StreamBeaconRegistry.sol)

**Inherits:**
Ownable

Manages the UpgradeableBeacon for StreamWallet implementation

*Similar to SportBeaconRegistry but for streaming wallets*


## State Variables
### beacon
The beacon that points to the current StreamWallet implementation


```solidity
UpgradeableBeacon public beacon;
```


## Functions
### constructor


```solidity
constructor(address initialOwner) Ownable(initialOwner);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`initialOwner`|`address`|Owner of the registry (Gnosis Safe recommended)|


### checkNullAddress


```solidity
modifier checkNullAddress(address _addr);
```

### setImplementation

Set or upgrade the StreamWallet implementation


```solidity
function setImplementation(address implementation) external onlyOwner checkNullAddress(implementation);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`implementation`|`address`|New logic implementation address (non-zero)|


### getBeacon

Get the beacon address


```solidity
function getBeacon() external view returns (address);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`address`|The beacon address (address(0) if not set)|


### getImplementation

Get current implementation address


```solidity
function getImplementation() external view checkNullAddress(address(beacon)) returns (address);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`address`|Current implementation address (reverts if not set)|


### isInitialized

Check if beacon has been initialized


```solidity
function isInitialized() external view returns (bool);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bool`|bool True if beacon exists|


## Events
### BeaconCreated

```solidity
event BeaconCreated(address indexed beacon, address indexed implementation);
```

### BeaconUpgraded

```solidity
event BeaconUpgraded(address indexed newImplementation);
```

## Errors
### NullAddressImplementation

```solidity
error NullAddressImplementation();
```

### BeaconAlreadySet

```solidity
error BeaconAlreadySet();
```

