# MatchHubFactory
[Git Source](https://github.com/ChilizTV/smart-contracts/blob/5df5cfe0612ac659a912e036eb003da070811361/src/matchhub/MatchHubFactory.sol)

**Inherits:**
Ownable

Factory contract to deploy UUPS‑upgradeable MatchHub proxies


## State Variables
### implementation
Address of the MatchHub logic contract implementation


```solidity
address public implementation;
```


### allHubs
List of all deployed MatchHub proxy addresses


```solidity
address[] public allHubs;
```


## Functions
### constructor


```solidity
constructor(address _implementation) Ownable(msg.sender);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_implementation`|`address`|Initial MatchHub implementation address|


### setImplementation

Update the logic contract address for future proxies


```solidity
function setImplementation(address _newImpl) external onlyOwner;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_newImpl`|`address`|New implementation contract address|


### createHub

Deploy a new MatchHub proxy and initialize it for the caller

*Uses ERC‑1967 proxy pattern to delegate to `implementation`*


```solidity
function createHub() external returns (address proxy);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`proxy`|`address`|Address of the newly deployed proxy|


### getAllHubs

Retrieve all deployed proxy addresses


```solidity
function getAllHubs() external view returns (address[] memory);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`address[]`|Array of MatchHub proxy addresses|


## Events
### ImplementationUpdated
Emitted when the implementation logic address is updated


```solidity
event ImplementationUpdated(address indexed newImplementation);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`newImplementation`|`address`|The new implementation address|

### MatchHubCreated
Emitted when a new MatchHub proxy is created


```solidity
event MatchHubCreated(address indexed proxy, address indexed owner);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`proxy`|`address`|Address of the deployed proxy|
|`owner`|`address`|Address that will own the new proxy|

## Errors
### ZeroAddress
Custom error for zero‑address inputs


```solidity
error ZeroAddress();
```

