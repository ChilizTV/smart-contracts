// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IMatchBettingBase
/// @notice Interface du moteur de pari-mutuel utilisé derrière un BeaconProxy par match.
/// @dev Couvre les vues, les fonctions d’admin, de pari, de règlement et de claim,
///      ainsi que les événements et erreurs afin de faciliter l’intégration (front, tests, autres contrats).
interface IMatchBettingBase {
    /*//////////////////////////////////////////////////////////////
                                ROLES (views)
    //////////////////////////////////////////////////////////////*/
    function ADMIN_ROLE() external view returns (bytes32);
    function SETTLER_ROLE() external view returns (bytes32);
    function PAUSER_ROLE() external view returns (bytes32);

    /*//////////////////////////////////////////////////////////////
                               STORAGE (views)
    //////////////////////////////////////////////////////////////*/
    function betToken() external view returns (IERC20);
    function treasury() external view returns (address);
    function matchId() external view returns (bytes32);
    function cutoffTs() external view returns (uint64);
    function feeBps() external view returns (uint16);
    function outcomesCount() external view returns (uint8);
    function settled() external view returns (bool);
    function winningOutcome() external view returns (uint8);

    /// @notice Montant total par issue (indexée)
    function pool(uint8 outcome) external view returns (uint256);

    /// @notice Montant misé par un utilisateur pour une issue donnée
    function bets(address user, uint8 outcome) external view returns (uint256);

    /// @notice Indique si l’utilisateur a déjà réclamé son gain
    function claimed(address user) external view returns (bool);

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/
    event Initialized(
        address indexed owner,
        address indexed token,
        bytes32 indexed matchId,
        uint8 outcomesCount,
        uint64 cutoffTs,
        uint16 feeBps,
        address treasury
    );

    event BetPlaced(address indexed user, uint8 indexed outcome, uint256 amount);
    event Settled(uint8 indexed winningOutcome, uint256 totalPool, uint256 feeAmount);
    event Claimed(address indexed user, uint256 payout);
    event CutoffUpdated(uint64 newCutoff);
    event TreasuryUpdated(address newTreasury);
    event FeeUpdated(uint16 newFeeBps);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error InvalidOutcome();
    error InvalidParam();
    error BettingClosed();
    error AlreadySettled();
    error NotSettled();
    error NothingToClaim();
    error ZeroAddress();
    error TooManyOutcomes();

    /*//////////////////////////////////////////////////////////////
                               ADMIN ACTIONS
    //////////////////////////////////////////////////////////////*/
    /// @notice Met à jour l’horodatage de fermeture des paris (si non settled)
    function setCutoff(uint64 newCutoff) external;

    /// @notice Met à jour l’adresse de trésorerie
    function setTreasury(address newTreasury) external;

    /// @notice Met à jour les frais en basis points (max 1000 = 10%)
    function setFeeBps(uint16 newFeeBps) external;

    /// @notice Pause / unpause du marché
    function pause() external;
    function unpause() external;

    /*//////////////////////////////////////////////////////////////
                                 BETTING
    //////////////////////////////////////////////////////////////*/
    /// @notice Parier sur une issue
    /// @param outcome index dans [0..outcomesCount-1]
    /// @param amount montant de jetons ERC-20 (nécessite approve préalable)
    function placeBet(uint8 outcome, uint256 amount) external;

    /*//////////////////////////////////////////////////////////////
                                SETTLEMENT
    //////////////////////////////////////////////////////////////*/
    /// @notice Règle le marché et fixe l’issue gagnante
    /// @param winning index de l’issue gagnante
    function settle(uint8 winning) external;

    /*//////////////////////////////////////////////////////////////
                                  CLAIM
    //////////////////////////////////////////////////////////////*/
    /// @notice Réclamer le gain proportionnel au pari-mutuel (après règlement)
    function claim() external;

    /// @notice Balaye les fonds vers la trésorerie si aucune mise gagnante (après règlement)
    function sweepIfNoWinners() external;

    /*//////////////////////////////////////////////////////////////
                                   VIEWS
    //////////////////////////////////////////////////////////////*/
    /// @notice Somme de toutes les mises (toutes issues confondues)
    function totalPoolAmount() external view returns (uint256);

    /// @notice Estimation du gain pour un utilisateur (0 si non applicable)
    function pendingPayout(address user) external view returns (uint256);
}
