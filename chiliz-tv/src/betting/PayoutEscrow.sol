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
 * @notice Dedicated USDC escrow for a single BettingMatch contract, funded by a
 *         Gnosis Safe treasury to backstop payout shortfalls.
 *
 * @dev Architecture (one escrow per match):
 *   ┌────────────┐  fund()   ┌──────────────┐  disburseTo()  ┌──────────────┐
 *   │ Gnosis Safe│ ────────> │ PayoutEscrow │ <──────────── │ BettingMatch │
 *   │ (Treasury) │           │  (USDC Pool) │  (immutable)  │   (Proxy)    │
 *   └────────────┘           └──────────────┘               └──────────────┘
 *
 * Only the single `authorizedMatch` set at construction can call `disburseTo()`.
 * Eliminates the shared-pool blast radius: a compromised match can only drain
 * its own escrow, not every other match's backstop.
 *
 * Security:
 *   - ReentrancyGuard on all state-changing external functions
 *   - SafeERC20 for all token transfers
 *   - Pausable to halt disbursements in emergencies
 *   - Single immutable authorized match (no whitelist management needed)
 */
contract PayoutEscrow is IPayoutEscrow, Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ══════════════════════════════════════════════════════════════════════════
    // STATE
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice USDC token used for all escrow operations
    IERC20 public immutable usdc;

    /// @notice The single BettingMatch contract authorized to call disburseTo()
    address public immutable authorizedMatch;

    /// @notice Running total of USDC disbursed to winners (accounting only)
    uint256 public totalDisbursed;

    // ══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ══════════════════════════════════════════════════════════════════════════

    event Funded(address indexed from, uint256 amount);
    event Disbursed(address indexed recipient, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);

    // ══════════════════════════════════════════════════════════════════════════
    // CUSTOM ERRORS
    // ══════════════════════════════════════════════════════════════════════════

    error UnauthorizedCaller(address caller);
    error InsufficientEscrowBalance(uint256 required, uint256 available);
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

    /// @param _usdc           USDC token address
    /// @param _authorizedMatch The single BettingMatch proxy this escrow serves
    /// @param _owner          Owner (Gnosis Safe address)
    constructor(address _usdc, address _authorizedMatch, address _owner) Ownable(_owner) {
        if (_usdc == address(0)) revert ZeroAddress();
        if (_authorizedMatch == address(0)) revert ZeroAddress();
        usdc = IERC20(_usdc);
        authorizedMatch = _authorizedMatch;
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
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Deposit USDC into the escrow reserve
    /// @param amount USDC amount to deposit
    /// @dev Caller must have approved this contract for `amount` USDC first
    function fund(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();
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

        uint256 balance = usdc.balanceOf(address(this));
        if (balance < amount) revert InsufficientEscrowBalance(amount, balance);

        totalDisbursed += amount;
        usdc.safeTransfer(recipient, amount);
        emit Disbursed(recipient, amount);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // WITHDRAWAL (Safe reclaims unused reserves)
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Withdraw USDC from the escrow (owner only)
    function withdraw(uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 balance = usdc.balanceOf(address(this));
        if (balance < amount) revert InsufficientEscrowBalance(amount, balance);
        usdc.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Current USDC balance available for payouts
    function availableBalance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }
}
