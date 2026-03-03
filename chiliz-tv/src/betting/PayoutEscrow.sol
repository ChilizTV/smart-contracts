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
 * @notice Centralized USDT escrow funded by a Gnosis Safe treasury to backstop
 *         betting payouts across all BettingMatch contracts on a network.
 *
 * @dev Architecture:
 *   ┌────────────┐  fund()   ┌──────────────┐  disburseTo()  ┌──────────────┐
 *   │ Gnosis Safe│ ────────> │ PayoutEscrow │ <──────────── │ BettingMatch │
 *   │ (Treasury) │           │ (USDT Pool)  │               │   (Proxy)    │
 *   └────────────┘           └──────────────┘               └──────────────┘
 *
 * Only whitelisted BettingMatch contracts can call `disburseTo()`.
 * The Safe (owner) manages whitelist, funding, withdrawals, and pause state.
 *
 * Security:
 *   - ReentrancyGuard on all state-changing external functions
 *   - SafeERC20 for all token transfers
 *   - Pausable to halt disbursements in emergencies
 *   - Whitelist prevents unauthorized drain
 */
contract PayoutEscrow is IPayoutEscrow, Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ══════════════════════════════════════════════════════════════════════════
    // STATE
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice USDT token used for all escrow operations
    IERC20 public immutable usdt;

    /// @notice Whitelist of BettingMatch contracts authorized to disburse
    mapping(address => bool) public authorizedMatches;

    /// @notice Running total of USDT disbursed to winners (accounting only)
    uint256 public totalDisbursed;

    /// @notice Per-match running total of USDT disbursed (accounting only)
    mapping(address => uint256) public disbursedPerMatch;

    // ══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ══════════════════════════════════════════════════════════════════════════

    event MatchAuthorized(address indexed matchContract);
    event MatchRevoked(address indexed matchContract);
    event Funded(address indexed from, uint256 amount);
    event Disbursed(address indexed matchContract, address indexed recipient, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);

    // ══════════════════════════════════════════════════════════════════════════
    // CUSTOM ERRORS
    // ══════════════════════════════════════════════════════════════════════════

    error UnauthorizedMatch(address caller);
    error InsufficientEscrowBalance(uint256 required, uint256 available);
    error ZeroAddress();
    error ZeroAmount();

    // ══════════════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ══════════════════════════════════════════════════════════════════════════

    modifier onlyAuthorizedMatch() {
        if (!authorizedMatches[msg.sender]) revert UnauthorizedMatch(msg.sender);
        _;
    }

    // ══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ══════════════════════════════════════════════════════════════════════════

    /// @param _usdt USDT token address
    /// @param _owner Owner (Gnosis Safe address)
    constructor(address _usdt, address _owner) Ownable(_owner) {
        if (_usdt == address(0)) revert ZeroAddress();
        usdt = IERC20(_usdt);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // WHITELIST MANAGEMENT (Owner / Safe)
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Authorize a BettingMatch contract to call disburseTo()
    function authorizeMatch(address matchContract) external onlyOwner {
        if (matchContract == address(0)) revert ZeroAddress();
        authorizedMatches[matchContract] = true;
        emit MatchAuthorized(matchContract);
    }

    /// @notice Revoke a BettingMatch contract's authorization
    function revokeMatch(address matchContract) external onlyOwner {
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
    // FUNDING (Safe approves USDT, then calls fund())
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Deposit USDT into the escrow reserve
    /// @param amount USDT amount to deposit
    /// @dev Caller must have approved this contract for `amount` USDT first
    function fund(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        usdt.safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(msg.sender, amount);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // DISBURSEMENT (called by authorized BettingMatch contracts only)
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

        uint256 balance = usdt.balanceOf(address(this));
        if (balance < amount) revert InsufficientEscrowBalance(amount, balance);

        totalDisbursed += amount;
        disbursedPerMatch[msg.sender] += amount;

        usdt.safeTransfer(recipient, amount);
        emit Disbursed(msg.sender, recipient, amount);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // WITHDRAWAL (Safe reclaims unused reserves)
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Withdraw USDT from the escrow (owner only)
    function withdraw(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 balance = usdt.balanceOf(address(this));
        if (balance < amount) revert InsufficientEscrowBalance(amount, balance);
        usdt.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Current USDT balance available for payouts
    function availableBalance() external view returns (uint256) {
        return usdt.balanceOf(address(this));
    }
}
