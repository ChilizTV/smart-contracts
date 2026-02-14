// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/**
 * @title BettingMatchV2
 * @author Chiliz Team
 * @notice Abstract base contract for UUPS-upgradeable sports betting with dynamic odds
 * 
 * @dev Architecture Overview:
 * ┌─────────────────────────────────────────────────────────────────────────────┐
 * │                           DYNAMIC ODDS SYSTEM                               │
 * ├─────────────────────────────────────────────────────────────────────────────┤
 * │  Market                                                                     │
 * │  ├── oddsRegistry: uint32[] (append-only list of unique odds values)        │
 * │  ├── oddsToIndex: mapping(uint32 => uint16) (O(1) lookup)                   │
 * │  ├── currentOddsIndex: uint16 (pointer to active odds)                      │
 * │  └── bets: mapping(address => Bet[])                                      │
 * │           └── Bet: { amount, selection, oddsIndex, claimed }              │
 * └─────────────────────────────────────────────────────────────────────────────┘
 * 
 * Odds Precision: oddsX10000 (4 decimal places)
 *   - 1.01x = 10100, 2.18x = 21800, 100.00x = 1000000
 *   - Bounds: [10001, 1000000] → (1.0001x to 100.00x)
 * 
 * Gas Optimization Analysis:
 * ┌────────────────────────────────┬───────────────────┬───────────────────────┐
 * │ Approach                       │ Storage Cost      │ Trade-off             │
 * ├────────────────────────────────┼───────────────────┼───────────────────────┤
 * │ A) Direct odds per bet (uint32)│ 32 bits/bet       │ Simple, no lookup     │
 * │ B) OddsIndex (uint16) + array  │ 16 bits/bet +     │ Dedupe saves gas when │
 * │                                │ 32 bits/unique    │ many bets share odds  │
 * └────────────────────────────────┴───────────────────┴───────────────────────┘
 * 
 * Choice: Approach B with uint16 oddsIndex
 *   - Max 65535 unique odds per market (more than sufficient)
 *   - Saves 16 bits per bet when odds are shared (common case)
 *   - O(1) lookup via oddsToIndex mapping
 */
