# StreamWalletFactory
[Git Source](https://github.com/ChilizTV/smart-contracts/blob/a4742235a0eb66bd4bec629003d5109eab4558a0/src/streamer/StreamWalletFactory.sol)

**Inherits:**
ReentrancyGuard, Ownable

Factory for deploying StreamWallet UUPS proxies for streamers

*Uses ERC1967 proxy pattern matching betting system architecture*


## State Variables
### streamWalletImplementation

```solidity
address private immutable streamWalletImplementation;
```


### streamerWallets

```solidity
mapping(address => address) public streamerWallets;
```


### treasury

```solidity
address public treasury;
```


### defaultPlatformFeeBps

```solidity
uint16 public defaultPlatformFeeBps;
```


## Functions
### constructor

Initialize the factory and deploy implementation


```solidity
constructor(address initialOwner, address treasury_, uint16 defaultPlatformFeeBps_) Ownable(initialOwner);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`initialOwner`|`address`|The owner of the factory|
|`treasury_`|`address`|The platform treasury address|
|`defaultPlatformFeeBps_`|`uint16`|Default platform fee in basis points|


### subscribeToStream

Subscribe to a streamer (creates wallet if needed)


```solidity
function subscribeToStream(address streamer, uint256 duration) external payable nonReentrant returns (address wallet);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`streamer`|`address`|The streamer address|
|`duration`|`uint256`|The subscription duration in seconds|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`wallet`|`address`|The StreamWallet address|


### donateToStream

Send a donation to a streamer (creates wallet if needed)


```solidity
function donateToStream(address streamer, string calldata message)
    external
    payable
    nonReentrant
    returns (address wallet);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`streamer`|`address`|The streamer address|
|`message`|`string`|Optional message from donor|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`wallet`|`address`|The StreamWallet address|


### _deployStreamWallet

Deploy a StreamWallet for a streamer


```solidity
function _deployStreamWallet(address streamer) internal returns (address wallet);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`streamer`|`address`|The streamer address|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`wallet`|`address`|The deployed wallet address|


### deployWalletFor

Manually deploy a wallet for a streamer (admin only)


```solidity
function deployWalletFor(address streamer) external onlyOwner returns (address wallet);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`streamer`|`address`|The streamer address|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`wallet`|`address`|The deployed wallet address|


### setTreasury

Update the treasury address


```solidity
function setTreasury(address newTreasury) external onlyOwner;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`newTreasury`|`address`|The new treasury address|


### setPlatformFee

Update the default platform fee

Update the default platform fee


```solidity
function setPlatformFee(uint16 newFeeBps) external onlyOwner;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`newFeeBps`|`uint16`|The new fee in basis points|


### getWallet

Get the wallet address for a streamer


```solidity
function getWallet(address streamer) external view returns (address);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`streamer`|`address`|The streamer address|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`address`|wallet The wallet address (address(0) if not deployed)|


### hasWallet

Check if a streamer has a wallet


```solidity
function hasWallet(address streamer) external view returns (bool);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`streamer`|`address`|The streamer address|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bool`|bool True if wallet exists|


### implementation

Get current implementation address


```solidity
function implementation() external view returns (address);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`address`|Current StreamWallet implementation|


## Events
### StreamWalletCreated

```solidity
event StreamWalletCreated(address indexed streamer, address indexed wallet);
```

### SubscriptionProcessed

```solidity
event SubscriptionProcessed(address indexed streamer, address indexed subscriber, uint256 amount);
```

### DonationProcessed

```solidity
event DonationProcessed(address indexed streamer, address indexed donor, uint256 amount, string message);
```

### TreasuryUpdated

```solidity
event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
```

### PlatformFeeUpdated

```solidity
event PlatformFeeUpdated(uint16 oldFeeBps, uint16 newFeeBps);
```

## Errors
### InvalidAmount

```solidity
error InvalidAmount();
```

### InvalidDuration

```solidity
error InvalidDuration();
```

### InvalidAddress

```solidity
error InvalidAddress();
```

### InvalidFeeBps

```solidity
error InvalidFeeBps();
```

### WalletAlreadyExists

```solidity
error WalletAlreadyExists();
```

