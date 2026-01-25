# StreamWallet
[Git Source](https://github.com/ChilizTV/smart-contracts/blob/a4742235a0eb66bd4bec629003d5109eab4558a0/src/streamer/StreamWallet.sol)

**Inherits:**
Initializable, OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable

Smart wallet for managing streaming revenue (subscriptions and donations)

*Deployed via ERC1967 UUPS proxy by StreamWalletFactory*


## State Variables
### streamer

```solidity
address public streamer;
```


### treasury

```solidity
address public treasury;
```


### platformFeeBps

```solidity
uint16 public platformFeeBps;
```


### factory

```solidity
address public factory;
```


### subscriptions

```solidity
mapping(address => Subscription) public subscriptions;
```


### lifetimeDonations

```solidity
mapping(address => uint256) public lifetimeDonations;
```


### totalRevenue

```solidity
uint256 public totalRevenue;
```


### totalWithdrawn

```solidity
uint256 public totalWithdrawn;
```


### totalSubscribers

```solidity
uint256 public totalSubscribers;
```


## Functions
### onlyFactory


```solidity
modifier onlyFactory();
```

### onlyStreamer


```solidity
modifier onlyStreamer();
```

### constructor

**Note:**
oz-upgrades-unsafe-allow: constructor


```solidity
constructor();
```

### initialize

Initialize the StreamWallet


```solidity
function initialize(address streamer_, address treasury_, uint16 platformFeeBps_) external initializer;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`streamer_`|`address`|The streamer address (owner/beneficiary)|
|`treasury_`|`address`|The platform treasury address|
|`platformFeeBps_`|`uint16`|Platform fee in basis points|


### recordSubscription

Record a subscription and distribute funds


```solidity
function recordSubscription(address subscriber, uint256 amount, uint256 duration)
    external
    payable
    onlyFactory
    nonReentrant
    returns (uint256 platformFee, uint256 streamerAmount);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`subscriber`|`address`|The subscriber address|
|`amount`|`uint256`|The subscription amount|
|`duration`|`uint256`|The subscription duration in seconds|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`platformFee`|`uint256`|The fee sent to treasury|
|`streamerAmount`|`uint256`|The amount sent to streamer|


### donate

Accept a donation with optional message


```solidity
function donate(uint256 amount, string calldata message)
    external
    payable
    nonReentrant
    returns (uint256 platformFee, uint256 streamerAmount);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`amount`|`uint256`|The donation amount|
|`message`|`string`|Optional message from donor|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`platformFee`|`uint256`|The fee sent to treasury|
|`streamerAmount`|`uint256`|The amount sent to streamer|


### withdrawRevenue

Streamer withdraws accumulated revenue


```solidity
function withdrawRevenue(uint256 amount) external onlyStreamer nonReentrant;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`amount`|`uint256`|The amount to withdraw|


### isSubscribed

Check if a user has an active subscription


```solidity
function isSubscribed(address user) external view returns (bool);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`user`|`address`|The user address to check|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`bool`|bool True if subscription is active and not expired|


### availableBalance

Get available balance for withdrawal


```solidity
function availableBalance() public view returns (uint256);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|uint256 The available balance|


### getSubscription

Get subscription details for a user


```solidity
function getSubscription(address user) external view returns (Subscription memory);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`user`|`address`|The user address|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`Subscription`|Subscription struct with subscription details|


### getDonationAmount

Get lifetime donation amount from a donor


```solidity
function getDonationAmount(address donor) external view returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`donor`|`address`|The donor address|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|uint256 Total donated amount|


### receive

Receive function to accept native CHZ


```solidity
receive() external payable;
```

### _authorizeUpgrade

Authorize upgrade (only streamer/owner can upgrade)


```solidity
function _authorizeUpgrade(address newImplementation) internal override onlyOwner;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`newImplementation`|`address`|The new implementation address|


## Events
### SubscriptionRecorded

```solidity
event SubscriptionRecorded(address indexed subscriber, uint256 amount, uint256 duration, uint256 expiryTime);
```

### DonationReceived

```solidity
event DonationReceived(
    address indexed donor, uint256 amount, string message, uint256 platformFee, uint256 streamerAmount
);
```

### RevenueWithdrawn

```solidity
event RevenueWithdrawn(address indexed streamer, uint256 amount);
```

### PlatformFeeCollected

```solidity
event PlatformFeeCollected(uint256 amount, address indexed treasury);
```

## Errors
### OnlyFactory

```solidity
error OnlyFactory();
```

### OnlyStreamer

```solidity
error OnlyStreamer();
```

### InvalidAmount

```solidity
error InvalidAmount();
```

### InvalidDuration

```solidity
error InvalidDuration();
```

### InsufficientBalance

```solidity
error InsufficientBalance();
```

## Structs
### Subscription

```solidity
struct Subscription {
    uint256 amount;
    uint256 startTime;
    uint256 expiryTime;
    bool active;
}
```

