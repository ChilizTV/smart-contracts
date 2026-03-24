// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IPayoutEscrow} from "../interfaces/IPayoutEscrow.sol";

/**
 * @title PayoutEscrow
 * @author Chiliz Team
 * @notice Centralized USDC escrow funded by a Gnosis Safe treasury to backstop
 *         betting payouts across all BettingMatch contracts on a network.
 *
 * @dev Architecture (one escrow per match):
 *   ┌────────────┐  fund()   ┌──────────────┐  disburseTo()  ┌──────────────┐
 *   │ Gnosis Safe│ ────────> │ PayoutEscrow │ <──────────── │ BettingMatch │
 *   │ (Treasury) │           │ (USDC Pool)  │               │   (Proxy)    │
 *   └────────────┘           └──────────────┘               └──────────────┘
 *
 * Only whitelisted BettingMatch contracts can call `disburseTo()`.
 * Each match has a per-match disbursement cap set at authorization time.
 * The Safe (owner) manages whitelist, caps, funding, withdrawals, and pause state.
 *
 * Security:
 *   - ReentrancyGuard on all state-changing external functions
 *   - SafeERC20 for all token transfers
 *   - Pausable to halt disbursements in emergencies
 *   - Whitelist + per-match cap prevents unauthorized or unbounded drain
 */
