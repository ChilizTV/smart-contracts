# MatchHub
[Git Source](https://github.com/ChilizTV/smart-contracts/blob/5df5cfe0612ac659a912e036eb003da070811361/src/matchhub/MatchHub.sol)

**Inherits:**
Initializable, OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuard

UUPS‑upgradeable contract representing one sports match with multiple bet markets


## State Variables
### matchName
Human‑readable name or description of the match


```solidity
string public matchName;
```


### marketCount
How many markets have been created


```solidity
uint256 public marketCount;
```


### markets
Mapping: marketId → Market


```solidity
mapping(uint256 => Market) public markets;
```


## Functions
### initialize

UUPS initializer — replace constructor


```solidity
function initialize(string calldata _matchName, address _owner) external initializer;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_matchName`|`string`|descriptive name of this match|
|`_owner`|`address`|     owner/admin of this contract|


### _authorizeUpgrade


```solidity
function _authorizeUpgrade(address) internal override onlyOwner;
```

### addMarket

Add a new bet market to this match


```solidity
function addMarket(MarketType mtype, uint256 odds) external onlyOwner;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`mtype`|`MarketType`|type of market (Winner, GoalsCount, FirstScorer)|
|`odds`|`uint256`| multiplier ×100 (e.g. 150 == 1.5×)|


### placeBet

Place a bet in ETH on a given market


```solidity
function placeBet(uint256 marketId, uint256 selection) external payable;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`| identifier of the market|
|`selection`|`uint256`|encoded user pick|


### resolveMarket

Resolve a market by setting its result


```solidity
function resolveMarket(uint256 marketId, uint256 result) external onlyOwner;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|identifier of the market|
|`result`|`uint256`|  encoded actual result|


### claim

Claim payout for a winning bet


```solidity
function claim(uint256 marketId) external nonReentrant;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|identifier of the market|


## Events
### MatchInitialized
Emitted when the contract is initialized


```solidity
event MatchInitialized(string indexed name, address indexed owner);
```

### MarketAdded
Emitted when a new market is added


```solidity
event MarketAdded(uint256 indexed marketId, MarketType mtype, uint256 odds);
```

### BetPlaced
Emitted when a bet is placed


```solidity
event BetPlaced(uint256 indexed marketId, address indexed user, uint256 amount, uint256 selection);
```

### MarketResolved
Emitted when a market is resolved


```solidity
event MarketResolved(uint256 indexed marketId, uint256 result);
```

### Payout
Emitted when a payout is made


```solidity
event Payout(uint256 indexed marketId, address indexed user, uint256 amount);
```

## Errors
### InvalidMarket
Error for invalid market references


```solidity
error InvalidMarket(uint256 marketId);
```

### WrongState
Error for wrong market state


```solidity
error WrongState(State required);
```

### ZeroBet
Error if zero ETH is sent


```solidity
error ZeroBet();
```

### NoBet
Error if no bet exists


```solidity
error NoBet();
```

### AlreadyClaimed
Error if already claimed


```solidity
error AlreadyClaimed();
```

### Lost
Error if selection lost


```solidity
error Lost();
```

### TransferFailed
Error if ETH transfer fails


```solidity
error TransferFailed();
```

## Structs
### Bet
A single user’s bet on a market


```solidity
struct Bet {
    uint256 amount;
    uint256 selection;
    bool claimed;
}
```

### Market
A market inside this match


```solidity
struct Market {
    MarketType mtype;
    uint256 odds;
    State state;
    uint256 result;
    mapping(address => Bet) bets;
    address[] bettors;
}
```

## Enums
### MarketType
Types of markets available in this match


```solidity
enum MarketType {
    Winner,
    GoalsCount,
    FirstScorer
}
```

### State
State of each market


```solidity
enum State {
    Live,
    Ended
}
```

