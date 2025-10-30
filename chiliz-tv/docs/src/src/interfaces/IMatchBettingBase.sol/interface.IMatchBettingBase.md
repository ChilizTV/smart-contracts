# IMatchBettingBase
[Git Source](https://github.com/ChilizTV/smart-contracts/blob/5df5cfe0612ac659a912e036eb003da070811361/src/interfaces/IMatchBettingBase.sol)

**Author:**
ChilizTV

Interface for the parimutuel betting engine used behind BeaconProxy per match

*Covers views, admin functions, betting, settlement, and claim functions
Also includes events and errors for easier integration (frontend, tests, external contracts)*


## Functions
### ADMIN_ROLE

Returns the admin role identifier


```solidity
function ADMIN_ROLE() external view returns (bytes32);
```

### SETTLER_ROLE

Returns the settler role identifier


```solidity
function SETTLER_ROLE() external view returns (bytes32);
```

### PAUSER_ROLE

Returns the pauser role identifier


```solidity
function PAUSER_ROLE() external view returns (bytes32);
```

### betToken

ERC20 token used for betting


```solidity
function betToken() external view returns (IERC20);
```

### treasury

Address receiving platform fees


```solidity
function treasury() external view returns (address);
```

### matchId

Unique match identifier


```solidity
function matchId() external view returns (bytes32);
```

### cutoffTs

Betting cutoff timestamp


```solidity
function cutoffTs() external view returns (uint64);
```

### feeBps

Platform fee in basis points


```solidity
function feeBps() external view returns (uint16);
```

### outcomesCount

Total number of possible outcomes


```solidity
function outcomesCount() external view returns (uint8);
```

### settled

Whether the match has been settled


```solidity
function settled() external view returns (bool);
```

### winningOutcome

Winning outcome index (valid after settlement)


```solidity
function winningOutcome() external view returns (uint8);
```

### pool

Returns total amount staked on a specific outcome


```solidity
function pool(uint8 outcome) external view returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`outcome`|`uint8`|Outcome index|


### bets

Returns amount a user has bet on a specific outcome


```solidity
function bets(address user, uint8 outcome) external view returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`user`|`address`|User address|
|`outcome`|`uint8`|Outcome index|


### claimed

Returns whether a user has already claimed their winnings


```solidity
function claimed(address user) external view returns (bool);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`user`|`address`|User address|


### setCutoff

Updates betting cutoff timestamp (only before settlement)


```solidity
function setCutoff(uint64 newCutoff) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`newCutoff`|`uint64`|New cutoff timestamp|


### setTreasury

Updates treasury address


```solidity
function setTreasury(address newTreasury) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`newTreasury`|`address`|New treasury address|


### setFeeBps

Updates platform fee in basis points (max 1000 = 10%)


```solidity
function setFeeBps(uint16 newFeeBps) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`newFeeBps`|`uint16`|New fee in basis points|


### pause

Pauses betting operations


```solidity
function pause() external;
```

### unpause

Resumes betting operations


```solidity
function unpause() external;
```

### placeBet

Places a bet on an outcome


```solidity
function placeBet(uint8 outcome, uint256 amount) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`outcome`|`uint8`|Outcome index [0..outcomesCount-1]|
|`amount`|`uint256`|Amount of ERC20 tokens to stake (requires prior approval)|


### settle

Settles the match with winning outcome


```solidity
function settle(uint8 winning) external;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`winning`|`uint8`|Index of the winning outcome|


### claim

Claims parimutuel payout for caller (after settlement)


```solidity
function claim() external;
```

### sweepIfNoWinners

Sweeps funds to treasury if no winning bets exist (after settlement)


```solidity
function sweepIfNoWinners() external;
```

### totalPoolAmount

Returns sum of all bets across all outcomes


```solidity
function totalPoolAmount() external view returns (uint256);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|Total pool amount|


### pendingPayout

Estimates pending payout for a user (returns 0 if not applicable)


```solidity
function pendingPayout(address user) external view returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`user`|`address`|User address to check|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|Estimated payout amount|


## Events
### Initialized
Emitted when match betting is initialized


```solidity
event Initialized(
    address indexed owner,
    address indexed token,
    bytes32 indexed matchId,
    uint8 outcomesCount,
    uint64 cutoffTs,
    uint16 feeBps,
    address treasury
);
```

### BetPlaced
Emitted when a bet is placed


```solidity
event BetPlaced(address indexed user, uint8 indexed outcome, uint256 amount);
```

### Settled
Emitted when match outcome is settled


```solidity
event Settled(uint8 indexed winningOutcome, uint256 totalPool, uint256 feeAmount);
```

### Claimed
Emitted when winnings are claimed


```solidity
event Claimed(address indexed user, uint256 payout);
```

### CutoffUpdated
Emitted when cutoff time is updated


```solidity
event CutoffUpdated(uint64 newCutoff);
```

### TreasuryUpdated
Emitted when treasury address is updated


```solidity
event TreasuryUpdated(address newTreasury);
```

### FeeUpdated
Emitted when fee is updated


```solidity
event FeeUpdated(uint16 newFeeBps);
```

## Errors
### InvalidOutcome
Thrown when invalid outcome index provided


```solidity
error InvalidOutcome();
```

### InvalidParam
Thrown when invalid parameter provided


```solidity
error InvalidParam();
```

### BettingClosed
Thrown when betting after cutoff


```solidity
error BettingClosed();
```

### AlreadySettled
Thrown when attempting to settle already settled match


```solidity
error AlreadySettled();
```

### NotSettled
Thrown when action requires settlement first


```solidity
error NotSettled();
```

### NothingToClaim
Thrown when user has nothing to claim


```solidity
error NothingToClaim();
```

### ZeroAddress
Thrown when zero address provided


```solidity
error ZeroAddress();
```

### TooManyOutcomes
Thrown when outcomes count exceeds maximum


```solidity
error TooManyOutcomes();
```

