// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "./BettingMatch.sol";

/**
 * @title FootballMatch
 * @notice Football-specific betting contract with dynamic odds support
 * @dev Inherits BettingMatch for odds management, implements football-specific markets
 */
contract FootballMatch is BettingMatch {
    
    // ══════════════════════════════════════════════════════════════════════════
    // FOOTBALL MARKET TYPES
    // ══════════════════════════════════════════════════════════════════════════
    
    /// @notice Football market type identifiers (bytes32 for gas efficiency)
    bytes32 public constant MARKET_WINNER = keccak256("WINNER");           // 1X2: Home(0)/Draw(1)/Away(2)
    bytes32 public constant MARKET_GOALS_TOTAL = keccak256("GOALS_TOTAL"); // Over/Under
    bytes32 public constant MARKET_BOTH_SCORE = keccak256("BOTH_SCORE");   // Yes(1)/No(0)
    bytes32 public constant MARKET_HALFTIME = keccak256("HALFTIME");       // 1X2 at halftime
    bytes32 public constant MARKET_CORRECT_SCORE = keccak256("CORRECT_SCORE"); // Exact score
    bytes32 public constant MARKET_FIRST_SCORER = keccak256("FIRST_SCORER");   // Player ID

    // ══════════════════════════════════════════════════════════════════════════
    // STORAGE
    // ══════════════════════════════════════════════════════════════════════════
    
    /// @notice Football-specific market data
    struct FootballMarket {
        bytes32 marketType;
        int16   line;          // For O/U or spread (e.g., 2.5 goals = 25, stored as int16)
        uint8   maxSelections; // Maximum valid selection value
    }
    
    mapping(uint256 => FootballMarket) public footballMarkets;

    // ══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ══════════════════════════════════════════════════════════════════════════
    
    error InvalidMarketType(bytes32 marketType);
    error InvalidSelection(uint256 marketId, uint64 selection, uint8 maxAllowed);

    // ══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR & INITIALIZER
    // ══════════════════════════════════════════════════════════════════════════
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    /**
     * @notice Initialize the football match contract
     * @param _matchName Match name (e.g., "Barcelona vs Real Madrid")
     * @param _owner Owner address
     */
    function initialize(string memory _matchName, address _owner) external initializer {
        __BettingMatchV2_init(_matchName, "FOOTBALL", _owner);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // MARKET CREATION
    // ══════════════════════════════════════════════════════════════════════════
    
    /**
     * @notice Add a new football betting market
     * @param marketType Market type identifier
     * @param initialOdds Initial odds (x10000)
     */
    function addMarket(bytes32 marketType, uint32 initialOdds) 
        external 
        override 
        onlyRole(ADMIN_ROLE) 
    {
        _validateOdds(initialOdds);
        
        uint8 maxSelections = _getMaxSelections(marketType);
        
        uint256 marketId = marketCount++;
        
        // Initialize market core
        _marketCores[marketId] = MarketCore({
            state: MarketState.Inactive,
            result: 0,
            createdAt: uint40(block.timestamp),
            resolvedAt: 0,
            totalPool: 0
        });
        
        // Initialize football-specific data
        footballMarkets[marketId] = FootballMarket({
            marketType: marketType,
            line: 0,
            maxSelections: maxSelections
        });
        
        // Set initial odds
        _getOrCreateOddsIndex(marketId, initialOdds);
        _oddsRegistries[marketId].currentIndex = 1;
        
        emit MarketCreated(marketId, _marketTypeToString(marketType), initialOdds);
    }
    
    /**
     * @notice Add a market with a line (for O/U or spread)
     * @param marketType Market type
     * @param initialOdds Initial odds
     * @param line Line value (e.g., 25 = 2.5 goals)
     */
    function addMarketWithLine(bytes32 marketType, uint32 initialOdds, int16 line) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        _validateOdds(initialOdds);
        
        uint8 maxSelections = _getMaxSelections(marketType);
        
        uint256 marketId = marketCount++;
        
        _marketCores[marketId] = MarketCore({
            state: MarketState.Inactive,
            result: 0,
            createdAt: uint40(block.timestamp),
            resolvedAt: 0,
            totalPool: 0
        });
        
        footballMarkets[marketId] = FootballMarket({
            marketType: marketType,
            line: line,
            maxSelections: maxSelections
        });
        
        _getOrCreateOddsIndex(marketId, initialOdds);
        _oddsRegistries[marketId].currentIndex = 1;
        
        emit MarketCreated(marketId, _marketTypeToString(marketType), initialOdds);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // VALIDATION
    // ══════════════════════════════════════════════════════════════════════════
    
    /**
     * @notice Validate selection for football market
     */
    function _validateSelection(uint256 marketId, uint64 selection) internal view override {
        FootballMarket storage fm = footballMarkets[marketId];
        if (selection > fm.maxSelections) {
            revert InvalidSelection(marketId, selection, fm.maxSelections);
        }
    }
    
    /**
     * @notice Get max valid selection for market type
     */
    function _getMaxSelections(bytes32 marketType) internal pure returns (uint8) {
        if (marketType == MARKET_WINNER) return 2;          // 0,1,2 (Home/Draw/Away)
        if (marketType == MARKET_GOALS_TOTAL) return 1;     // 0,1 (Under/Over)
        if (marketType == MARKET_BOTH_SCORE) return 1;      // 0,1 (No/Yes)
        if (marketType == MARKET_HALFTIME) return 2;        // 0,1,2
        if (marketType == MARKET_CORRECT_SCORE) return 99;  // Encoded scores
        if (marketType == MARKET_FIRST_SCORER) return 255;  // Player IDs
        revert InvalidMarketType(marketType);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════════════════════════
    
    /**
     * @notice Get complete market information
     */
    function getMarketInfo(uint256 marketId) 
        external 
        view 
        override 
        validMarket(marketId) 
        returns (
            bytes32 marketType,
            MarketState state,
            uint32 currentOdds,
            uint64 result,
            uint256 totalPool
        ) 
    {
        FootballMarket storage fm = footballMarkets[marketId];
        MarketCore storage core = _marketCores[marketId];
        
        marketType = fm.marketType;
        state = core.state;
        currentOdds = _getCurrentOdds(marketId);
        result = core.result;
        totalPool = core.totalPool;
    }
    
    /**
     * @notice Get football-specific market details
     */
    function getFootballMarket(uint256 marketId) 
        external 
        view 
        validMarket(marketId) 
        returns (
            string memory marketTypeStr,
            int16 line,
            uint8 maxSelections,
            MarketState state,
            uint32 currentOdds,
            uint64 result,
            uint256 totalPool
        ) 
    {
        FootballMarket storage fm = footballMarkets[marketId];
        MarketCore storage core = _marketCores[marketId];
        
        marketTypeStr = _marketTypeToString(fm.marketType);
        line = fm.line;
        maxSelections = fm.maxSelections;
        state = core.state;
        currentOdds = _getCurrentOdds(marketId);
        result = core.result;
        totalPool = core.totalPool;
    }
    
    /**
     * @notice Convert market type to string for events
     */
    function _marketTypeToString(bytes32 marketType) internal pure returns (string memory) {
        if (marketType == MARKET_WINNER) return "WINNER";
        if (marketType == MARKET_GOALS_TOTAL) return "GOALS_TOTAL";
        if (marketType == MARKET_BOTH_SCORE) return "BOTH_SCORE";
        if (marketType == MARKET_HALFTIME) return "HALFTIME";
        if (marketType == MARKET_CORRECT_SCORE) return "CORRECT_SCORE";
        if (marketType == MARKET_FIRST_SCORER) return "FIRST_SCORER";
        return "UNKNOWN";
    }

    // ══════════════════════════════════════════════════════════════════════════
    // STORAGE GAP
    // ══════════════════════════════════════════════════════════════════════════
    
    uint256[48] private __gap_football;
}
