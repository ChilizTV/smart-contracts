// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BettingMatch.sol";

/// @title FootballMatch
/// @notice Football-specific betting contract with markets like Winner, GoalsCount, FirstScorer, etc.
contract FootballMatch is BettingMatch {
    /// @notice Types of markets available for football
    enum FootballMarketType { 
        Winner,          // Home/Draw/Away (0/1/2)
        GoalsCount,      // Total goals (0, 1, 2, 3+)
        FirstScorer,     // Player ID who scores first
        BothTeamsScore,  // Yes/No (1/0)
        HalfTimeResult,  // Home/Draw/Away at HT
        CorrectScore     // Exact score (encoded)
    }

    /// @notice A football-specific market
    struct FootballMarket {
        FootballMarketType mtype;
        uint256            odds;
        State              state;
        uint256            result;
        bool               cancelled;  // market cancellation flag
        mapping(address => Bet) bets;
    }

    /// @notice Mapping: marketId → FootballMarket
    mapping(uint256 => FootballMarket) public footballMarkets;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize a football match
    /// @param _matchName descriptive name (e.g., "Barcelona vs Real Madrid")
    /// @param _owner owner/admin address
    function initialize(string memory _matchName, address _owner) external initializer {
        __BettingMatch_init(_matchName, "FOOTBALL", _owner);
    }

    /// @notice Add a new football market
    /// @param marketType string representation of FootballMarketType (e.g., "Winner", "GoalsCount")
    /// @param odds multiplier ×100 (e.g., 200 = 2.0x)
    function addMarket(string calldata marketType, uint256 odds) external override onlyRole(ADMIN_ROLE) {
        // CRITICAL: Validate odds (1.01x to 100x)
        if (odds < 101 || odds > 10000) revert InvalidOdds();
        
        uint256 mid = marketCount++;
        FootballMarket storage m = footballMarkets[mid];
        m.mtype = _parseFootballMarketType(marketType);
        m.odds = odds;
        m.state = State.Live;
        emit MarketAdded(mid, marketType, odds);
    }

    /// @notice Internal function to store a football bet
    function _storeBet(uint256 marketId, address user, uint256 amount, uint256 selection) internal override {
        FootballMarket storage m = footballMarkets[marketId];
        if (m.state != State.Live) revert WrongState(State.Live);
        
        // CRITICAL: Prevent double betting
        if (m.bets[user].amount > 0) revert AlreadyBet();
        
        m.bets[user] = Bet({ amount: amount, selection: selection, claimed: false });
    }

    /// @notice Internal function to resolve a football market
    function _resolveMarketInternal(uint256 marketId, uint256 result) internal override {
        FootballMarket storage m = footballMarkets[marketId];
        if (m.state != State.Live) revert WrongState(State.Live);
        
        m.result = result;
        m.state = State.Ended;
    }

    /// @notice Internal helper to get market and bet data for claim logic
    function _getMarketAndBet(uint256 marketId, address user) internal view override returns (
        uint256 odds,
        State state,
        uint256 result,
        Bet storage userBet
    ) {
        FootballMarket storage m = footballMarkets[marketId];
        return (m.odds, m.state, m.result, m.bets[user]);
    }

    /// @notice Get football market details
    function getMarket(uint256 marketId) external view override returns (
        string memory marketType,
        uint256 odds,
        State state,
        uint256 result
    ) {
        if (marketId >= marketCount) revert InvalidMarket(marketId);
        FootballMarket storage m = footballMarkets[marketId];
        return (
            _footballMarketTypeToString(m.mtype),
            m.odds,
            m.state,
            m.result
        );
    }

    /// @notice Get user's bet on a football market
    function getBet(uint256 marketId, address user) external view override returns (
        uint256 amount,
        uint256 selection,
        bool claimed
    ) {
        if (marketId >= marketCount) revert InvalidMarket(marketId);
        Bet storage b = footballMarkets[marketId].bets[user];
        return (b.amount, b.selection, b.claimed);
    }

    /// @notice Parse string to FootballMarketType enum
    function _parseFootballMarketType(string calldata marketType) internal pure returns (FootballMarketType) {
        bytes32 hash = keccak256(bytes(marketType));
        if (hash == keccak256("Winner")) return FootballMarketType.Winner;
        if (hash == keccak256("GoalsCount")) return FootballMarketType.GoalsCount;
        if (hash == keccak256("FirstScorer")) return FootballMarketType.FirstScorer;
        if (hash == keccak256("BothTeamsScore")) return FootballMarketType.BothTeamsScore;
        if (hash == keccak256("HalfTimeResult")) return FootballMarketType.HalfTimeResult;
        if (hash == keccak256("CorrectScore")) return FootballMarketType.CorrectScore;
        revert("Invalid market type");
    }

    /// @notice Convert FootballMarketType enum to string
    function _footballMarketTypeToString(FootballMarketType mtype) internal pure returns (string memory) {
        if (mtype == FootballMarketType.Winner) return "Winner";
        if (mtype == FootballMarketType.GoalsCount) return "GoalsCount";
        if (mtype == FootballMarketType.FirstScorer) return "FirstScorer";
        if (mtype == FootballMarketType.BothTeamsScore) return "BothTeamsScore";
        if (mtype == FootballMarketType.HalfTimeResult) return "HalfTimeResult";
        if (mtype == FootballMarketType.CorrectScore) return "CorrectScore";
        return "Unknown";
    }

    /// @notice Internal function to cancel a football market
    function _cancelMarketInternal(uint256 marketId) internal override {
        FootballMarket storage m = footballMarkets[marketId];
        if (m.state == State.Ended && m.cancelled) revert("Market already resolved or cancelled");
        m.cancelled = true;
    }

    /// @notice Internal function to check if market is cancelled and get bet
    function _getMarketCancellationStatus(uint256 marketId, address user) internal view override returns (
        Bet storage userBet,
        bool isCancelled
    ) {
        FootballMarket storage m = footballMarkets[marketId];
        return (m.bets[user], m.cancelled);
    }
}
