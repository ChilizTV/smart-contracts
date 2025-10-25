// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

/// @title MatchBettingBase
/// @notice Abstract pari-mutuel betting logic (used behind BeaconProxy per match)
/// @dev Storage layout must remain append-only for future logic versions.
abstract contract MatchBettingBase is
    Initializable,
    PausableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable
{
    // ----------------------------- ROLES --------------------------------
    bytes32 public constant ADMIN_ROLE   = keccak256("ADMIN_ROLE");
    bytes32 public constant SETTLER_ROLE = keccak256("SETTLER_ROLE");
    bytes32 public constant PAUSER_ROLE  = keccak256("PAUSER_ROLE");

    // ---------------------------- STORAGE -------------------------------
    IERC20  public betToken;        // Token used for stakes
    address public treasury;        // Fees destination
    bytes32 public matchId;         // Off-chain match identifier (hashed if needed)
    uint64  public cutoffTs;        // Betting cutoff (UNIX - seconds)
    uint16  public feeBps;          // Fee in basis points (e.g., 300 = 3%)
    uint8   public outcomesCount;   // Number of outcomes for this sport/match

    bool    public settled;         // Once settled => immutable
    uint8   public winningOutcome;  // Winning outcome index (0..outcomesCount-1)

    // outcomeId => total stake
    mapping(uint8 => uint256) public pool;
    // user => outcomeId => stake
    mapping(address => mapping(uint8 => uint256)) public bets;
    // user => claimed?
    mapping(address => bool) public claimed;

    // ----------------------------- EVENTS -------------------------------
    event Initialized(
        address indexed owner,
        address indexed token,
        bytes32 indexed matchId,
        uint8 outcomesCount,
        uint64 cutoffTs,
        uint16 feeBps,
        address treasury
    );

    event BetPlaced(
        address indexed user,
        uint8 indexed outcome,
        uint256 amount
    );

    event Settled(
        uint8 indexed winningOutcome,
        uint256 totalPool,
        uint256 feeAmount
    );

    event Claimed(
        address indexed user,
        uint256 payout
    );

    event CutoffUpdated(uint64 newCutoff);
    event TreasuryUpdated(address newTreasury);
    event FeeUpdated(uint16 newFeeBps);

    // ----------------------------- ERRORS -------------------------------
    error InvalidOutcome();
    error InvalidParam();
    error BettingClosed();
    error AlreadySettled();
    error NotSettled();
    error NothingToClaim();
    error ZeroAddress();
    error TooManyOutcomes();

    // --------------------------- INITIALIZER ----------------------------
    /// @notice Initialize the match (called via BeaconProxy constructor)
    /// @param owner_      Admin/owner (Gnosis Safe recommandé)
    /// @param token_      ERC-20 token used for stakes
    /// @param matchId_    External identifier of the match
    /// @param outcomes_   Number of outcomes (2..8 recommended)
    /// @param cutoffTs_   Timestamp after which betting is closed
    /// @param feeBps_     Fee in basis points (max 10% recommandé)
    /// @param treasury_   Fee receiver
    function initializeBase(
        address owner_,
        address token_,
        bytes32 matchId_,
        uint8 outcomes_,
        uint64 cutoffTs_,
        uint16 feeBps_,
        address treasury_
    ) internal onlyInitializing {
        if (owner_ == address(0) || token_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        if (outcomes_ < 2 || outcomes_ > 16) revert TooManyOutcomes();
        if (cutoffTs_ == 0) revert InvalidParam();
        if (feeBps_ > 1_000) revert InvalidParam(); // max 10%: 1000 bps

        __Pausable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();

        _grantRole(ADMIN_ROLE, owner_);
        _grantRole(DEFAULT_ADMIN_ROLE, owner_);
        _grantRole(PAUSER_ROLE, owner_);
        _grantRole(SETTLER_ROLE, owner_);

        betToken      = IERC20(token_);
        treasury      = treasury_;
        matchId       = matchId_;
        outcomesCount = outcomes_;
        cutoffTs      = cutoffTs_;
        feeBps        = feeBps_;

        emit Initialized(owner_, token_, matchId_, outcomes_, cutoffTs_, feeBps_, treasury_);
    }

    // ---------------------------- MODIFIERS -----------------------------
    modifier onlyBeforeCutoff() {
        if (block.timestamp >= cutoffTs) revert BettingClosed();
        _;
    }

    // ----------------------------- ADMIN --------------------------------
    function setCutoff(uint64 newCutoff) external onlyRole(ADMIN_ROLE) {
        // Autoriser uniquement si pas encore settled pour éviter grief
        if (settled) revert AlreadySettled();
        cutoffTs = newCutoff;
        emit CutoffUpdated(newCutoff);
    }

    function setTreasury(address newTreasury) external onlyRole(ADMIN_ROLE) {
        if (newTreasury == address(0)) revert ZeroAddress();
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    function setFeeBps(uint16 newFeeBps) external onlyRole(ADMIN_ROLE) {
        if (newFeeBps > 1_000) revert InvalidParam();
        feeBps = newFeeBps;
        emit FeeUpdated(newFeeBps);
    }

    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    // ----------------------------- BETTING ------------------------------
    /// @notice Place a bet on an outcome
    /// @param outcome outcome index [0..outcomesCount-1]
    /// @param amount  stake in betToken (approve required)
    function placeBet(uint8 outcome, uint256 amount)
        external
        whenNotPaused
        onlyBeforeCutoff
        nonReentrant
    {
        if (outcome >= outcomesCount) revert InvalidOutcome();
        if (amount == 0) revert InvalidParam();

        // effects
        pool[outcome] += amount;
        bets[msg.sender][outcome] += amount;

        emit BetPlaced(msg.sender, outcome, amount);

        // interactions
        // pull ERC-20 from user
        require(betToken.transferFrom(msg.sender, address(this), amount), "TRANSFER_FROM_FAILED");
    }

    // ----------------------------- SETTLEMENT ---------------------------
    /// @notice Settle the market and set the winning outcome
    /// @dev For MVP: restricted to SETTLER_ROLE (bridge/oracle).
    ///      You can extend to EIP-712 attestation instead.
    function settle(uint8 winning) external whenNotPaused onlyRole(SETTLER_ROLE) {
        if (settled) revert AlreadySettled();
        if (winning >= outcomesCount) revert InvalidOutcome();

        settled = true;
        winningOutcome = winning;

        // Compute fee on total pool at claim-time to avoid rounding issues here
        uint256 totalPool = totalPoolAmount();
        uint256 feeAmount = (totalPool * feeBps) / 10_000;

        emit Settled(winning, totalPool, feeAmount);
    }

    /// @notice Claim payout according to pari-mutuel share
    function claim() external whenNotPaused nonReentrant {
        if (!settled) revert NotSettled();
        if (claimed[msg.sender]) revert NothingToClaim();

        uint256 userStake = bets[msg.sender][winningOutcome];
        uint256 winPool   = pool[winningOutcome];
        if (winPool == 0 || userStake == 0) revert NothingToClaim();

        claimed[msg.sender] = true;

        uint256 total = totalPoolAmount();
        uint256 fee   = (total * feeBps) / 10_000;
        uint256 distributable = total - fee;

        // pari-mutuel share
        uint256 payout = (distributable * userStake) / winPool;

        emit Claimed(msg.sender, payout);

        // pay fee first time any user claims? (MVP: collect on first claim)
        // For simplicity, send fee to treasury on first claim of the market
        // If you prefer: collect fee on settle or separate function guarded by once flag.
        if (fee > 0) {
            // try/catch pattern would be cleaner; MVP requires success
            require(betToken.transfer(treasury, fee), "FEE_TRANSFER_FAILED");
            // set feeBps = 0 to avoid re-sending on subsequent claims? Optional.
            feeBps = 0;
        }

        require(betToken.transfer(msg.sender, payout), "PAYOUT_TRANSFER_FAILED");
    }

    // In case of no winners, ADMIN can sweep losers to treasury after settlement
    function sweepIfNoWinners() external onlyRole(ADMIN_ROLE) {
        require(settled, "NOT_SETTLED");
        if (pool[winningOutcome] != 0) revert InvalidParam(); // winners exist
        uint256 bal = betToken.balanceOf(address(this));
        require(betToken.transfer(treasury, bal), "SWEEP_FAILED");
    }

    // ----------------------------- VIEWS --------------------------------
    function totalPoolAmount() public view returns (uint256 sum) {
        unchecked {
            for (uint8 i = 0; i < outcomesCount; i++) {
                sum += pool[i];
            }
        }
    }

    function pendingPayout(address user) external view returns (uint256) {
        if (!settled) return 0;
        uint256 userStake = bets[user][winningOutcome];
        uint256 winPool   = pool[winningOutcome];
        if (winPool == 0 || userStake == 0) return 0;

        uint256 total = totalPoolAmount();
        uint256 fee   = (total * feeBps) / 10_000;
        uint256 distributable = total - fee;

        return (distributable * userStake) / winPool;
    }

    // ----------------------- SPORT-SPECIFIC HOOK ------------------------
    /// @notice Implementations must call this from their own initialize(...)
    function _initSport(
        address owner_,
        address token_,
        bytes32 matchId_,
        uint64 cutoffTs_,
        uint16 feeBps_,
        address treasury_,
        uint8 outcomes_
    ) internal {
        initializeBase(owner_, token_, matchId_, outcomes_, cutoffTs_, feeBps_, treasury_);
    }
}
