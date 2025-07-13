// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./IWCHZ.sol";

/// @title SportsBet
/// @notice Upgradeable sports-betting contract accepting WCHZ tokens
/// @dev Implements UUPS upgradeability and non-reentrant claim logic
contract SportsBet is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard
{
    /// @notice Possible outcomes of the event
    enum Outcome { Undecided, Home, Away, Draw }
    /// @notice Stages of the betting lifecycle
    enum State   { Not_started, Live, Ended, Blocked }

    /// @notice Represents a user's bet
    /// @param outcome The selected outcome
    /// @param amount  Amount of WCHZ staked (in wei)
    /// @param claimed Whether the payout has been claimed
    struct Bet {
        Outcome outcome;
        uint256 amount;
        bool    claimed;
    }

    // --- State Variables ---

    /// @notice Identifier for the sports event
    uint256 public eventId;
    /// @notice Human-readable name or description of the event
    string  public eventName;
    /// @notice Odds (multiplied by 100) for each possible outcome
    uint256 public oddsHome;
    uint256 public oddsAway;
    uint256 public oddsDraw;
    /// @notice Final result after resolution
    Outcome public result;
    /// @notice Current contract state
    State   public state;
    /// @notice ERC-20 token used for staking and payouts
    IWCHZ   public wchz;

    /// @notice Maps user addresses to their active bet
    mapping(address => Bet) public bets;

    // --- Events ---

    /// @notice Emitted when the event moves from Not_started to Live
    /// @param eventId Identifier of the event
    event EventStarted(uint256 indexed eventId);

    /// @notice Emitted when a user places a bet
    /// @param user    Address of the bettor
    /// @param outcome Outcome selected by the bettor
    /// @param amount  Amount of WCHZ staked
    event BetPlaced(address indexed user, Outcome outcome, uint256 amount);

    /// @notice Emitted when the event result is set and betting ends
    /// @param result Final outcome of the event
    event BetResolved(Outcome result);

    /// @notice Emitted when a user claims their payout
    /// @param user   Address of the bettor
    /// @param amount Amount of WCHZ paid out
    event Payout(address indexed user, uint256 amount);

    // --- Errors ---

    /// @notice Error for invalid state transitions or calls
    /// @param currentState The actual contract state
    error InvalidState(State currentState);

    /// @notice Error when a user stakes zero amount
    error ZeroValueUnauthorized();

    /// @notice Error when ERC-20 transfer fails
    error TransferIssue();

    /// @notice Error when claiming is attempted before resolution
    /// @param currentState The actual contract state
    error ClaimWhenBetNotEnded(State currentState);

    /// @notice Error when a user tries to claim twice
    error AlreadyClaimed();

    /// @notice Error when the user did not win
    error WrongOutcome();

    /// @notice UUPS initializer function (replaces constructor)
    /// @param _eventId     Identifier for the sports event
    /// @param _eventName   Name or description of the event
    /// @param _oddsHome    Odds×100 for home win
    /// @param _oddsAway    Odds×100 for away win
    /// @param _oddsDraw    Odds×100 for draw
    /// @param _owner       Address to receive ownership rights
    /// @param _wchz        Address of the WCHZ ERC-20 token
    function initialize(
        uint256 _eventId,
        string memory _eventName,
        uint256 _oddsHome,
        uint256 _oddsAway,
        uint256 _oddsDraw,
        address _owner,
        address _wchz
    ) external initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();

        eventId   = _eventId;
        eventName = _eventName;
        oddsHome  = _oddsHome;
        oddsAway  = _oddsAway;
        oddsDraw  = _oddsDraw;
        result    = Outcome.Undecided;
        state     = State.Not_started;
        wchz      = IWCHZ(_wchz);

        transferOwnership(_owner);
    }

    /// @notice Modifier to require the contract in Not_started state
    modifier onlyNotStarted() {
        if (state != State.Not_started) revert InvalidState(state);
        _;
    }

    /// @notice Modifier to require the contract in Live state
    modifier onlyLive() {
        if (state != State.Live) revert InvalidState(state);
        _;
    }

    /// @notice Start the event, enabling betting
    /// @dev Can only be called by owner when in Not_started state
    function startEvent() external onlyOwner onlyNotStarted {
        state = State.Live;
        emit EventStarted(eventId);
    }

    /// @notice Place a bet by staking WCHZ
    /// @param _outcome Outcome you want to bet on
    /// @param _amount  Amount of WCHZ to stake (in wei)
    function placeBet(Outcome _outcome, uint256 _amount)
        external
        onlyLive
    {
        if (_amount == 0) revert ZeroValueUnauthorized();
        bool ok = wchz.transferFrom(msg.sender, address(this), _amount);
        if (!ok) revert TransferIssue();

        bets[msg.sender] = Bet({ outcome: _outcome, amount: _amount, claimed: false });
        emit BetPlaced(msg.sender, _outcome, _amount);
    }

    /// @notice Resolve the event and set the final outcome
    /// @param _result Final outcome of the event
    function resolveBet(Outcome _result)
        external
        onlyOwner
        onlyLive
    {
        result = _result;
        state  = State.Ended;
        emit BetResolved(_result);
    }

    /// @notice Claim your winnings after the event ends
    /// @dev Protected against reentrancy
    function claim() external nonReentrant {
        if (state != State.Ended) revert ClaimWhenBetNotEnded(state);

        Bet storage userBet = bets[msg.sender];
        if (userBet.claimed) revert AlreadyClaimed();
        if (userBet.outcome != result) revert WrongOutcome();

        uint256 mult   = (result == Outcome.Home)
            ? oddsHome
            : (result == Outcome.Away)
                ? oddsAway
                : oddsDraw;
        uint256 payout = (userBet.amount * mult) / 100;

        userBet.claimed = true;
        bool sent = wchz.transfer(msg.sender, payout);
        if (!sent) revert TransferIssue();

        emit Payout(msg.sender, payout);
    }

    /// @notice Authorize UUPS upgrades
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
