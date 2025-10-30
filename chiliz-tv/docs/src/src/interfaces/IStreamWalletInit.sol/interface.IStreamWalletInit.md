# IStreamWalletInit
[Git Source](https://github.com/ChilizTV/smart-contracts/blob/5df5cfe0612ac659a912e036eb003da070811361/src/interfaces/IStreamWalletInit.sol)

Interface for StreamWallet initialization

*Used by StreamWalletFactory to initialize new StreamWallet proxies*


## Functions
### initialize

Initialize the StreamWallet


```solidity
function initialize(address streamer_, address token_, address treasury_, uint16 platformFeeBps_) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`streamer_`|`address`|The streamer address (owner/beneficiary)|
|`token_`|`address`|The ERC20 token used for payments|
|`treasury_`|`address`|The platform treasury address|
|`platformFeeBps_`|`uint16`|Platform fee in basis points|


