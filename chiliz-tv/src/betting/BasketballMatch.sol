// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BettingMatch} from "./BettingMatch.sol";

/**
 * @title BasketballMatch
 * @notice Basketball-specific betting contract with dynamic odds support
 * @dev Inherits BettingMatch for odds management, implements basketball-specific markets
 */
contract BasketballMatch is BettingMatch {
    
    // ══════════════════════════════════════════════════════════════════════════
    // BASKETBALL MARKET TYPES
    // ══════════════════════════════════════════════════════════════════════════
    
    bytes32 public constant MARKET_WINNER = keccak256("WINNER");             // Home(0)/Away(1)
    bytes32 public constant MARKET_TOTAL_POINTS = keccak256("TOTAL_POINTS"); // Over/Under
    bytes32 public constant MARKET_SPREAD = keccak256("SPREAD");             // Point spread
    bytes32 public constant MARKET_QUARTER_WINNER = keccak256("QUARTER_WINNER");
    bytes32 public constant MARKET_FIRST_TO_SCORE = keccak256("FIRST_TO_SCORE");
    bytes32 public constant MARKET_HIGHEST_QUARTER = keccak256("HIGHEST_QUARTER");

    // ══════════════════════════════════════════════════════════════════════════
    // STORAGE
    // ══════════════════════════════════════════════════════════════════════════
    
    struct BasketballMarket {
        bytes32 marketType;
        int16   line;          // For O/U or spread (e.g., 215.5 = 2155)
        uint8   quarter;       // For quarter-specific markets (1-4, 0 = full game)
        uint8   maxSelections;
    }
    
    mapping(uint256 => BasketballMarket) public basketballMarkets;

    // ══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ══════════════════════════════════════════════════════════════════════════
    
    error InvalidMarketType(bytes32 marketType);
    error InvalidSelection(uint256 marketId, uint64 selection, uint8 maxAllowed);
    error InvalidQuarter(uint8 quarter);

    // ══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR & INITIALIZER
    // ══════════════════════════════════════════════════════════════════════════
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    function initialize(string memory _matchName, address _owner) external initializer {
        __BettingMatchV2_init(_matchName, "BASKETBALL", _owner);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // MARKET CREATION
    // ══════════════════════════════════════════════════════════════════════════
    
    function addMarket(bytes32 marketType, uint32 initialOdds) 
        external 
        override 
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
        
        basketballMarkets[marketId] = BasketballMarket({
            marketType: marketType,
            line: 0,
            quarter: 0,
            maxSelections: maxSelections
        });
        
        _getOrCreateOddsIndex(marketId, initialOdds);
        _oddsRegistries[marketId].currentIndex = 1;
        
        emit MarketCreated(marketId, _marketTypeToString(marketType), initialOdds);
    }
    
    function addMarketWithLine(bytes32 marketType, uint32 initialOdds, int16 line, uint8 quarter) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        _validateOdds(initialOdds);
        if (quarter > 4) revert InvalidQuarter(quarter);
        
        uint8 maxSelections = _getMaxSelections(marketType);
        
        uint256 marketId = marketCount++;
        
        _marketCores[marketId] = MarketCore({
            state: MarketState.Inactive,
            result: 0,
            createdAt: uint40(block.timestamp),
            resolvedAt: 0,
            totalPool: 0
        });
        
        basketballMarkets[marketId] = BasketballMarket({
            marketType: marketType,
            line: line,
            quarter: quarter,
            maxSelections: maxSelections
        });
        
        _getOrCreateOddsIndex(marketId, initialOdds);
        _oddsRegistries[marketId].currentIndex = 1;
        
        emit MarketCreated(marketId, _marketTypeToString(marketType), initialOdds);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // VALIDATION
    // ══════════════════════════════════════════════════════════════════════════
    
    function _validateSelection(uint256 marketId, uint64 selection) internal view override {
        BasketballMarket storage bm = basketballMarkets[marketId];
        if (selection > bm.maxSelections) {
            revert InvalidSelection(marketId, selection, bm.maxSelections);
        }
    }
    
    function _getMaxSelections(bytes32 marketType) internal pure returns (uint8) {
        if (marketType == MARKET_WINNER) return 1;           // 0,1 (Home/Away)
        if (marketType == MARKET_TOTAL_POINTS) return 1;     // 0,1 (Under/Over)
        if (marketType == MARKET_SPREAD) return 1;           // 0,1 (Home covers/Away covers)
        if (marketType == MARKET_QUARTER_WINNER) return 1;   // 0,1
        if (marketType == MARKET_FIRST_TO_SCORE) return 1;   // 0,1
        if (marketType == MARKET_HIGHEST_QUARTER) return 3;  // 0,1,2,3 (Q1/Q2/Q3/Q4)
        revert InvalidMarketType(marketType);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════════════════════════
    
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
        BasketballMarket storage bm = basketballMarkets[marketId];
        MarketCore storage core = _marketCores[marketId];
        
        marketType = bm.marketType;
        state = core.state;
        currentOdds = _getCurrentOdds(marketId);
        result = core.result;
        totalPool = core.totalPool;
    }
    
    function getBasketballMarket(uint256 marketId) 
        external 
        view 
        validMarket(marketId) 
        returns (
            string memory marketTypeStr,
            int16 line,
            uint8 quarter,
            uint8 maxSelections,
            MarketState state,
            uint32 currentOdds,
            uint64 result,
            uint256 totalPool
        ) 
    {
        BasketballMarket storage bm = basketballMarkets[marketId];
        MarketCore storage core = _marketCores[marketId];
        
        marketTypeStr = _marketTypeToString(bm.marketType);
        line = bm.line;
        quarter = bm.quarter;
        maxSelections = bm.maxSelections;
        state = core.state;
        currentOdds = _getCurrentOdds(marketId);
        result = core.result;
        totalPool = core.totalPool;
    }
    
    function _marketTypeToString(bytes32 marketType) internal pure returns (string memory) {
        if (marketType == MARKET_WINNER) return "WINNER";
        if (marketType == MARKET_TOTAL_POINTS) return "TOTAL_POINTS";
        if (marketType == MARKET_SPREAD) return "SPREAD";
        if (marketType == MARKET_QUARTER_WINNER) return "QUARTER_WINNER";
        if (marketType == MARKET_FIRST_TO_SCORE) return "FIRST_TO_SCORE";
        if (marketType == MARKET_HIGHEST_QUARTER) return "HIGHEST_QUARTER";
        return "UNKNOWN";
    }

    // ══════════════════════════════════════════════════════════════════════════
    // STORAGE GAP
    // ══════════════════════════════════════════════════════════════════════════
    
    // forge-lint: disable-next-line(mixed-case-variable)
    uint256[48] private __gap_basketball;
}
