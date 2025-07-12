// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./IWCHZ.sol";

/// @title SportsBet
/// @notice Pari sportif en ERC-20 WCHZ, upgradable UUPS
contract SportsBet is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard
{
    enum Outcome { Undecided, Home, Away, Draw }
    enum State   { Not_started, Live, Ended, Blocked }

    struct Bet {
        Outcome outcome;
        uint256 amount;
        bool    claimed;
    }

    // --- Storage ---
    uint256 public eventId;
    string  public eventName;
    uint256 public oddsHome;
    uint256 public oddsAway;
    uint256 public oddsDraw;
    Outcome public result;
    State   public state;
    IWCHZ   public wchz;

    mapping(address => Bet) public bets;

    // --- Events ---
    event EventStarted(uint256 indexed eventId);
    event BetPlaced(address indexed user, Outcome outcome, uint256 amount);
    event BetResolved(Outcome result);
    event Payout(address indexed user, uint256 amount);

    // --- Errors ---
    error InvalidState(State currentState);
    error ZeroValueUnauthorized();
    error TransferIssue();
    error ClaimWhenBetNotEnded(State currentState);
    error AlreadyClaimed();
    error WrongOutcome();

    /// @notice Initializer UUPS
    /// @param _wchz L’adresse du token WCHZ (ERC-20)
    function initialize(
        uint256 _eventId,
        string memory _eventName,
        uint256 _oddsHome,
        uint256 _oddsAway,
        uint256 _oddsDraw,
        address _owner,
        address _wchz
    ) public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        // transferOwnership(_owner);

        eventId    = _eventId;
        eventName  = _eventName;
        oddsHome   = _oddsHome;
        oddsAway   = _oddsAway;
        oddsDraw   = _oddsDraw;
        result     = Outcome.Undecided;
        state      = State.Not_started;
        wchz       = IWCHZ(_wchz);
    }

    modifier onlyNotStarted() {
        if (state != State.Not_started) revert InvalidState(state);
        _;
    }

    modifier onlyLive() {
        if (state != State.Live) revert InvalidState(state);
        _;
    }

    /// @notice Démarrer l'événement (passe en Live)
    function startEvent() external onlyOwner onlyNotStarted {
        state = State.Live;
        emit EventStarted(eventId);
    }

    /// @notice Placer un pari (approve WCHZ puis transferFrom)
    function placeBet(Outcome _outcome, uint256 _amount) external onlyLive {
        if (_amount == 0) revert ZeroValueUnauthorized();

        bool ok = wchz.transferFrom(msg.sender, address(this), _amount);
        if (!ok) revert TransferIssue();

        bets[msg.sender] = Bet({
            outcome: _outcome,
            amount:  _amount,
            claimed: false
        });

        emit BetPlaced(msg.sender, _outcome, _amount);
    }

    /// @notice Résoudre le pari (seulement en Live)
    function resolveBet(Outcome _result) external onlyOwner onlyLive {
        result = _result;
        state  = State.Ended;
        emit BetResolved(_result);
    }

    /// @notice Réclamer ses gains (non reentrancy)
    function claim() external nonReentrant {
        if (state != State.Ended) revert ClaimWhenBetNotEnded(state);

        Bet storage userBet = bets[msg.sender];
        if (userBet.claimed) revert AlreadyClaimed();
        if (userBet.outcome != result) revert WrongOutcome();

        uint256 mult   = result == Outcome.Home
            ? oddsHome
            : result == Outcome.Away
                ? oddsAway
                : oddsDraw;
        uint256 payout = userBet.amount * mult / 100;

        userBet.claimed = true;

        bool sent = wchz.transfer(msg.sender, payout);
        if (!sent) revert TransferIssue();

        emit Payout(msg.sender, payout);
    }

    /// @dev UUPS authorisation
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
