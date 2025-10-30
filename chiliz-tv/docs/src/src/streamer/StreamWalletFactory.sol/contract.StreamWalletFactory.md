# StreamWalletFactory
[Git Source](https://github.com/ChilizTV/smart-contracts/blob/5df5cfe0612ac659a912e036eb003da070811361/src/streamer/StreamWalletFactory.sol)

**Inherits:**
ReentrancyGuard, Ownable

Factory for deploying StreamWallet proxies for streamers

*Uses BeaconProxy pattern via StreamBeaconRegistry for upgradeability*


## State Variables
### registry

```solidity
StreamBeaconRegistry public immutable registry;
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


### token

```solidity
IERC20 public token;
```


## Functions
### constructor

Initialize the factory


```solidity
constructor(
    address initialOwner,
    address registryAddr,
    address token_,
    address treasury_,
    uint16 defaultPlatformFeeBps_
) Ownable(initialOwner);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`initialOwner`|`address`|The owner of the factory|
|`registryAddr`|`address`|The StreamBeaconRegistry address|
|`token_`|`address`|The payment token address|
|`treasury_`|`address`|The platform treasury address|
|`defaultPlatformFeeBps_`|`uint16`|Default platform fee in basis points|


### subscribeToStream

Subscribe to a streamer (creates wallet if needed)


```solidity
function subscribeToStream(address streamer, uint256 amount, uint256 duration)
    external
    nonReentrant
    returns (address wallet);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`streamer`|`address`|The streamer address|
|`amount`|`uint256`|The subscription amount|
|`duration`|`uint256`|The subscription duration in seconds|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`wallet`|`address`|The StreamWallet address|


### subscribeToStreamWithPermit

Subscribe to a streamer using EIP-2612 permit (single transaction, no prior approval needed)


```solidity
function subscribeToStreamWithPermit(
    address streamer,
    uint256 amount,
    uint256 duration,
    uint256 deadline,
    uint8 v,
    bytes32 r,
    bytes32 s
) external nonReentrant returns (address wallet);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`streamer`|`address`|The streamer address|
|`amount`|`uint256`|The subscription amount|
|`duration`|`uint256`|The subscription duration in seconds|
|`deadline`|`uint256`|The permit deadline timestamp|
|`v`|`uint8`|The recovery byte of the signature|
|`r`|`bytes32`|Half of the ECDSA signature pair|
|`s`|`bytes32`|Half of the ECDSA signature pair|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`wallet`|`address`|The StreamWallet address|


### donateToStream

Send a donation to a streamer (creates wallet if needed)


```solidity
function donateToStream(address streamer, uint256 amount, string calldata message)
    external
    nonReentrant
    returns (address wallet);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`streamer`|`address`|The streamer address|
|`amount`|`uint256`|The donation amount|
|`message`|`string`|Optional message from donor|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`wallet`|`address`|The StreamWallet address|


### donateToStreamWithPermit

Send a donation to a streamer using EIP-2612 permit (single transaction, no prior approval needed)


```solidity
function donateToStreamWithPermit(
    address streamer,
    uint256 amount,
    string calldata message,
    uint256 deadline,
    uint8 v,
    bytes32 r,
    bytes32 s
) external nonReentrant returns (address wallet);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`streamer`|`address`|The streamer address|
|`amount`|`uint256`|The donation amount|
|`message`|`string`|Optional message from donor|
|`deadline`|`uint256`|The permit deadline timestamp|
|`v`|`uint8`|The recovery byte of the signature|
|`r`|`bytes32`|Half of the ECDSA signature pair|
|`s`|`bytes32`|Half of the ECDSA signature pair|

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
function getWallet(address streamer) external view returns (address wallet);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`streamer`|`address`|The streamer address|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`wallet`|`address`|The wallet address (address(0) if not deployed)|


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

### BeaconNotSet

```solidity
error BeaconNotSet();
```

