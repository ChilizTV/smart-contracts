# IStreamWalletInit
[Git Source](https://github.com/ChilizTV/smart-contracts/blob/a4742235a0eb66bd4bec629003d5109eab4558a0/src/interfaces/IStreamWalletInit.sol)

Interface for StreamWallet initialization

*Used by StreamWalletFactory to initialize new StreamWallet proxies*


## Functions
### initialize

Initialize the StreamWallet


```solidity
function initialize(address streamer_, address treasury_, uint16 platformFeeBps_) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`streamer_`|`address`|The streamer address (owner/beneficiary)|
|`treasury_`|`address`|The platform treasury address|
|`platformFeeBps_`|`uint16`|Platform fee in basis points|


