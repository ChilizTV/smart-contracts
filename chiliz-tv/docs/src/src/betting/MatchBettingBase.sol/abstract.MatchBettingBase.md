# MatchBettingBase
[Git Source](https://github.com/ChilizTV/smart-contracts/blob/5df5cfe0612ac659a912e036eb003da070811361/src/betting/MatchBettingBase.sol)

**Inherits:**
Initializable, PausableUpgradeable, AccessControlUpgradeable, ReentrancyGuardUpgradeable

**Author:**
ChilizTV

Abstract base contract implementing pari-mutuel betting logic for sports matches

*Designed to be used behind a BeaconProxy for upgradeable per-match betting instances.
Storage layout must remain append-only for future logic versions to maintain compatibility.
Implements parimutuel betting where losers fund winners proportionally after platform fees.*


## State Variables
### ADMIN_ROLE
Role for administrative functions (setCutoff, setTreasury, setFeeBps)


```solidity
bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
```


### SETTLER_ROLE
Role authorized to settle match outcomes


```solidity
bytes32 public constant SETTLER_ROLE = keccak256("SETTLER_ROLE");
```


### PAUSER_ROLE
Role authorized to pause/unpause betting


```solidity
bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
```


### betToken
ERC20 token used for placing bets and payouts


```solidity
IERC20 public betToken;
```


### treasury
Address receiving platform fees


```solidity
address public treasury;
```


### matchId
Unique identifier for this match (can be hash of off-chain data)


```solidity
bytes32 public matchId;
```


### cutoffTs
Unix timestamp after which no more bets can be placed


```solidity
uint64 public cutoffTs;
```


### feeBps
Platform fee in basis points (e.g., 200 = 2%, max 1000 = 10%)


```solidity
uint16 public feeBps;
```


### outcomesCount
Total number of possible outcomes for this match (2-16)


```solidity
uint8 public outcomesCount;
```


### settled
Whether the match has been settled (immutable once true)


```solidity
bool public settled;
```


### winningOutcome
Index of the winning outcome (only valid after settlement)


```solidity
uint8 public winningOutcome;
```


### pool
Total amount staked on each outcome

*outcomeId => total stake amount*


```solidity
mapping(uint8 => uint256) public pool;
```


### bets
Individual user stakes per outcome

*user => outcomeId => stake amount*


```solidity
mapping(address => mapping(uint8 => uint256)) public bets;
```


### claimed
Tracks whether a user has claimed their winnings

*user => has claimed*


```solidity
mapping(address => bool) public claimed;
```


## Functions
### initializeBase

Initializes the betting contract for a specific match

*Called internally by sport-specific implementations via BeaconProxy
Grants all roles to owner and sets up parimutuel betting parameters*


```solidity
function initializeBase(
    address owner_,
    address token_,
    bytes32 matchId_,
    uint8 outcomes_,
    uint64 cutoffTs_,
    uint16 feeBps_,
    address treasury_
) internal onlyInitializing;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`owner_`|`address`|Address to receive admin roles (recommended: Gnosis Safe multisig)|
|`token_`|`address`|ERC20 token address for placing bets and payouts|
|`matchId_`|`bytes32`|Unique identifier for this match (hash of off-chain data)|
|`outcomes_`|`uint8`|Number of possible outcomes (min 2, max 16, typical 2-3)|
|`cutoffTs_`|`uint64`|Unix timestamp after which betting closes|
|`feeBps_`|`uint16`|Platform fee in basis points (max 1000 = 10%)|
|`treasury_`|`address`|Address to receive platform fees|


### onlyBeforeCutoff

Ensures function can only be called before betting cutoff

*Reverts with BettingClosed if current time >= cutoffTs*


```solidity
modifier onlyBeforeCutoff();
```

### setCutoff

Updates the betting cutoff timestamp

*Can only be called before settlement to prevent manipulation*


```solidity
function setCutoff(uint64 newCutoff) external onlyRole(ADMIN_ROLE);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`newCutoff`|`uint64`|New cutoff timestamp (unix seconds)|


### setTreasury

Updates the treasury address receiving fees

*Zero address not allowed*


```solidity
function setTreasury(address newTreasury) external onlyRole(ADMIN_ROLE);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`newTreasury`|`address`|New treasury address|


### setFeeBps

Updates the platform fee percentage

*Maximum fee is 10% (1000 basis points)*


```solidity
function setFeeBps(uint16 newFeeBps) external onlyRole(ADMIN_ROLE);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`newFeeBps`|`uint16`|New fee in basis points|


### pause

Pauses all betting operations

*Can only be called by PAUSER_ROLE*


```solidity
function pause() external onlyRole(PAUSER_ROLE);
```

### unpause

Resumes betting operations

*Can only be called by PAUSER_ROLE*


```solidity
function unpause() external onlyRole(PAUSER_ROLE);
```

### placeBet

Places a bet on a specific outcome

*Internal function called by sport-specific wrappers (betHome, betRed, etc.)
Transfers tokens from user (requires prior approval)
Parimutuel system: user share = (user bet / total winning pool) * total pool after fees*


```solidity
function placeBet(uint8 outcome, uint256 amount) internal whenNotPaused onlyBeforeCutoff nonReentrant;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`outcome`|`uint8`|Outcome index to bet on [0..outcomesCount-1]|
|`amount`|`uint256`|Amount of betToken to stake (must be > 0)|


### settle

Settles the match with the winning outcome

*Can only be called once by SETTLER_ROLE after match conclusion
Sets match as settled and records winning outcome
Fees are calculated and emitted but transferred during claims*


```solidity
function settle(uint8 winning) external whenNotPaused onlyRole(SETTLER_ROLE);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`winning`|`uint8`|Index of the winning outcome [0..outcomesCount-1]|


### claim

Claims winnings for the caller based on their winning bets

*Implements parimutuel payout calculation:
Payout = (userBet / winningPool) * (totalPool - fees)
Can only claim once after settlement
Fees are sent to treasury on first claim only (via feeBpsOnFirstClaim optimization)*


```solidity
function claim() external whenNotPaused nonReentrant;
```

### sweepIfNoWinners

Sweeps all funds to treasury when there are no winners

*Can only be called by ADMIN_ROLE after settlement
Reverts if winning pool has any bets (winners exist)
Use case: All users bet on wrong outcomes, no one to pay out*


```solidity
function sweepIfNoWinners() external onlyRole(ADMIN_ROLE);
```

### totalPoolAmount

Calculates total amount in all betting pools


```solidity
function totalPoolAmount() public view returns (uint256 sum);
```
**Returns**

|Name|Type|Description|
|----|----|-----------|
|`sum`|`uint256`|Total tokens staked across all outcomes|


### pendingPayout

Calculates pending payout for a user if they won

*Returns 0 if match not settled or user has no winning bets
Formula: (userBet / winningPool) * (totalPool - fees)*


```solidity
function pendingPayout(address user) external view returns (uint256);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`user`|`address`|Address to check payout for|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`uint256`|Pending payout amount in betToken|


### _initSport

Internal helper for sport-specific implementations to initialize base

*Must be called by concrete implementations (FootballBetting, UFCBetting, etc.)
during their initialize() function*


```solidity
function _initSport(
    address owner_,
    address token_,
    bytes32 matchId_,
    uint64 cutoffTs_,
    uint16 feeBps_,
    address treasury_,
    uint8 outcomes_
) internal;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`owner_`|`address`|Address to receive admin roles|
|`token_`|`address`|ERC20 token for betting|
|`matchId_`|`bytes32`|Match identifier|
|`cutoffTs_`|`uint64`|Betting cutoff timestamp|
|`feeBps_`|`uint16`|Platform fee in basis points|
|`treasury_`|`address`|Fee recipient address|
|`outcomes_`|`uint8`|Number of possible outcomes|


## Events
### Initialized
Emitted when a match betting instance is initialized


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

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`owner`|`address`|Address granted admin roles|
|`token`|`address`|ERC20 token address for bets|
|`matchId`|`bytes32`|Unique match identifier|
|`outcomesCount`|`uint8`|Number of possible outcomes|
|`cutoffTs`|`uint64`|Betting cutoff timestamp|
|`feeBps`|`uint16`|Platform fee in basis points|
|`treasury`|`address`|Address receiving fees|

### BetPlaced
Emitted when a user places a bet


```solidity
event BetPlaced(address indexed user, uint8 indexed outcome, uint256 amount);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`user`|`address`|Address of the bettor|
|`outcome`|`uint8`|Outcome index being bet on|
|`amount`|`uint256`|Amount of tokens staked|

### Settled
Emitted when match outcome is settled


```solidity
event Settled(uint8 indexed winningOutcome, uint256 totalPool, uint256 feeAmount);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`winningOutcome`|`uint8`|Index of the winning outcome|
|`totalPool`|`uint256`|Total amount in all pools|
|`feeAmount`|`uint256`|Amount sent to treasury as fees|

### Claimed
Emitted when a user claims their winnings


```solidity
event Claimed(address indexed user, uint256 payout);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`user`|`address`|Address claiming rewards|
|`payout`|`uint256`|Amount of tokens paid out|

### CutoffUpdated
Emitted when betting cutoff time is updated


```solidity
event CutoffUpdated(uint64 newCutoff);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`newCutoff`|`uint64`|New cutoff timestamp|

### TreasuryUpdated
Emitted when treasury address is updated


```solidity
event TreasuryUpdated(address newTreasury);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`newTreasury`|`address`|New treasury address|

### FeeUpdated
Emitted when fee percentage is updated


```solidity
event FeeUpdated(uint16 newFeeBps);
```

**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`newFeeBps`|`uint16`|New fee in basis points|

## Errors
### InvalidOutcome
Thrown when an invalid outcome index is provided


```solidity
error InvalidOutcome();
```

### InvalidParam
Thrown when an invalid parameter is provided during initialization


```solidity
error InvalidParam();
```

### BettingClosed
Thrown when attempting to bet after cutoff time


```solidity
error BettingClosed();
```

### AlreadySettled
Thrown when attempting to settle an already settled match


```solidity
error AlreadySettled();
```

### NotSettled
Thrown when attempting an action that requires settlement first


```solidity
error NotSettled();
```

### NothingToClaim
Thrown when a user has no winnings to claim


```solidity
error NothingToClaim();
```

### ZeroAddress
Thrown when a zero address is provided where not allowed


```solidity
error ZeroAddress();
```

### TooManyOutcomes
Thrown when outcomes count exceeds maximum allowed (16)


```solidity
error TooManyOutcomes();
```

