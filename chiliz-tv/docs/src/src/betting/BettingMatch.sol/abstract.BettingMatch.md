# BettingMatch
[Git Source](https://github.com/ChilizTV/smart-contracts/blob/a4742235a0eb66bd4bec629003d5109eab4558a0/src/betting/BettingMatch.sol)

**Inherits:**
Initializable, OwnableUpgradeable, AccessControlUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable

Abstract base contract for UUPS-upgradeable sports betting matches


## State Variables
### ADMIN_ROLE

```solidity
bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
```


### RESOLVER_ROLE

```solidity
bytes32 public constant RESOLVER_ROLE = keccak256("RESOLVER_ROLE");
```


### PAUSER_ROLE

```solidity
bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
```


### TREASURY_ROLE

```solidity
bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
```


### matchName
Human-readable name or description of the match


```solidity
string public matchName;
```


### sportType
Sport type identifier


```solidity
string public sportType;
```


### marketCount
How many markets have been created


```solidity
uint256 public marketCount;
```


### __gap
Storage gap for future upgrades


```solidity
uint256[40] private __gap;
```


## Functions
### __BettingMatch_init

UUPS initializer — replace constructor


```solidity
function __BettingMatch_init(string memory _matchName, string memory _sportType, address _owner)
    internal
    onlyInitializing;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`_matchName`|`string`|descriptive name of this match|
|`_sportType`|`string`|sport identifier (e.g., "FOOTBALL", "BASKETBALL")|
|`_owner`|`address`|    owner/admin of this contract|


### _authorizeUpgrade


```solidity
function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE);
```

### receive

Allow contract to receive CHZ


```solidity
receive() external payable;
```

### getMarket

Get sport-specific market information (implemented by each sport)


```solidity
function getMarket(uint256 marketId)
    external
    view
    virtual
    returns (string memory marketType, uint256 odds, State state, uint256 result);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|identifier of the market|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`marketType`|`string`|human-readable market type|
|`odds`|`uint256`|multiplier ×100|
|`state`|`State`|current state (Live/Ended)|
|`result`|`uint256`|encoded result (if ended)|


### getBet

Get user's bet for a specific market (implemented by each sport)


```solidity
function getBet(uint256 marketId, address user)
    external
    view
    virtual
    returns (uint256 amount, uint256 selection, bool claimed);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|identifier of the market|
|`user`|`address`|address of the bettor|


### addMarket

Add a new bet market to this match (sport-specific implementation)


```solidity
function addMarket(string calldata marketType, uint256 odds) external virtual;
```

### placeBet

Place a bet in CHZ on a given market (shared logic)


```solidity
function placeBet(uint256 marketId, uint256 selection) external payable whenNotPaused;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|identifier of the market|
|`selection`|`uint256`|encoded user pick|


### resolveMarket

Resolve a market by setting its result (shared logic)


```solidity
function resolveMarket(uint256 marketId, uint256 result) external onlyRole(RESOLVER_ROLE);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|identifier of the market|
|`result`|`uint256`|encoded actual result|


### claim

Claim payout for a winning bet (shared logic)


```solidity
function claim(uint256 marketId) external nonReentrant whenNotPaused;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|identifier of the market|


### cancelMarket

Cancel a market and refund all bettors


```solidity
function cancelMarket(uint256 marketId) external onlyRole(ADMIN_ROLE);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|identifier of the market to cancel|


### refundBet

Refund a specific bet if market was cancelled


```solidity
function refundBet(uint256 marketId) external nonReentrant;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|identifier of the cancelled market|


### emergencyPause

Emergency pause - stops all betting and claiming


```solidity
function emergencyPause() external onlyRole(PAUSER_ROLE);
```

### unpause

Unpause contract


```solidity
function unpause() external onlyRole(ADMIN_ROLE);
```

### emergencyWithdraw

Emergency withdraw - only for stuck funds when paused


```solidity
function emergencyWithdraw(uint256 amount) external onlyRole(TREASURY_ROLE);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`amount`|`uint256`|Amount to withdraw|


### grantRole

Grant a role to an address


```solidity
function grantRole(bytes32 role, address account) public override onlyRole(DEFAULT_ADMIN_ROLE);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`role`|`bytes32`|The role identifier|
|`account`|`address`|The address to grant the role to|


### revokeRole

Revoke a role from an address


```solidity
function revokeRole(bytes32 role, address account) public override onlyRole(DEFAULT_ADMIN_ROLE);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`role`|`bytes32`|The role identifier|
|`account`|`address`|The address to revoke the role from|


### _storeBet

Internal function to store a bet (implemented by each sport)


```solidity
function _storeBet(uint256 marketId, address user, uint256 amount, uint256 selection) internal virtual;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|identifier of the market|
|`user`|`address`|address of the bettor|
|`amount`|`uint256`|bet amount in CHZ|
|`selection`|`uint256`|encoded selection|


### _resolveMarketInternal

Internal function to resolve market (implemented by each sport)


```solidity
function _resolveMarketInternal(uint256 marketId, uint256 result) internal virtual;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|identifier of the market|
|`result`|`uint256`|encoded result|


### _getMarketAndBet

Internal function to get market data and user bet (implemented by each sport)


```solidity
function _getMarketAndBet(uint256 marketId, address user)
    internal
    view
    virtual
    returns (uint256 odds, State state, uint256 result, Bet storage userBet);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|identifier of the market|
|`user`|`address`|address of the bettor|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`odds`|`uint256`|multiplier for the market|
|`state`|`State`|current state of the market|
|`result`|`uint256`|encoded result of the market|
|`userBet`|`Bet`|storage reference to the user's bet|


### _cancelMarketInternal

Internal function to cancel a market (implemented by each sport)


```solidity
function _cancelMarketInternal(uint256 marketId) internal virtual;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|identifier of the market to cancel|


### _getMarketCancellationStatus

Internal function to check if market is cancelled and get bet (implemented by each sport)


```solidity
function _getMarketCancellationStatus(uint256 marketId, address user)
    internal
    view
    virtual
    returns (Bet storage userBet, bool isCancelled);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`marketId`|`uint256`|identifier of the market|
|`user`|`address`|address of the bettor|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`userBet`|`Bet`|storage reference to the user's bet|
|`isCancelled`|`bool`|whether the market is cancelled|


## Events
### MatchInitialized
Emitted when the contract is initialized


```solidity
event MatchInitialized(string indexed name, string sportType, address indexed owner);
```

### MarketAdded
Emitted when a new market is added


```solidity
event MarketAdded(uint256 indexed marketId, string marketType, uint256 odds);
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
Error if zero CHZ is sent


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
Error if CHZ transfer fails


```solidity
error TransferFailed();
```

### InvalidOdds
Error if odds are invalid


```solidity
error InvalidOdds();
```

### InsufficientBalance
Error if insufficient balance for payout


```solidity
error InsufficientBalance();
```

### AlreadyBet
Error if double betting detected


```solidity
error AlreadyBet();
```

## Structs
### Bet
A single user's bet on a market


```solidity
struct Bet {
    uint256 amount;
    uint256 selection;
    bool claimed;
}
```

## Enums
### MarketState
Market lifecycle states


```solidity
enum MarketState {
    Scheduled,
    Live,
    Resolved,
    Cancelled
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

