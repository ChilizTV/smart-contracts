// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

/// @title MatchBettingBase
/// @author ChilizTV
/// @notice Abstract base contract implementing pari-mutuel betting logic for sports matches
/// @dev Designed to be used behind a BeaconProxy for upgradeable per-match betting instances.
///      Storage layout must remain append-only for future logic versions to maintain compatibility.
///      Implements parimutuel betting where losers fund winners proportionally after platform fees.
abstract contract MatchBettingBase is
    Initializable,
    PausableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable
{
    // ----------------------------- ROLES --------------------------------
    
    /// @notice Role for administrative functions (setCutoff, setTreasury, setFeeBps)
    bytes32 public constant ADMIN_ROLE   = keccak256("ADMIN_ROLE");
    
    /// @notice Role authorized to settle match outcomes
    bytes32 public constant SETTLER_ROLE = keccak256("SETTLER_ROLE");
    
    /// @notice Role authorized to pause/unpause betting
    bytes32 public constant PAUSER_ROLE  = keccak256("PAUSER_ROLE");

    // ---------------------------- STORAGE -------------------------------
    
    /// @notice ERC20 token used for placing bets and payouts
    IERC20  public betToken;
    
    /// @notice Address receiving platform fees
    address public treasury;
    
    /// @notice Unique identifier for this match (can be hash of off-chain data)
    bytes32 public matchId;
    
    /// @notice Unix timestamp after which no more bets can be placed
    uint64  public cutoffTs;
    
    /// @notice Platform fee in basis points (e.g., 200 = 2%, max 1000 = 10%)
    uint16  public feeBps;
    
    /// @notice Total number of possible outcomes for this match (2-16)
    uint8   public outcomesCount;

    /// @notice Whether the match has been settled (immutable once true)
    bool    public settled;
    
    /// @notice Index of the winning outcome (only valid after settlement)
    uint8   public winningOutcome;

    /// @notice Total amount staked on each outcome
    /// @dev outcomeId => total stake amount
    mapping(uint8 => uint256) public pool;
    
    /// @notice Individual user stakes per outcome
    /// @dev user => outcomeId => stake amount
    mapping(address => mapping(uint8 => uint256)) public bets;
    
    /// @notice Tracks whether a user has claimed their winnings
    /// @dev user => has claimed
    mapping(address => bool) public claimed;

    // ----------------------------- EVENTS -------------------------------
    
    /// @notice Emitted when a match betting instance is initialized
    /// @param owner Address granted admin roles
    /// @param token ERC20 token address for bets
    /// @param matchId Unique match identifier
    /// @param outcomesCount Number of possible outcomes
    /// @param cutoffTs Betting cutoff timestamp
    /// @param feeBps Platform fee in basis points
    /// @param treasury Address receiving fees
    event Initialized(
        address indexed owner,
        address indexed token,
        bytes32 indexed matchId,
        uint8 outcomesCount,
        uint64 cutoffTs,
        uint16 feeBps,
        address treasury
    );

    /// @notice Emitted when a user places a bet
    /// @param user Address of the bettor
    /// @param outcome Outcome index being bet on
    /// @param amount Amount of tokens staked
    event BetPlaced(
        address indexed user,
        uint8 indexed outcome,
        uint256 amount
    );

    /// @notice Emitted when match outcome is settled
    /// @param winningOutcome Index of the winning outcome
    /// @param totalPool Total amount in all pools
    /// @param feeAmount Amount sent to treasury as fees
    event Settled(
        uint8 indexed winningOutcome,
        uint256 totalPool,
        uint256 feeAmount
    );

    /// @notice Emitted when a user claims their winnings
    /// @param user Address claiming rewards
    /// @param payout Amount of tokens paid out
    event Claimed(
        address indexed user,
        uint256 payout
    );

    /// @notice Emitted when betting cutoff time is updated
    /// @param newCutoff New cutoff timestamp
    event CutoffUpdated(uint64 newCutoff);
    
    /// @notice Emitted when treasury address is updated
    /// @param newTreasury New treasury address
    event TreasuryUpdated(address newTreasury);
    
    /// @notice Emitted when fee percentage is updated
    /// @param newFeeBps New fee in basis points
    event FeeUpdated(uint16 newFeeBps);

    // ----------------------------- ERRORS -------------------------------
    
    /// @notice Thrown when an invalid outcome index is provided
    error InvalidOutcome();
    
    /// @notice Thrown when an invalid parameter is provided during initialization
    error InvalidParam();
    
    /// @notice Thrown when attempting to bet after cutoff time
    error BettingClosed();
    
    /// @notice Thrown when attempting to settle an already settled match
    error AlreadySettled();
    
    /// @notice Thrown when attempting an action that requires settlement first
    error NotSettled();
    
    /// @notice Thrown when a user has no winnings to claim
    error NothingToClaim();
    
    /// @notice Thrown when a zero address is provided where not allowed
    error ZeroAddress();
    
    /// @notice Thrown when outcomes count exceeds maximum allowed (16)
    error TooManyOutcomes();

    // --------------------------- INITIALIZER ----------------------------
    
    /// @notice Initializes the betting contract for a specific match
    /// @dev Called internally by sport-specific implementations via BeaconProxy
    ///      Grants all roles to owner and sets up parimutuel betting parameters
    /// @param owner_ Address to receive admin roles (recommended: Gnosis Safe multisig)
    /// @param token_ ERC20 token address for placing bets and payouts
    /// @param matchId_ Unique identifier for this match (hash of off-chain data)
    /// @param outcomes_ Number of possible outcomes (min 2, max 16, typical 2-3)
    /// @param cutoffTs_ Unix timestamp after which betting closes
    /// @param feeBps_ Platform fee in basis points (max 1000 = 10%)
    /// @param treasury_ Address to receive platform fees
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
    
    /// @notice Ensures function can only be called before betting cutoff
    /// @dev Reverts with BettingClosed if current time >= cutoffTs
    modifier onlyBeforeCutoff() {
        if (block.timestamp >= cutoffTs) revert BettingClosed();
        _;
    }

    // ----------------------------- ADMIN --------------------------------
    
    /// @notice Updates the betting cutoff timestamp
    /// @dev Can only be called before settlement to prevent manipulation
    /// @param newCutoff New cutoff timestamp (unix seconds)
    function setCutoff(uint64 newCutoff) external onlyRole(ADMIN_ROLE) {
        if (settled) revert AlreadySettled();
        cutoffTs = newCutoff;
        emit CutoffUpdated(newCutoff);
    }

    /// @notice Updates the treasury address receiving fees
    /// @dev Zero address not allowed
    /// @param newTreasury New treasury address
    function setTreasury(address newTreasury) external onlyRole(ADMIN_ROLE) {
        if (newTreasury == address(0)) revert ZeroAddress();
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    /// @notice Updates the platform fee percentage
    /// @dev Maximum fee is 10% (1000 basis points)
    /// @param newFeeBps New fee in basis points
    function setFeeBps(uint16 newFeeBps) external onlyRole(ADMIN_ROLE) {
        if (newFeeBps > 1_000) revert InvalidParam();
        feeBps = newFeeBps;
        emit FeeUpdated(newFeeBps);
    }

    /// @notice Pauses all betting operations
    /// @dev Can only be called by PAUSER_ROLE
    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }
    
    /// @notice Resumes betting operations
    /// @dev Can only be called by PAUSER_ROLE
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    // ----------------------------- BETTING ------------------------------
    
    /// @notice Places a bet on a specific outcome
    /// @dev Internal function called by sport-specific wrappers (betHome, betRed, etc.)
    ///      Transfers tokens from user (requires prior approval)
    ///      Parimutuel system: user share = (user bet / total winning pool) * total pool after fees
    /// @param outcome Outcome index to bet on [0..outcomesCount-1]
    /// @param amount Amount of betToken to stake (must be > 0)
    function placeBet(uint8 outcome, uint256 amount)
        internal
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
    
    /// @notice Settles the match with the winning outcome
    /// @dev Can only be called once by SETTLER_ROLE after match conclusion
    ///      Sets match as settled and records winning outcome
    ///      Fees are calculated and emitted but transferred during claims
    /// @param winning Index of the winning outcome [0..outcomesCount-1]
    function settle(uint8 winning) external whenNotPaused onlyRole(SETTLER_ROLE) {
        if (settled) revert AlreadySettled();
        if (winning >= outcomesCount) revert InvalidOutcome();

        settled = true;
        winningOutcome = winning;

        uint256 totalPool = totalPoolAmount();
        uint256 feeAmount = (totalPool * feeBps) / 10_000;

        emit Settled(winning, totalPool, feeAmount);
    }

    /// @notice Claims winnings for the caller based on their winning bets
    /// @dev Implements parimutuel payout calculation:
    ///      Payout = (userBet / winningPool) * (totalPool - fees)
    ///      Can only claim once after settlement
    ///      Fees are sent to treasury on first claim only (via feeBpsOnFirstClaim optimization)
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

        // Transfer fee to treasury on first claim (optimization to avoid separate transaction)
        // feeBps is set to 0 after first fee transfer to prevent duplicate fee collection
        if (fee > 0) {
            require(betToken.transfer(treasury, fee), "FEE_TRANSFER_FAILED");
            feeBps = 0;
        }

        require(betToken.transfer(msg.sender, payout), "PAYOUT_TRANSFER_FAILED");
    }

    /// @notice Sweeps all funds to treasury when there are no winners
    /// @dev Can only be called by ADMIN_ROLE after settlement
    ///      Reverts if winning pool has any bets (winners exist)
    ///      Use case: All users bet on wrong outcomes, no one to pay out
    function sweepIfNoWinners() external onlyRole(ADMIN_ROLE) {
        require(settled, "NOT_SETTLED");
        if (pool[winningOutcome] != 0) revert InvalidParam();
        uint256 bal = betToken.balanceOf(address(this));
        require(betToken.transfer(treasury, bal), "SWEEP_FAILED");
    }

    // ----------------------------- VIEWS --------------------------------
    
    /// @notice Calculates total amount in all betting pools
    /// @return sum Total tokens staked across all outcomes
    function totalPoolAmount() public view returns (uint256 sum) {
        unchecked {
            for (uint8 i = 0; i < outcomesCount; i++) {
                sum += pool[i];
            }
        }
    }

    /// @notice Calculates pending payout for a user if they won
    /// @dev Returns 0 if match not settled or user has no winning bets
    ///      Formula: (userBet / winningPool) * (totalPool - fees)
    /// @param user Address to check payout for
    /// @return Pending payout amount in betToken
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
    
    /// @notice Internal helper for sport-specific implementations to initialize base
    /// @dev Must be called by concrete implementations (FootballBetting, UFCBetting, etc.)
    ///      during their initialize() function
    /// @param owner_ Address to receive admin roles
    /// @param token_ ERC20 token for betting
    /// @param matchId_ Match identifier
    /// @param cutoffTs_ Betting cutoff timestamp
    /// @param feeBps_ Platform fee in basis points
    /// @param treasury_ Fee recipient address
    /// @param outcomes_ Number of possible outcomes
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
