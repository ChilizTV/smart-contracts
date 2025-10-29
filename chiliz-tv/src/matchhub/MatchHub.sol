// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title Match
/// @notice UUPS‑upgradeable contract representing one sports match with multiple bet markets
contract MatchHub is Initializable, OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuard {
    /// @notice Types of markets available in this match
    enum MarketType { Winner, GoalsCount, FirstScorer }
    /// @notice State of each market
    enum State      { Live, Ended }

    /// @notice A single user’s bet on a market
    struct Bet {
        uint256 amount;     // amount of wCHZ bid
        uint256 selection;  // encoded pick
        bool    claimed;    // whether already paid out
    }

    /// @notice A market inside this match
    struct Market {
        MarketType            mtype;    // kind of market
        uint256               odds;     // multiplier ×100
        State                 state;    // Live or Ended
        uint256               result;   // encoded result
        mapping(address=>Bet) bets;     // user → Bet
        address[]             bettors;  // list of addresses who bet
    }

    /// @notice Human‑readable name or description of the match
    string public matchName;
    /// @notice How many markets have been created
    uint256 public marketCount;
    /// @notice Mapping: marketId → Market
    mapping(uint256 => Market) public markets;

    /// @notice Emitted when the contract is initialized
    event MatchInitialized(string indexed name, address indexed owner);
    /// @notice Emitted when a new market is added
    event MarketAdded(uint256 indexed marketId, MarketType mtype, uint256 odds);
    /// @notice Emitted when a bet is placed
    event BetPlaced(uint256 indexed marketId, address indexed user, uint256 amount, uint256 selection);
    /// @notice Emitted when a market is resolved
    event MarketResolved(uint256 indexed marketId, uint256 result);
    /// @notice Emitted when a payout is made
    event Payout(uint256 indexed marketId, address indexed user, uint256 amount);

    /// @notice Error for invalid market references
    error InvalidMarket(uint256 marketId);
    /// @notice Error for wrong market state
    error WrongState(State required);
    /// @notice Error if zero ETH is sent
    error ZeroBet();
    /// @notice Error if no bet exists
    error NoBet();
    /// @notice Error if already claimed
    error AlreadyClaimed();
    /// @notice Error if selection lost
    error Lost();
    /// @notice Error if ETH transfer fails
    error TransferFailed();

    /// @notice UUPS initializer — replace constructor
    /// @param _matchName descriptive name of this match
    /// @param _owner      owner/admin of this contract
    function initialize(string calldata _matchName, address _owner) external initializer {
        __Ownable_init(_owner);
        __UUPSUpgradeable_init();
        //__ReentrancyGuard_init();
        matchName = _matchName;
        //_transferOwnership(_owner);
        emit MatchInitialized(_matchName, _owner);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @notice Add a new bet market to this match
    /// @param mtype type of market (Winner, GoalsCount, FirstScorer)
    /// @param odds  multiplier ×100 (e.g. 150 == 1.5×)
    function addMarket(MarketType mtype, uint256 odds) external onlyOwner {
        uint256 mid = marketCount++;
        Market storage m = markets[mid];
        m.mtype = mtype;
        m.odds  = odds;
        m.state = State.Live;
        emit MarketAdded(mid, mtype, odds);
    }

    /// @notice Place a bet in ETH on a given market
    /// @param marketId  identifier of the market
    /// @param selection encoded user pick
    function placeBet(uint256 marketId, uint256 selection) external payable {
        if (marketId >= marketCount) revert InvalidMarket(marketId);
        Market storage m = markets[marketId];
        if (m.state != State.Live) revert WrongState(State.Live);
        if (msg.value == 0) revert ZeroBet();
        m.bets[msg.sender] = Bet({ amount: msg.value, selection: selection, claimed: false });
        m.bettors.push(msg.sender);
        emit BetPlaced(marketId, msg.sender, msg.value, selection);
    }

    /// @notice Resolve a market by setting its result
    /// @param marketId identifier of the market
    /// @param result   encoded actual result
    function resolveMarket(uint256 marketId, uint256 result) external onlyOwner {
        if (marketId >= marketCount) revert InvalidMarket(marketId);
        Market storage m = markets[marketId];
        if (m.state != State.Live) revert WrongState(State.Live);
        m.result = result;
        m.state  = State.Ended;
        emit MarketResolved(marketId, result);
    }

    /// @notice Claim payout for a winning bet
    /// @param marketId identifier of the market
    function claim(uint256 marketId) external nonReentrant {
        if (marketId >= marketCount) revert InvalidMarket(marketId);
        Market storage m = markets[marketId];
        if (m.state != State.Ended) revert WrongState(State.Ended);
        Bet storage b = m.bets[msg.sender];
        if (b.amount == 0) revert NoBet();
        if (b.claimed) revert AlreadyClaimed();
        if (b.selection != m.result) revert Lost();
        b.claimed = true;
        uint256 payout = (b.amount * m.odds) / 100;
        (bool ok, ) = payable(msg.sender).call{ value: payout }("");
        if (!ok) revert TransferFailed();
        emit Payout(marketId, msg.sender, payout);
    }
}
