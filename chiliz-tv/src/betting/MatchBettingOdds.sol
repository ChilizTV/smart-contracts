// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";
import {PriceOracle} from "../oracle/PriceOracle.sol";

/// @title MatchBettingOdds
/// @author ChilizTV
/// @notice Fixed-odds betting system with treasury liquidity backing
/// @dev Implements bookmaker-style betting where users lock in odds at bet time
///      Treasury provides liquidity and assumes risk/reward
contract MatchBettingOdds is
    Initializable,
    PausableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable
{
    // ----------------------------- ROLES --------------------------------
    
    bytes32 public constant ADMIN_ROLE   = keccak256("ADMIN_ROLE");
    bytes32 public constant SETTLER_ROLE = keccak256("SETTLER_ROLE");
    bytes32 public constant PAUSER_ROLE  = keccak256("PAUSER_ROLE");

    // ----------------------------- STRUCTS ------------------------------
    
    /// @notice Individual bet record with locked odds
    struct OddsBet {
        uint8 outcome;        // Outcome index [0..outcomesCount-1]
        uint96 amountChz;     // CHZ staked (96 bits = ~79B CHZ max)
        uint64 odds;          // Locked odds in 4 decimals (e.g., 25000 = 2.5x)
        bool claimed;         // Whether payout has been claimed
    }

    /// @notice Initialization parameters struct to avoid stack too deep
    struct InitParams {
        address owner;
        address priceFeed;
        bytes32 matchId;
        uint64 cutoffTs;
        uint16 feeBps;
        address treasury;
        uint256 minBetUsd;
        uint256 maxLiability;
        uint256 maxBetAmount;
        uint8 outcomes;
        uint64[] initialOdds;
    }

    // ---------------------------- STORAGE -------------------------------
    
    AggregatorV3Interface public priceFeed;
    address public treasury;
    bytes32 public matchId;
    uint64  public cutoffTs;
    uint16  public feeBps;        // Platform fee (not from odds, but additional)
    uint8   public outcomesCount;
    uint256 public minBetUsd;
    bool    public settled;
    uint8   public winningOutcome;

    /// @notice Current odds for each outcome (4 decimals: 25000 = 2.5x)
    mapping(uint8 => uint64) public odds;
    
    /// @notice Total amount staked on each outcome (for tracking)
    mapping(uint8 => uint256) public pool;
    
    /// @notice All bets placed by each user
    mapping(address => OddsBet[]) public userBets;
    
    /// @notice Maximum potential payout house will allow
    uint256 public maxLiability;
    
    /// @notice Current potential payouts if worst outcome occurs
    uint256 public currentLiability;
    
    /// @notice Maximum single bet size in CHZ
    uint256 public maxBetAmount;

    /// @notice Track total potential payouts per outcome
    mapping(uint8 => uint256) public potentialPayouts;

    // ----------------------------- EVENTS -------------------------------
    
    event Initialized(
        address indexed owner,
        address indexed priceFeed,
        bytes32 indexed matchId,
        uint8 outcomesCount,
        uint64 cutoffTs,
        uint16 feeBps,
        address treasury,
        uint256 minBetUsd,
        uint256 maxLiability
    );

    event BetPlaced(
        address indexed user,
        uint8 indexed outcome,
        uint256 amountChz,
        uint256 amountUsd,
        uint64 lockedOdds
    );

    event Settled(
        uint8 indexed winningOutcome,
        uint256 totalStaked,
        uint256 totalPayouts,
        int256 housePnL
    );

    event Claimed(
        address indexed user,
        uint256 payout,
        uint256 betCount
    );

    event OddsUpdated(uint8 indexed outcome, uint64 newOdds);
    event MaxLiabilityUpdated(uint256 newMaxLiability);
    event MaxBetAmountUpdated(uint256 newMaxBetAmount);
    event TreasuryFunded(uint256 amount);

    // ----------------------------- ERRORS -------------------------------
    
    error InvalidOutcome();
    error InvalidParam();
    error BettingClosed();
    error AlreadySettled();
    error NotSettled();
    error NothingToClaim();
    error BetBelowMinimum();
    error BetAboveMaximum();
    error ZeroBet();
    error TransferFailed();
    error ZeroAddress();
    error TooManyOutcomes();
    error InsufficientLiquidity();
    error InsufficientContractBalance();

    // --------------------------- INITIALIZER ----------------------------
    
    /// @notice Initializes fixed-odds betting for a specific match
    /// @param params InitParams struct containing all initialization parameters
    function initialize(InitParams calldata params) external initializer {
        // Validations
        if (params.owner == address(0)) revert ZeroAddress();
        if (params.priceFeed == address(0)) revert ZeroAddress();
        if (params.treasury == address(0)) revert ZeroAddress();
        if (params.outcomes < 2 || params.outcomes > 16) revert TooManyOutcomes();
        if (params.cutoffTs == 0) revert InvalidParam();
        if (params.feeBps > 1_000) revert InvalidParam();
        if (params.initialOdds.length != params.outcomes) revert InvalidParam();

        // Initialize base contracts
        __Pausable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();

        // Grant roles
        _grantRole(ADMIN_ROLE, params.owner);
        _grantRole(DEFAULT_ADMIN_ROLE, params.owner);
        _grantRole(PAUSER_ROLE, params.owner);
        _grantRole(SETTLER_ROLE, params.owner);

        // Set state variables
        priceFeed      = AggregatorV3Interface(params.priceFeed);
        treasury       = params.treasury;
        matchId        = params.matchId;
        outcomesCount  = params.outcomes;
        cutoffTs       = params.cutoffTs;
        feeBps         = params.feeBps;
        minBetUsd      = params.minBetUsd;
        maxLiability   = params.maxLiability;
        maxBetAmount   = params.maxBetAmount;

        // Set initial odds
        for (uint8 i = 0; i < params.outcomes; i++) {
            if (params.initialOdds[i] < 10000) revert InvalidParam();
            odds[i] = params.initialOdds[i];
        }

        emit Initialized(
            params.owner,
            params.priceFeed,
            params.matchId,
            params.outcomes,
            params.cutoffTs,
            params.feeBps,
            params.treasury,
            params.minBetUsd,
            params.maxLiability
        );
    }

    // ----------------------------- ADMIN --------------------------------
    
    function setOdds(uint8 outcome, uint64 newOdds) external onlyRole(ADMIN_ROLE) {
        if (settled) revert AlreadySettled();
        if (outcome >= outcomesCount) revert InvalidOutcome();
        if (newOdds < 10000) revert InvalidParam();
        
        odds[outcome] = newOdds;
        emit OddsUpdated(outcome, newOdds);
    }

    function setMaxLiability(uint256 newMaxLiability) external onlyRole(ADMIN_ROLE) {
        maxLiability = newMaxLiability;
        emit MaxLiabilityUpdated(newMaxLiability);
    }

    function setMaxBetAmount(uint256 newMaxBetAmount) external onlyRole(ADMIN_ROLE) {
        maxBetAmount = newMaxBetAmount;
        emit MaxBetAmountUpdated(newMaxBetAmount);
    }

    function setCutoff(uint64 newCutoff) external onlyRole(ADMIN_ROLE) {
        if (settled) revert AlreadySettled();
        cutoffTs = newCutoff;
    }

    function setTreasury(address newTreasury) external onlyRole(ADMIN_ROLE) {
        if (newTreasury == address(0)) revert ZeroAddress();
        treasury = newTreasury;
    }

    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    // ----------------------------- BETTING ------------------------------
    
    /// @notice Places a bet with locked odds
    /// @param outcome Outcome to bet on
    function placeBet(uint8 outcome) external payable whenNotPaused nonReentrant {
        if (block.timestamp >= cutoffTs) revert BettingClosed();
        if (outcome >= outcomesCount) revert InvalidOutcome();
        if (msg.value == 0) revert ZeroBet();
        if (msg.value > maxBetAmount) revert BetAboveMaximum();

        // Validate minimum bet in USD
        uint256 usdValue = PriceOracle.chzToUsd(msg.value, priceFeed);
        if (usdValue < minBetUsd) revert BetBelowMinimum();

        // Get current odds for this outcome
        uint64 currentOdds = odds[outcome];
        
        // Calculate potential payout and profit
        uint256 potentialPayout = (uint256(msg.value) * currentOdds) / 10_000;
        uint256 potentialProfit = potentialPayout > msg.value ? potentialPayout - msg.value : 0;

        // Check liquidity: ensure house can cover this bet
        if (currentLiability + potentialProfit > maxLiability) revert InsufficientLiquidity();

        // Update liability (worst-case scenario tracking)
        currentLiability += potentialProfit;

        // Record bet with locked odds
        userBets[msg.sender].push(OddsBet({
            outcome: outcome,
            amountChz: uint96(msg.value),
            odds: currentOdds,
            claimed: false
        }));

        // Update pool for tracking
        pool[outcome] += msg.value;
        
        // Track potential payout for this outcome
        potentialPayouts[outcome] += potentialPayout;

        emit BetPlaced(msg.sender, outcome, msg.value, usdValue, currentOdds);
    }

    // ----------------------------- SETTLEMENT ---------------------------
    
    /// @notice Settles match and calculates house P&L
    /// @param winning Winning outcome index
    function settle(uint8 winning) external whenNotPaused onlyRole(SETTLER_ROLE) nonReentrant {
        if (settled) revert AlreadySettled();
        if (winning >= outcomesCount) revert InvalidOutcome();

        settled = true;
        winningOutcome = winning;

        // Calculate total staked and total payouts
        uint256 totalStaked = 0;
        uint256 totalPayouts = 0;

        for (uint8 i = 0; i < outcomesCount; i++) {
            totalStaked += pool[i];
        }

        // Calculate actual payouts needed (only for winning outcome)
        totalPayouts = calculateTotalPayouts(winning);

        // House P&L: positive if house profits, negative if house loses
        int256 housePnL = int256(totalStaked) - int256(totalPayouts);

        emit Settled(winning, totalStaked, totalPayouts, housePnL);

        // Treasury settlement flow
        if (housePnL > 0) {
            // House profits: Send excess to treasury, keep payouts in contract
            uint256 profit = uint256(housePnL);
            
            // Keep totalPayouts in contract for claims
            // Send profit to treasury
            if (profit > 0) {
                (bool success, ) = treasury.call{value: profit}("");
                if (!success) revert TransferFailed();
            }
        } else if (housePnL < 0) {
            // House loss: Treasury must fund the difference
            uint256 loss = uint256(-housePnL);
            
            // Check if contract has enough balance
            if (address(this).balance < totalPayouts) {
                // Need treasury to fund the contract
                // Treasury should send funds via fundContract()
                revert InsufficientContractBalance();
            }
        }
        // If housePnL == 0, perfect balance, no transfer needed
    }

    /// @notice Allows treasury to fund contract for payouts (when house loses)
    function fundContract() external payable {
        require(msg.sender == treasury, "Only treasury can fund");
        emit TreasuryFunded(msg.value);
    }

    /// @notice Calculates total payouts for a given winning outcome
    function calculateTotalPayouts(uint8 outcome) public view returns (uint256) {
        return potentialPayouts[outcome];
    }

    // ----------------------------- CLAIMS -------------------------------
    
    /// @notice Claims all winning bets for caller
    function claim() external whenNotPaused nonReentrant {
        if (!settled) revert NotSettled();

        uint256 totalPayout = 0;
        uint256 betCount = 0;

        OddsBet[] storage bets = userBets[msg.sender];
        
        for (uint256 i = 0; i < bets.length; i++) {
            if (bets[i].outcome == winningOutcome && !bets[i].claimed) {
                // Calculate payout with locked odds
                uint256 payout = (uint256(bets[i].amountChz) * bets[i].odds) / 10_000;
                totalPayout += payout;
                bets[i].claimed = true;
                betCount++;
            }
        }

        if (totalPayout == 0) revert NothingToClaim();

        emit Claimed(msg.sender, totalPayout, betCount);

        (bool success, ) = msg.sender.call{value: totalPayout}("");
        if (!success) revert TransferFailed();
    }

    // ----------------------------- VIEWS --------------------------------
    
    /// @notice Gets total number of bets for a user
    function getUserBetCount(address user) external view returns (uint256) {
        return userBets[user].length;
    }

    /// @notice Gets specific bet details for a user
    function getUserBet(address user, uint256 index) external view returns (OddsBet memory) {
        return userBets[user][index];
    }

    /// @notice Calculates pending payout for a user
    function pendingPayout(address user) external view returns (uint256) {
        if (!settled) return 0;

        uint256 total = 0;
        OddsBet[] storage bets = userBets[user];

        for (uint256 i = 0; i < bets.length; i++) {
            if (bets[i].outcome == winningOutcome && !bets[i].claimed) {
                total += (uint256(bets[i].amountChz) * bets[i].odds) / 10_000;
            }
        }

        return total;
    }

    /// @notice Gets current odds for all outcomes
    function getAllOdds() external view returns (uint64[] memory) {
        uint64[] memory allOdds = new uint64[](outcomesCount);
        for (uint8 i = 0; i < outcomesCount; i++) {
            allOdds[i] = odds[i];
        }
        return allOdds;
    }

    /// @notice Total amount staked across all outcomes
    function totalPoolAmount() external view returns (uint256) {
        uint256 total = 0;
        for (uint8 i = 0; i < outcomesCount; i++) {
            total += pool[i];
        }
        return total;
    }

    // ------------------------- RECEIVE CHZ ------------------------------
    
    receive() external payable {}
    fallback() external payable {}
}