contract PayoutEscrow is IPayoutEscrow, Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ══════════════════════════════════════════════════════════════════════════
    // STATE
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice USDC token used for all escrow operations
    IERC20 public immutable usdc;
    /// @notice USDC token used for all escrow operations
    IERC20 public immutable usdc;

    /// @notice The single BettingMatch contract authorized to call disburseTo()
    address public immutable authorizedMatch;

    /// @notice Maximum USDC each match is allowed to draw from this escrow
    mapping(address => uint256) public matchCaps;

    /// @notice Sum of remaining allocations across all authorized matches.
    /// @dev    Invariant: usdc.balanceOf(this) should always be >= totalAllocated once funded.
    ///         freeBalance = max(0, balance - totalAllocated)
    ///         Only free balance may be withdrawn by the owner.
    uint256 public totalAllocated;

    /// @notice Running total of USDC disbursed to winners (accounting only)
    uint256 public totalDisbursed;

    /// @notice Per-match running total of USDC disbursed (accounting only)
    mapping(address => uint256) public disbursedPerMatch;

    // ══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ══════════════════════════════════════════════════════════════════════════

    event MatchAuthorized(address indexed matchContract, uint256 cap);
    event MatchCapUpdated(address indexed matchContract, uint256 newCap);
    event MatchRevoked(address indexed matchContract);
    event Funded(address indexed from, uint256 amount);
    event Disbursed(address indexed recipient, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);

    // ══════════════════════════════════════════════════════════════════════════
    // CUSTOM ERRORS
    // ══════════════════════════════════════════════════════════════════════════

    error UnauthorizedMatch(address caller);
    error AlreadyAuthorized(address matchContract);
    error InsufficientEscrowBalance(uint256 required, uint256 available);
    error InsufficientFreeBalance(uint256 required, uint256 free);
    error MatchCapExceeded(address matchContract, uint256 required, uint256 cap);
    error CapBelowDisbursed(address matchContract, uint256 newCap, uint256 alreadyDisbursed);
    error ZeroAddress();
    error ZeroAmount();

    // ══════════════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ══════════════════════════════════════════════════════════════════════════

    modifier onlyAuthorizedMatch() {
        if (msg.sender != authorizedMatch) revert UnauthorizedCaller(msg.sender);
        _;
    }

    // ══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ══════════════════════════════════════════════════════════════════════════

    /// @param _usdc USDC token address
    /// @param _owner Owner (Gnosis Safe address)
    constructor(address _usdc, address _owner) Ownable(_owner) {
        if (_usdc == address(0)) revert ZeroAddress();
        usdc = IERC20(_usdc);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // WHITELIST MANAGEMENT (Owner / Safe)
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Authorize a BettingMatch contract to call disburseTo() up to `cap` USDC
    /// @param matchContract The BettingMatch proxy address
    /// @param cap Maximum total USDC this match may draw from the escrow
    function authorizeMatch(address matchContract, uint256 cap) external onlyOwner {
        if (matchContract == address(0)) revert ZeroAddress();
        if (cap == 0) revert ZeroAmount();
        // Prevent double-authorization: re-calling would inflate totalAllocated
        // without a corresponding increase in the match's actual cap.
        if (authorizedMatches[matchContract]) revert AlreadyAuthorized(matchContract);
        uint256 disbursed = disbursedPerMatch[matchContract];
        if (cap < disbursed) revert CapBelowDisbursed(matchContract, cap, disbursed);
        authorizedMatches[matchContract] = true;
        matchCaps[matchContract] = cap;
        // Subtract already-disbursed amount: a re-authorized match that previously
        // paid out some funds only needs (cap - disbursed) allocated from the pool.
        totalAllocated += cap - disbursed;
        emit MatchAuthorized(matchContract, cap);
    }

    /// @notice Update the disbursement cap for an already-authorized match
    /// @param matchContract The BettingMatch proxy address
    /// @param newCap New maximum total USDC this match may draw
    function updateMatchCap(address matchContract, uint256 newCap) external onlyOwner {
        if (!authorizedMatches[matchContract]) revert UnauthorizedMatch(matchContract);
        if (newCap == 0) revert ZeroAmount();

        uint256 disbursed = disbursedPerMatch[matchContract];
        if (newCap < disbursed) revert CapBelowDisbursed(matchContract, newCap, disbursed);

        // Adjust totalAllocated by the change in remaining (uncommitted) cap.
        // remaining = cap - disbursed; delta = newRemaining - oldRemaining = newCap - oldCap
        uint256 oldCap = matchCaps[matchContract];
        if (newCap > oldCap) {
            totalAllocated += newCap - oldCap;
        } else {
            totalAllocated -= oldCap - newCap;
        }

        matchCaps[matchContract] = newCap;
        emit MatchCapUpdated(matchContract, newCap);
    }

    /// @notice Revoke a BettingMatch contract's authorization
    function revokeMatch(address matchContract) external onlyOwner {
        if (authorizedMatches[matchContract]) {
            // Release remaining (unused) allocation back to the free pool.
            uint256 remaining = matchCaps[matchContract] - disbursedPerMatch[matchContract];
            if (remaining > 0) totalAllocated -= remaining;
        }
        authorizedMatches[matchContract] = false;
        emit MatchRevoked(matchContract);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // PAUSE (Owner / Safe)
    // ══════════════════════════════════════════════════════════════════════════

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // FUNDING (Safe approves USDC, then calls fund())
    // FUNDING (Safe approves USDC, then calls fund())
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Deposit USDC into the escrow reserve
    /// @param amount USDC amount to deposit
    /// @dev Caller must have approved this contract for `amount` USDC first
    function fund(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(msg.sender, amount);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // DISBURSEMENT (called by authorizedMatch only)
    // ══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IPayoutEscrow
    function disburseTo(address recipient, uint256 amount)
        external
        override
        onlyAuthorizedMatch
        nonReentrant
        whenNotPaused
    {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint256 newDisbursed = disbursedPerMatch[msg.sender] + amount;
        if (newDisbursed > matchCaps[msg.sender]) {
            revert MatchCapExceeded(msg.sender, newDisbursed, matchCaps[msg.sender]);
        }

        uint256 balance = usdc.balanceOf(address(this));
        if (balance < amount) revert InsufficientEscrowBalance(amount, balance);

        totalAllocated -= amount;
        totalDisbursed += amount;
        disbursedPerMatch[msg.sender] = newDisbursed;

        usdc.safeTransfer(recipient, amount);
        emit Disbursed(msg.sender, recipient, amount);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // WITHDRAWAL (Safe reclaims unused reserves)
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Withdraw USDC from the escrow (owner only).
    /// @dev Only free balance (balance − totalAllocated) may be withdrawn so that
    ///      committed match caps are never put at risk.
    function withdraw(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 free = freeBalance();
        if (amount > free) revert InsufficientFreeBalance(amount, free);
        usdc.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Current total USDC balance held by this contract
    function availableBalance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    /// @notice Balance not committed to any authorized match (safe to withdraw)
    /// @dev    freeBalance = max(0, balance − totalAllocated)
    function freeBalance() public view returns (uint256) {
        uint256 balance = usdc.balanceOf(address(this));
        return balance > totalAllocated ? balance - totalAllocated : 0;
    }
}
