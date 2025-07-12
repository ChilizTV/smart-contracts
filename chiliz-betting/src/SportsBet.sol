// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./IMockWrappedChz.sol";
/// @notice Interface du MockWrappedChz pour appeler les méthodes ERC-20 et utilitaires de mint/burn

/*
 * @title SportsBet
 * @notice Contrat de pari sportif, upgradeable via UUPS
 */
contract SportsBet is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    enum Outcome {
        Undecided,
        Home,
        Away,
        Draw
    }
    enum State {
        Not_started,
        Live,
        Ended,
        Blocked
    }

    struct Bet {
        Outcome outcome;
        State state;
        uint256 amount;
        bool claimed;
    }

    /// @notice ID de l’événement, nom, et cotes
    uint256 public eventId;
    string public eventName;
    uint256 public oddsHome;
    uint256 public oddsAway;
    uint256 public oddsDraw;

    /// @notice Résultat et état du pari
    Outcome public result;
    State public state;

    /// @notice Mapping des paris par utilisateur
    mapping(address => Bet) public bets;

    /// @notice Adresse du token Wrapped CHZ
    IMockWrappedChz public wChz;

    /// @notice Événements
    event BetPlaced(address indexed user, Outcome outcome, uint256 amount);
    event BetResolved(Outcome result);
    event Payout(address indexed user, uint256 amount);

    /// @notice Erreurs custom
    error BetAlreadyLive(State currentState);
    error ClaimWhenBetNotEnded(State currentState);

    /// @notice Initialisateur UUPS (remplace le constructeur)
    function initialize(
        uint256 _eventId,
        string memory _eventName,
        uint256 _oddsHome,
        uint256 _oddsAway,
        uint256 _oddsDraw,
        address _owner
    ) public initializer {
        __Ownable_init(_owner);
        __UUPSUpgradeable_init();
        eventId = _eventId;
        eventName = _eventName;
        oddsHome = _oddsHome;
        oddsAway = _oddsAway;
        oddsDraw = _oddsDraw;
        result = Outcome.Undecided;
        state = State.Not_started;
    }

    /// @notice Permet à l’owner de définir l’adresse du token WCHZ à utiliser
    function setToken(address tokenAddress) external onlyOwner {
        wChz = IMockWrappedChz(tokenAddress);
    }

    /// @notice Modificateur qui empêche de parier si le pari n’est pas démarré
    modifier isLive() {
        if (state != State.Not_started) revert BetAlreadyLive(state);
        _;
    }

    /// @notice Placer un pari en WCHZ (il faut que le user ait préalablement `approve`)
    function placeBet(Outcome _outcome, uint256 _amount) external isLive {
        require(_amount > 0, "Must bet > 0");

        // Transfert du token WCHZ depuis le joueur vers ce contrat
        bool ok = wChz.transferFrom(msg.sender, address(this), _amount);
        require(ok, "Transfer failed");

        bets[msg.sender] = Bet({outcome: _outcome, state: State.Live, amount: _amount, claimed: false});
        emit BetPlaced(msg.sender, _outcome, _amount);
    }

    /// @notice Résoudre le pari (appelable par owner only)
    function resolveBet(Outcome _result) external onlyOwner isLive {
        result = _result;
        state = State.Ended;
        emit BetResolved(_result);
    }

    /// @notice Réclamer ses gains en WCHZ si victoire
    function claim() external {
        if (state != State.Ended) revert ClaimWhenBetNotEnded(state);

        Bet storage userBet = bets[msg.sender];
        require(!userBet.claimed, "Already claimed");
        require(userBet.outcome == result, "No winnings");

        // Calcul du payout selon la cote
        uint256 mult = (result == Outcome.Home) ? oddsHome : (result == Outcome.Away) ? oddsAway : oddsDraw;
        uint256 payout = userBet.amount * mult / 100;

        userBet.claimed = true;
        // Transfert des tokens WCHZ au parieur
        bool ok = wChz.transfer(msg.sender, payout);
        require(ok, "Payout failed");

        emit Payout(msg.sender, payout);
    }

    /// @dev Sécurise les upgrades UUPS
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
