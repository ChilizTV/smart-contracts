// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BettingMatch.sol";

/// @title BasketballMatch
/// @notice Basketball-specific betting contract with markets like Winner, TotalPoints, PointSpread, etc.
contract BasketballMatch is BettingMatch {
    /// @notice Types of markets available for basketball
    enum BasketballMarketType { 
        Winner,           // Home/Away (0/1)
        TotalPoints,      // Over/Under total points
        PointSpread,      // Home + spread vs Away
        QuarterWinner,    // Winner of specific quarter
        FirstToScore,     // Team to score first (Home=0, Away=1)
        HighestScoringQuarter  // Which quarter has most points (1/2/3/4)
    }

    /// @notice A basketball-specific market
    struct BasketballMarket {
        BasketballMarketType mtype;
        uint256              odds;
        State                state;
        uint256              result;
        bool                 cancelled;  // market cancellation flag
        mapping(address => Bet) bets;
    }

    /// @notice Mapping: marketId → BasketballMarket
    mapping(uint256 => BasketballMarket) public basketballMarkets;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize a basketball match
    /// @param _matchName descriptive name (e.g., "Lakers vs Celtics")
    /// @param _owner owner/admin address
    function initialize(string memory _matchName, address _owner) external initializer {
        __BettingMatch_init(_matchName, "BASKETBALL", _owner);
    }

    /// @notice Add a new basketball market
    /// @param marketType string representation of BasketballMarketType
    /// @param odds multiplier ×100 (e.g., 180 = 1.8x)
    function addMarket(string calldata marketType, uint256 odds) external override onlyRole(ADMIN_ROLE) {
        // CRITICAL: Validate odds (1.01x to 100x)
        if (odds < 101 || odds > 10000) revert InvalidOdds();
        
        uint256 mid = marketCount++;
        BasketballMarket storage m = basketballMarkets[mid];
        m.mtype = _parseBasketballMarketType(marketType);
        m.odds = odds;
        m.state = State.Live;
        emit MarketAdded(mid, marketType, odds);
    }

    /// @notice Internal function to store a basketball bet
    function _storeBet(uint256 marketId, address user, uint256 amount, uint256 selection) internal override {
        BasketballMarket storage m = basketballMarkets[marketId];
        if (m.state != State.Live) revert WrongState(State.Live);
        
        // CRITICAL: Prevent double betting
        if (m.bets[user].amount > 0) revert AlreadyBet();
        
        m.bets[user] = Bet({ amount: amount, selection: selection, claimed: false });
    }

    /// @notice Internal function to resolve a basketball market
    function _resolveMarketInternal(uint256 marketId, uint256 result) internal override {
        BasketballMarket storage m = basketballMarkets[marketId];
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
        BasketballMarket storage m = basketballMarkets[marketId];
        return (m.odds, m.state, m.result, m.bets[user]);
    }

    /// @notice Get basketball market details
    function getMarket(uint256 marketId) external view override returns (
        string memory marketType,
        uint256 odds,
        State state,
        uint256 result
    ) {
        if (marketId >= marketCount) revert InvalidMarket(marketId);
        BasketballMarket storage m = basketballMarkets[marketId];
        return (
            _basketballMarketTypeToString(m.mtype),
            m.odds,
            m.state,
            m.result
        );
    }

    /// @notice Get user's bet on a basketball market
    function getBet(uint256 marketId, address user) external view override returns (
        uint256 amount,
        uint256 selection,
        bool claimed
    ) {
        if (marketId >= marketCount) revert InvalidMarket(marketId);
        Bet storage b = basketballMarkets[marketId].bets[user];
        return (b.amount, b.selection, b.claimed);
    }

    /// @notice Parse string to BasketballMarketType enum
    function _parseBasketballMarketType(string calldata marketType) internal pure returns (BasketballMarketType) {
        bytes32 hash = keccak256(bytes(marketType));
        if (hash == keccak256("Winner")) return BasketballMarketType.Winner;
        if (hash == keccak256("TotalPoints")) return BasketballMarketType.TotalPoints;
        if (hash == keccak256("PointSpread")) return BasketballMarketType.PointSpread;
        if (hash == keccak256("QuarterWinner")) return BasketballMarketType.QuarterWinner;
        if (hash == keccak256("FirstToScore")) return BasketballMarketType.FirstToScore;
        if (hash == keccak256("HighestScoringQuarter")) return BasketballMarketType.HighestScoringQuarter;
        revert("Invalid market type");
    }

    /// @notice Convert BasketballMarketType enum to string
    function _basketballMarketTypeToString(BasketballMarketType mtype) internal pure returns (string memory) {
        if (mtype == BasketballMarketType.Winner) return "Winner";
        if (mtype == BasketballMarketType.TotalPoints) return "TotalPoints";
        if (mtype == BasketballMarketType.PointSpread) return "PointSpread";
        if (mtype == BasketballMarketType.QuarterWinner) return "QuarterWinner";
        if (mtype == BasketballMarketType.FirstToScore) return "FirstToScore";
        if (mtype == BasketballMarketType.HighestScoringQuarter) return "HighestScoringQuarter";
        return "Unknown";
    }

    /// @notice Internal function to cancel a basketball market
    function _cancelMarketInternal(uint256 marketId) internal override {
        BasketballMarket storage m = basketballMarkets[marketId];
        if (m.state == State.Ended && m.cancelled) revert("Market already resolved or cancelled");
        m.cancelled = true;
    }

    /// @notice Internal function to check if market is cancelled and get bet
    function _getMarketCancellationStatus(uint256 marketId, address user) internal view override returns (
        Bet storage userBet,
        bool isCancelled
    ) {
        BasketballMarket storage m = basketballMarkets[marketId];
        return (m.bets[user], m.cancelled);
    }
}
