// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/// @title BettingMatch
/// @notice Abstract base contract for UUPS-upgradeable sports betting matches
abstract contract BettingMatch is Initializable, OwnableUpgradeable, AccessControlUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    // Role definitions
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant RESOLVER_ROLE = keccak256("RESOLVER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    
    /// @notice Market lifecycle states
    enum MarketState { Scheduled, Live, Resolved, Cancelled }
    
    /// @notice State of each market
    enum State { Live, Ended }

    /// @notice A single user's bet on a market
    struct Bet {
        uint256 amount;     // amount of CHZ bid
        uint256 selection;  // encoded pick
        bool    claimed;    // whether already paid out
    }

    /// @notice Human-readable name or description of the match
    string public matchName;
    /// @notice Sport type identifier
    string public sportType;
    /// @notice How many markets have been created
    uint256 public marketCount;

    /// @notice Emitted when the contract is initialized
    event MatchInitialized(string indexed name, string sportType, address indexed owner);
    /// @notice Emitted when a new market is added
    event MarketAdded(uint256 indexed marketId, string marketType, uint256 odds);
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
    /// @notice Error if zero CHZ is sent
    error ZeroBet();
    /// @notice Error if no bet exists
    error NoBet();
    /// @notice Error if already claimed
    error AlreadyClaimed();
    /// @notice Error if selection lost
    error Lost();
    /// @notice Error if CHZ transfer fails
    error TransferFailed();
    /// @notice Error if odds are invalid
    error InvalidOdds();
    /// @notice Error if insufficient balance for payout
    error InsufficientBalance();
    /// @notice Error if double betting detected
    error AlreadyBet();

    /// @notice UUPS initializer — replace constructor
    /// @param _matchName descriptive name of this match
    /// @param _sportType sport identifier (e.g., "FOOTBALL", "BASKETBALL")
    /// @param _owner     owner/admin of this contract
    function __BettingMatch_init(string memory _matchName, string memory _sportType, address _owner) internal onlyInitializing {
        __Ownable_init(_owner);
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        
        // Setup role hierarchy: owner has all roles
        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
        _grantRole(ADMIN_ROLE, _owner);
        _grantRole(RESOLVER_ROLE, _owner);
        _grantRole(PAUSER_ROLE, _owner);
        _grantRole(TREASURY_ROLE, _owner);
        
        matchName = _matchName;
        sportType = _sportType;
        emit MatchInitialized(_matchName, _sportType, _owner);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /// @notice Allow contract to receive CHZ
    receive() external payable {}

    /// @notice Get sport-specific market information (implemented by each sport)
    /// @param marketId identifier of the market
    /// @return marketType human-readable market type
    /// @return odds multiplier ×100
    /// @return state current state (Live/Ended)
    /// @return result encoded result (if ended)
    function getMarket(uint256 marketId) external view virtual returns (
        string memory marketType,
        uint256 odds,
        State state,
        uint256 result
    );

    /// @notice Get user's bet for a specific market (implemented by each sport)
    /// @param marketId identifier of the market
    /// @param user address of the bettor
    function getBet(uint256 marketId, address user) external view virtual returns (
        uint256 amount,
        uint256 selection,
        bool claimed
    );

    /// @notice Add a new bet market to this match (sport-specific implementation)
    function addMarket(string calldata marketType, uint256 odds) external virtual;

    /// @notice Place a bet in CHZ on a given market (shared logic)
    /// @param marketId identifier of the market
    /// @param selection encoded user pick
    function placeBet(uint256 marketId, uint256 selection) external payable whenNotPaused {
        if (marketId >= marketCount) revert InvalidMarket(marketId);
        if (msg.value == 0) revert ZeroBet();
        
        // Delegate to sport-specific validation and storage
        _storeBet(marketId, msg.sender, msg.value, selection);
        
        emit BetPlaced(marketId, msg.sender, msg.value, selection);
    }

    /// @notice Resolve a market by setting its result (shared logic)
    /// @param marketId identifier of the market
    /// @param result encoded actual result
    function resolveMarket(uint256 marketId, uint256 result) external onlyRole(RESOLVER_ROLE) {
        if (marketId >= marketCount) revert InvalidMarket(marketId);
        
        // Delegate to sport-specific resolution
        _resolveMarketInternal(marketId, result);
        
        emit MarketResolved(marketId, result);
    }

    /// @notice Claim payout for a winning bet (shared logic)
    /// @param marketId identifier of the market
    function claim(uint256 marketId) external nonReentrant whenNotPaused {
        if (marketId >= marketCount) revert InvalidMarket(marketId);
        
        // Get sport-specific market and bet data
        (uint256 odds, State state, uint256 result, Bet storage userBet) = _getMarketAndBet(marketId, msg.sender);
        
        if (state != State.Ended) revert WrongState(State.Ended);
        if (userBet.amount == 0) revert NoBet();
        if (userBet.claimed) revert AlreadyClaimed();
        if (userBet.selection != result) revert Lost();
        
        userBet.claimed = true;
        uint256 payout = (userBet.amount * odds) / 100;
        
        // CRITICAL FIX: Revert if insufficient balance instead of silent reduction
        if (address(this).balance < payout) revert InsufficientBalance();
        
        (bool ok, ) = payable(msg.sender).call{ value: payout }("");
        if (!ok) revert TransferFailed();
        emit Payout(marketId, msg.sender, payout);
    }

    /// @notice Cancel a market and refund all bettors
    /// @param marketId identifier of the market to cancel
    function cancelMarket(uint256 marketId) external onlyRole(ADMIN_ROLE) {
        if (marketId >= marketCount) revert InvalidMarket(marketId);
        
        _cancelMarketInternal(marketId);
    }

    /// @notice Refund a specific bet if market was cancelled
    /// @param marketId identifier of the cancelled market
    function refundBet(uint256 marketId) external nonReentrant {
        if (marketId >= marketCount) revert InvalidMarket(marketId);
        
        (Bet storage userBet, bool isCancelled) = _getMarketCancellationStatus(marketId, msg.sender);
        
        if (!isCancelled) revert("Market not cancelled");
        if (userBet.amount == 0) revert NoBet();
        if (userBet.claimed) revert AlreadyClaimed();
        
        userBet.claimed = true;
        uint256 refundAmount = userBet.amount;
        
        if (address(this).balance < refundAmount) revert InsufficientBalance();
        
        (bool ok, ) = payable(msg.sender).call{ value: refundAmount }("");
        if (!ok) revert TransferFailed();
        emit Payout(marketId, msg.sender, refundAmount);
    }

    /// @notice Emergency pause - stops all betting and claiming
    function emergencyPause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpause contract
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Emergency withdraw - only for stuck funds when paused
    /// @param amount Amount to withdraw
    function emergencyWithdraw(uint256 amount) external onlyRole(TREASURY_ROLE) {
        if (!paused()) revert("Contract must be paused");
        if (amount > address(this).balance) revert InsufficientBalance();
        
        (bool ok, ) = payable(msg.sender).call{ value: amount }("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Grant a role to an address
    /// @param role The role identifier
    /// @param account The address to grant the role to
    function grantRole(bytes32 role, address account) public override onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(role, account);
    }

    /// @notice Revoke a role from an address
    /// @param role The role identifier
    /// @param account The address to revoke the role from
    function revokeRole(bytes32 role, address account) public override onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(role, account);
    }

    /// @notice Internal function to store a bet (implemented by each sport)
    /// @param marketId identifier of the market
    /// @param user address of the bettor
    /// @param amount bet amount in CHZ
    /// @param selection encoded selection
    function _storeBet(uint256 marketId, address user, uint256 amount, uint256 selection) internal virtual;

    /// @notice Internal function to resolve market (implemented by each sport)
    /// @param marketId identifier of the market
    /// @param result encoded result
    function _resolveMarketInternal(uint256 marketId, uint256 result) internal virtual;

    /// @notice Internal function to get market data and user bet (implemented by each sport)
    /// @param marketId identifier of the market
    /// @param user address of the bettor
    /// @return odds multiplier for the market
    /// @return state current state of the market
    /// @return result encoded result of the market
    /// @return userBet storage reference to the user's bet
    function _getMarketAndBet(uint256 marketId, address user) internal view virtual returns (
        uint256 odds,
        State state,
        uint256 result,
        Bet storage userBet
    );

    /// @notice Internal function to cancel a market (implemented by each sport)
    /// @param marketId identifier of the market to cancel
    function _cancelMarketInternal(uint256 marketId) internal virtual;

    /// @notice Internal function to check if market is cancelled and get bet (implemented by each sport)
    /// @param marketId identifier of the market
    /// @param user address of the bettor
    /// @return userBet storage reference to the user's bet
    /// @return isCancelled whether the market is cancelled
    function _getMarketCancellationStatus(uint256 marketId, address user) internal view virtual returns (
        Bet storage userBet,
        bool isCancelled
    );

    /// @notice Storage gap for future upgrades
    uint256[40] private __gap;
}