abstract contract BettingMatch is 
    Initializable, 
    OwnableUpgradeable, 
    AccessControlUpgradeable, 
    UUPSUpgradeable, 
    ReentrancyGuardUpgradeable, 
    PausableUpgradeable 
{
    // ══════════════════════════════════════════════════════════════════════════
    // CONSTANTS & ROLES
    // ══════════════════════════════════════════════════════════════════════════
    
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant RESOLVER_ROLE = keccak256("RESOLVER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    bytes32 public constant ODDS_SETTER_ROLE = keccak256("ODDS_SETTER_ROLE");
    
    /// @notice Odds precision: multiply by 10000 (4 decimals)
    /// @dev 2.18x = 21800, min 1.0001x = 10001, max 100x = 1000000
    uint32 public constant ODDS_PRECISION = 10000;
    uint32 public constant MIN_ODDS = 10001;   // 1.0001x minimum
    uint32 public constant MAX_ODDS = 1000000; // 100.00x maximum
    
    // ══════════════════════════════════════════════════════════════════════════
    // ENUMS
    // ══════════════════════════════════════════════════════════════════════════
    
    /// @notice Market lifecycle states
    enum MarketState { 
        Inactive,   // Not yet opened for betting
        Open,       // Accepting bets
        Suspended,  // Temporarily paused (e.g., match started)
        Closed,     // No more bets, awaiting result
        Resolved,   // Result set, payouts available
        Cancelled   // Refunds available
    }

    // ══════════════════════════════════════════════════════════════════════════
    // STRUCTS
    // ══════════════════════════════════════════════════════════════════════════
    
    /**
     * @notice Individual bet with odds snapshot
     * @dev Packed into 2 storage slots:
     *      Slot 1: amount (256 bits)
     *      Slot 2: selection (64) + oddsIndex (16) + timestamp (40) + claimed (8) = 128 bits
     */
    struct Bet {
        uint256 amount;       // Bet amount in CHZ (wei)
        uint64  selection;    // Encoded user pick (outcome ID)
        uint16  oddsIndex;    // Index into market's oddsRegistry
        uint40  timestamp;    // Block timestamp when bet was placed
        bool    claimed;      // Whether payout/refund was claimed
    }
    
    /**
     * @notice Odds registry for a market (gas-optimized deduplication)
     * @dev Append-only array + reverse mapping for O(1) lookup
     */
    struct OddsRegistry {
        uint32[] values;                    // Unique odds values (append-only)
        mapping(uint32 => uint16) toIndex;  // odds value => index (1-based, 0 = not found)
        uint16 currentIndex;                // Active odds index for new bets
    }
    
    /**
     * @notice Base market data (extended by sport-specific contracts)
     */
    struct MarketCore {
        MarketState state;
        uint64      result;          // Encoded result (set on resolution)
        uint40      createdAt;
        uint40      resolvedAt;
        uint256     totalPool;       // Total CHZ wagered
    }

    // ══════════════════════════════════════════════════════════════════════════
    // STORAGE (Upgrade-safe layout)
    // ══════════════════════════════════════════════════════════════════════════
    
    /// @notice Human-readable name of the match
    string public matchName;
    
    /// @notice Sport type identifier (e.g., "FOOTBALL", "BASKETBALL")
    string public sportType;
    
    /// @notice Number of markets created
    uint256 public marketCount;
    
    /// @notice Odds registries per market
    mapping(uint256 => OddsRegistry) internal _oddsRegistries;
    
    /// @notice User bets per market (supports multiple bets per user at different odds)
    mapping(uint256 => mapping(address => Bet[])) internal _userBets;
    
    /// @notice Market core data
    mapping(uint256 => MarketCore) internal _marketCores;

    // ══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ══════════════════════════════════════════════════════════════════════════
    
    event MatchInitialized(string indexed name, string sportType, address indexed owner);
    event MarketCreated(uint256 indexed marketId, string marketType, uint32 initialOdds);
    event MarketStateChanged(uint256 indexed marketId, MarketState oldState, MarketState newState);
    event OddsUpdated(uint256 indexed marketId, uint32 oldOdds, uint32 newOdds, uint16 oddsIndex);
    event BetPlaced(
        uint256 indexed marketId, 
        address indexed user, 
        uint256 betIndex,
        uint256 amount, 
        uint64 selection, 
        uint32 odds,
        uint16 oddsIndex
    );
    event MarketResolved(uint256 indexed marketId, uint64 result, uint40 resolvedAt);
    event MarketCancelled(uint256 indexed marketId, string reason);
    event Payout(uint256 indexed marketId, address indexed user, uint256 betIndex, uint256 amount);
    event Refund(uint256 indexed marketId, address indexed user, uint256 betIndex, uint256 amount);

    // ══════════════════════════════════════════════════════════════════════════
    // CUSTOM ERRORS
    // ══════════════════════════════════════════════════════════════════════════
    
    error InvalidMarketId(uint256 marketId);
    error InvalidMarketState(uint256 marketId, MarketState current, MarketState required);
    error InvalidOddsValue(uint32 odds, uint32 min, uint32 max);
    error OddsNotSet(uint256 marketId);
    error ZeroBetAmount();
    error BetNotFound(uint256 marketId, address user, uint256 betIndex);
    error AlreadyClaimed(uint256 marketId, address user, uint256 betIndex);
    error BetLost(uint256 marketId, address user, uint256 betIndex);
    error InsufficientContractBalance(uint256 required, uint256 available);
    error TransferFailed(address to, uint256 amount);
    error MarketNotCancelled(uint256 marketId);
    error ContractNotPaused();
    error MaxOddsEntriesReached(uint256 marketId);

    // ══════════════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ══════════════════════════════════════════════════════════════════════════
    
    modifier validMarket(uint256 marketId) {
        _validMarket(marketId);
        _;
    }
    
    modifier inState(uint256 marketId, MarketState required) {
        _inState(marketId, required);
        _;
    }

    function _validMarket(uint256 marketId) internal view {
        if (marketId >= marketCount) revert InvalidMarketId(marketId);
    }

    function _inState(uint256 marketId, MarketState required) internal view {
        MarketState current = _marketCores[marketId].state;
        if (current != required) {
            revert InvalidMarketState(marketId, current, required);
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    // INITIALIZER
    // ══════════════════════════════════════════════════════════════════════════
    
    /**
     * @notice Initialize the betting match contract
     * @param _matchName Descriptive name of this match
     * @param _sportType Sport identifier (e.g., "FOOTBALL")
     * @param _owner Owner/admin address
     */
    // forge-lint: disable-next-line(mixed-case-function)
    function __BettingMatchV2_init(
        string memory _matchName, 
        string memory _sportType, 
        address _owner
    ) internal onlyInitializing {
        __Ownable_init(_owner);
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        
        // Grant all roles to owner
        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
        _grantRole(ADMIN_ROLE, _owner);
        _grantRole(RESOLVER_ROLE, _owner);
        _grantRole(PAUSER_ROLE, _owner);
        _grantRole(TREASURY_ROLE, _owner);
        _grantRole(ODDS_SETTER_ROLE, _owner);
        
        matchName = _matchName;
        sportType = _sportType;
        
        emit MatchInitialized(_matchName, _sportType, _owner);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ODDS MANAGEMENT
    // ══════════════════════════════════════════════════════════════════════════
    
    /**
     * @notice Set new odds for a market (can be called multiple times)
     * @param marketId Market identifier
     * @param newOdds New odds value (x10000 precision)
     * @dev 
     *   - If odds already exists in registry, reuses existing index
     *   - If new odds, appends to registry and creates new index
     *   - O(1) lookup via oddsToIndex mapping
     */
    function setMarketOdds(uint256 marketId, uint32 newOdds) 
        external 
        validMarket(marketId)
        onlyRole(ODDS_SETTER_ROLE) 
    {
        _validateOdds(newOdds);
        
        MarketCore storage core = _marketCores[marketId];
        // Can only set odds when market is Open or Inactive
        if (core.state != MarketState.Open && core.state != MarketState.Inactive) {
            revert InvalidMarketState(marketId, core.state, MarketState.Open);
        }
        
        OddsRegistry storage registry = _oddsRegistries[marketId];
        uint32 oldOdds = _getCurrentOdds(marketId);
        
        uint16 newIndex = _getOrCreateOddsIndex(marketId, newOdds);
        registry.currentIndex = newIndex;
        
        emit OddsUpdated(marketId, oldOdds, newOdds, newIndex);
    }
    
    /**
     * @notice Get or create an odds index for a value
     * @param marketId Market identifier  
     * @param odds Odds value to find/create
     * @return index The odds index (1-based)
     */
    function _getOrCreateOddsIndex(uint256 marketId, uint32 odds) internal returns (uint16 index) {
        OddsRegistry storage registry = _oddsRegistries[marketId];
        
        // Check if odds already exists (1-based index, 0 means not found)
        index = registry.toIndex[odds];
        if (index != 0) {
            return index;
        }
        
        // Safety check: max 65534 unique odds per market (uint16 - 1 for 0-sentinel)
        if (registry.values.length >= 65534) {
            revert MaxOddsEntriesReached(marketId);
        }
        
        // Append new odds
        registry.values.push(odds);
        index = uint16(registry.values.length); // 1-based
        registry.toIndex[odds] = index;
        
        return index;
    }
    
    /**
     * @notice Get current active odds for a market
     * @param marketId Market identifier
     * @return Current odds value (0 if not set)
     */
    function _getCurrentOdds(uint256 marketId) internal view returns (uint32) {
        OddsRegistry storage registry = _oddsRegistries[marketId];
        if (registry.currentIndex == 0) return 0;
        return registry.values[registry.currentIndex - 1]; // Convert 1-based to 0-based
    }
    
    /**
     * @notice Get odds value by index
     * @param marketId Market identifier
     * @param oddsIndex Odds index (1-based)
     * @return Odds value
     */
    function _getOddsByIndex(uint256 marketId, uint16 oddsIndex) internal view returns (uint32) {
        if (oddsIndex == 0) return 0;
        return _oddsRegistries[marketId].values[oddsIndex - 1];
    }
    
    /**
     * @notice Validate odds bounds
     */
    function _validateOdds(uint32 odds) internal pure {
        if (odds < MIN_ODDS || odds > MAX_ODDS) {
            revert InvalidOddsValue(odds, MIN_ODDS, MAX_ODDS);
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    // MARKET STATE MANAGEMENT
    // ══════════════════════════════════════════════════════════════════════════
    
    /**
     * @notice Open a market for betting
     */
    function openMarket(uint256 marketId) 
        external 
        validMarket(marketId) 
        onlyRole(ADMIN_ROLE) 
    {
        _transitionMarketState(marketId, MarketState.Open);
    }
    
    /**
     * @notice Suspend betting temporarily (e.g., match started)
     */
    function suspendMarket(uint256 marketId) 
        external 
        validMarket(marketId) 
        onlyRole(ADMIN_ROLE) 
    {
        _transitionMarketState(marketId, MarketState.Suspended);
    }
    
    /**
     * @notice Close market for betting (awaiting result)
     */
    function closeMarket(uint256 marketId) 
        external 
        validMarket(marketId) 
        onlyRole(ADMIN_ROLE) 
    {
        _transitionMarketState(marketId, MarketState.Closed);
    }
    
    /**
     * @notice Cancel market and enable refunds
     */
    function cancelMarket(uint256 marketId, string calldata reason) 
        external 
        validMarket(marketId) 
        onlyRole(ADMIN_ROLE) 
    {
        _transitionMarketState(marketId, MarketState.Cancelled);
        emit MarketCancelled(marketId, reason);
    }
    
    function _transitionMarketState(uint256 marketId, MarketState newState) internal {
        MarketCore storage core = _marketCores[marketId];
        MarketState oldState = core.state;
        
        // State transition validation
        // Inactive -> Open
        // Open -> Suspended, Closed, Cancelled
        // Suspended -> Open, Closed, Cancelled  
        // Closed -> Resolved, Cancelled
        // Resolved/Cancelled -> terminal
        
        core.state = newState;
        emit MarketStateChanged(marketId, oldState, newState);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // BETTING CORE
    // ══════════════════════════════════════════════════════════════════════════
    
    /**
     * @notice Place a bet on a market
     * @param marketId Market identifier
     * @param selection Encoded user pick (outcome ID)
     * @dev
     *   - Uses current market odds at time of bet
     *   - Stores oddsIndex to save gas (not raw odds value)
     *   - Supports multiple bets per user at different odds
     */
    function placeBet(uint256 marketId, uint64 selection) 
        external 
        payable 
        validMarket(marketId)
        inState(marketId, MarketState.Open)
        whenNotPaused 
    {
        if (msg.value == 0) revert ZeroBetAmount();
        
        OddsRegistry storage registry = _oddsRegistries[marketId];
        if (registry.currentIndex == 0) revert OddsNotSet(marketId);
        
        uint16 oddsIndex = registry.currentIndex;
        uint32 odds = registry.values[oddsIndex - 1];
        
        // Validate selection via sport-specific hook
        _validateSelection(marketId, selection);
        
        // Create bet
        Bet memory newBet = Bet({
            amount: msg.value,
            selection: selection,
            oddsIndex: oddsIndex,
            timestamp: uint40(block.timestamp),
            claimed: false
        });
        
        _userBets[marketId][msg.sender].push(newBet);
        uint256 betIndex = _userBets[marketId][msg.sender].length - 1;
        
        // Update pool
        _marketCores[marketId].totalPool += msg.value;
        
        emit BetPlaced(marketId, msg.sender, betIndex, msg.value, selection, odds, oddsIndex);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // RESOLUTION & PAYOUTS
    // ══════════════════════════════════════════════════════════════════════════
    
    /**
     * @notice Resolve a market with the final result
     * @param marketId Market identifier
     * @param result Encoded result
     */
    function resolveMarket(uint256 marketId, uint64 result) 
        external 
        validMarket(marketId)
        onlyRole(RESOLVER_ROLE) 
    {
        MarketCore storage core = _marketCores[marketId];
        
        // Can resolve from Closed or Open state
        if (core.state != MarketState.Closed && core.state != MarketState.Open) {
            revert InvalidMarketState(marketId, core.state, MarketState.Closed);
        }
        
        core.result = result;
        core.resolvedAt = uint40(block.timestamp);
        core.state = MarketState.Resolved;
        
        emit MarketResolved(marketId, result, core.resolvedAt);
    }
    
    /**
     * @notice Claim payout for a winning bet
     * @param marketId Market identifier
     * @param betIndex Index of the bet in user's bet array
     */
    function claim(uint256 marketId, uint256 betIndex) 
        external 
        nonReentrant 
        validMarket(marketId)
        inState(marketId, MarketState.Resolved)
        whenNotPaused 
    {
        Bet[] storage userBets = _userBets[marketId][msg.sender];
        if (betIndex >= userBets.length) {
            revert BetNotFound(marketId, msg.sender, betIndex);
        }
        
        Bet storage bet = userBets[betIndex];
        if (bet.claimed) revert AlreadyClaimed(marketId, msg.sender, betIndex);
        
        MarketCore storage core = _marketCores[marketId];
        if (bet.selection != core.result) {
            revert BetLost(marketId, msg.sender, betIndex);
        }
        
        // Calculate payout using bet's odds (not current odds!)
        uint32 betOdds = _getOddsByIndex(marketId, bet.oddsIndex);
        uint256 payout = (bet.amount * betOdds) / ODDS_PRECISION;
        
        // CEI: Effects before Interactions
        bet.claimed = true;
        
        // Check balance
        if (address(this).balance < payout) {
            revert InsufficientContractBalance(payout, address(this).balance);
        }
        
        // Transfer
        (bool success, ) = payable(msg.sender).call{value: payout}("");
        if (!success) revert TransferFailed(msg.sender, payout);
        
        emit Payout(marketId, msg.sender, betIndex, payout);
    }
    
    /**
     * @notice Claim refund for a cancelled market
     * @param marketId Market identifier
     * @param betIndex Index of the bet in user's bet array
     */
    function claimRefund(uint256 marketId, uint256 betIndex) 
        external 
        nonReentrant 
        validMarket(marketId)
        inState(marketId, MarketState.Cancelled)
    {
        Bet[] storage userBets = _userBets[marketId][msg.sender];
        if (betIndex >= userBets.length) {
            revert BetNotFound(marketId, msg.sender, betIndex);
        }
        
        Bet storage bet = userBets[betIndex];
        if (bet.claimed) revert AlreadyClaimed(marketId, msg.sender, betIndex);
        
        uint256 refundAmount = bet.amount;
        
        // CEI
        bet.claimed = true;
        
        if (address(this).balance < refundAmount) {
            revert InsufficientContractBalance(refundAmount, address(this).balance);
        }
        
        (bool success, ) = payable(msg.sender).call{value: refundAmount}("");
        if (!success) revert TransferFailed(msg.sender, refundAmount);
        
        emit Refund(marketId, msg.sender, betIndex, refundAmount);
    }
    
    /**
     * @notice Batch claim all winning bets for a market
     * @param marketId Market identifier
     */
    function claimAll(uint256 marketId) 
        external 
        nonReentrant 
        validMarket(marketId)
        whenNotPaused 
    {
        MarketCore storage core = _marketCores[marketId];
        Bet[] storage userBets = _userBets[marketId][msg.sender];
        
        uint256 totalPayout = 0;
        
        for (uint256 i = 0; i < userBets.length; i++) {
            Bet storage bet = userBets[i];
            if (bet.claimed) continue;
            
            bool shouldPay = false;
            uint256 amount = 0;
            
            if (core.state == MarketState.Resolved && bet.selection == core.result) {
                uint32 betOdds = _getOddsByIndex(marketId, bet.oddsIndex);
                amount = (bet.amount * betOdds) / ODDS_PRECISION;
                shouldPay = true;
            } else if (core.state == MarketState.Cancelled) {
                amount = bet.amount;
                shouldPay = true;
            }
            
            if (shouldPay) {
                bet.claimed = true;
                totalPayout += amount;
                
                if (core.state == MarketState.Cancelled) {
                    emit Refund(marketId, msg.sender, i, amount);
                } else {
                    emit Payout(marketId, msg.sender, i, amount);
                }
            }
        }
        
        if (totalPayout > 0) {
            if (address(this).balance < totalPayout) {
                revert InsufficientContractBalance(totalPayout, address(this).balance);
            }
            
            (bool success, ) = payable(msg.sender).call{value: totalPayout}("");
            if (!success) revert TransferFailed(msg.sender, totalPayout);
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════════════════════════
    
    /**
     * @notice Get current odds for a market
     */
    function getCurrentOdds(uint256 marketId) external view validMarket(marketId) returns (uint32) {
        return _getCurrentOdds(marketId);
    }
    
    /**
     * @notice Get all odds ever used in a market
     */
    function getOddsHistory(uint256 marketId) external view validMarket(marketId) returns (uint32[] memory) {
        return _oddsRegistries[marketId].values;
    }
    
    /**
     * @notice Get user's bets for a market
     */
    function getUserBets(uint256 marketId, address user) 
        external 
        view 
        validMarket(marketId) 
        returns (Bet[] memory) 
    {
        return _userBets[marketId][user];
    }
    
    /**
     * @notice Get specific bet details including odds value
     */
    function getBetDetails(uint256 marketId, address user, uint256 betIndex) 
        external 
        view 
        validMarket(marketId) 
        returns (
            uint256 amount,
            uint64 selection,
            uint32 odds,
            uint40 timestamp,
            bool claimed,
            uint256 potentialPayout
        ) 
    {
        Bet[] storage userBets = _userBets[marketId][user];
        if (betIndex >= userBets.length) revert BetNotFound(marketId, user, betIndex);
        
        Bet storage bet = userBets[betIndex];
        uint32 betOdds = _getOddsByIndex(marketId, bet.oddsIndex);
        
        return (
            bet.amount,
            bet.selection,
            betOdds,
            bet.timestamp,
            bet.claimed,
            (bet.amount * betOdds) / ODDS_PRECISION
        );
    }
    
    /**
     * @notice Get market core information
     */
    function getMarketCore(uint256 marketId) 
        external 
        view 
        validMarket(marketId) 
        returns (MarketCore memory) 
    {
        return _marketCores[marketId];
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ══════════════════════════════════════════════════════════════════════════
    
    function emergencyPause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }
    
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
    
    function emergencyWithdraw(uint256 amount) external onlyRole(TREASURY_ROLE) {
        if (!paused()) revert ContractNotPaused();
        if (amount > address(this).balance) {
            revert InsufficientContractBalance(amount, address(this).balance);
        }
        
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        if (!success) revert TransferFailed(msg.sender, amount);
    }
    
    receive() external payable {}
    
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ══════════════════════════════════════════════════════════════════════════
    // ABSTRACT FUNCTIONS (Sport-specific implementation)
    // ══════════════════════════════════════════════════════════════════════════
    
    /**
     * @notice Validate that selection is valid for the market type
     * @dev Override in sport-specific contracts
     */
    function _validateSelection(uint256 marketId, uint64 selection) internal view virtual;
    
    /**
     * @notice Create a new market (sport-specific)
     */
    function addMarket(bytes32 marketType, uint32 initialOdds) external virtual;
    
    /**
     * @notice Get market type information (sport-specific)
     */
    function getMarketInfo(uint256 marketId) external view virtual returns (
        bytes32 marketType,
        MarketState state,
        uint32 currentOdds,
        uint64 result,
        uint256 totalPool
    );

    // ══════════════════════════════════════════════════════════════════════════
    // STORAGE GAP
    // ══════════════════════════════════════════════════════════════════════════
    
    uint256[40] private __gap;
}
