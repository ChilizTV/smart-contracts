// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC4626Upgradeable, ERC20Upgradeable, IERC20}
    from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {AccessControlUpgradeable}
    from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable}
    from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable}
    from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable}
    from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Initializable}
    from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math}      from "@openzeppelin/contracts/utils/math/Math.sol";

import {ILiquidityPool} from "../interfaces/ILiquidityPool.sol";

/// @title LiquidityPool
/// @notice ChilizTV's single source of bet liquidity. LPs deposit USDC and
///         receive transferable ERC-4626 shares that auto-compound half of
///         every losing stake as house edge. The other half of each losing
///         stake accrues to the treasury as a pull-based USDC claim.
/// @dev    NAV model:
///             totalAssets() = USDC.balanceOf(this)
///                           - totalLiabilities
///                           - accruedTreasury
///
///         Three distinct claims on the contract's USDC balance:
///         (1) `totalLiabilities`  — owed to winning bettors (senior, hard reserve).
///         (2) `accruedTreasury`   — owed to treasury (pull via `withdrawTreasury`).
///         (3) LP NAV              — residual, priced into ctvLP shares.
///
///         Withdrawals are gated on `freeBalance` (= LP NAV) and a
///         per-depositor cooldown to prevent flash-NAV manipulation.
///
///         Inflation-attack defence: `_decimalsOffset()` returns 6, which
///         mirrors USDC's 6 decimals and gives ctvLP 12 effective decimals.
///         OZ 5.x maps this into virtual shares/assets inside the conversion
///         math, making the classic first-depositor attack uneconomic.
///
///         Roles:
///         - DEFAULT_ADMIN_ROLE: Admin key (operational setters + upgrades).
///                               NOT the treasury — separation is enforced.
///         - MATCH_ROLE:         one per authorized BettingMatch proxy.
///         - ROUTER_ROLE:        ChilizSwapRouter.
///         - PAUSER_ROLE:        emergency stop.
///         - `treasury` address: the ONLY address that can (a) rotate
///                               treasury via 2-step `proposeTreasury` /
///                               `acceptTreasury`, and (b) pull accrued
///                               funds via `withdrawTreasury`.
contract LiquidityPool is
    Initializable,
    ERC4626Upgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    ILiquidityPool
{
    // ═══════════════════════════════════════════════════════════════════════
    // ROLES
    // ═══════════════════════════════════════════════════════════════════════

    bytes32 public constant MATCH_ROLE            = keccak256("MATCH_ROLE");
    bytes32 public constant ROUTER_ROLE           = keccak256("ROUTER_ROLE");
    bytes32 public constant PAUSER_ROLE           = keccak256("PAUSER_ROLE");
    /// @notice Narrow role allowed to grant/revoke `MATCH_ROLE` on match proxies.
    ///         Intended to be granted to the `BettingMatchFactory` so it can
    ///         authorize a freshly-deployed match atomically with its creation.
    ///         DEFAULT_ADMIN_ROLE retains the same authority as a superset.
    bytes32 public constant MATCH_AUTHORIZER_ROLE = keccak256("MATCH_AUTHORIZER_ROLE");

    // ═══════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Basis-point denominator (1 bp = 1 / 10_000).
    uint16 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Upper bound for configurable fees and caps (10%).
    uint16 public constant MAX_BPS_SETTABLE = 1_000;

    /// @notice Treasury's share of every losing stake (50%). Fixed by design —
    ///         the remaining 50% stays in the pool as LP NAV yield.
    uint16 public constant TREASURY_SHARE_BPS = 5_000;

    // ═══════════════════════════════════════════════════════════════════════
    // STORAGE
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Address that receives protocol fees (NOT LP capital).
    address public treasury;

    /// @notice Protocol fee in bps, skimmed from each stake by the router/match.
    uint16 public protocolFeeBps;

    /// @notice Max per-market liability, in bps of `totalAssets()`.
    uint16 public maxLiabilityPerMarketBps;

    /// @notice Max per-match liability, in bps of `totalAssets()`.
    uint16 public maxLiabilityPerMatchBps;

    /// @notice Seconds a depositor must wait between deposit and withdrawal.
    uint48 public depositCooldownSeconds;

    /// @notice Global reserved liability (sum of winning-side payouts owed).
    uint256 public totalLiabilities;

    /// @notice Per-match reserved liability.
    mapping(address bettingMatch => uint256) public matchLiability;

    /// @notice Per-market reserved liability within a match.
    mapping(address bettingMatch => mapping(uint256 marketId => uint256))
        public marketLiability;

    /// @notice Timestamp of last deposit for each share-holder. Bumped on
    ///         share receipt (mint + transfer-in) so cooldown tracks the
    ///         most recent exposure window for that address.
    mapping(address holder => uint48) public lastDepositAt;

    /// @notice Treasury's accrued USDC claim. Physically held inside this
    ///         contract; pullable by `treasury` via `withdrawTreasury`.
    ///         Excluded from `totalAssets()` so LP shares do not reflect
    ///         funds earmarked for the treasury.
    uint256 public accruedTreasury;

    /// @notice Pending treasury address in a 2-step rotation. Cleared on
    ///         `acceptTreasury()` or `cancelTreasuryProposal()`.
    address public pendingTreasury;

    /// @notice Pool-wide per-bet cap in USDC (6 decimals). 0 = disabled.
    ///         Checked on every `recordBet` against `netStake` (post-fee).
    uint256 public maxBetAmount;

    /// @dev Reserved for upgrades. Shrunk from 43 → 40 after appending three
    ///      new storage slots above. Do NOT reorder or delete named slots.
    uint256[40] private __gap;

    // ═══════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    event MatchAuthorized(address indexed bettingMatch);
    event MatchRevoked(address indexed bettingMatch);
    event TreasuryProposed(address indexed proposer, address indexed pending);
    event TreasuryProposalCancelled(address indexed pending);
    event TreasuryAccepted(address indexed oldTreasury, address indexed newTreasury);
    event TreasuryWithdrawn(address indexed to, uint256 amount);
    event TreasuryAccrued(
        address indexed bettingMatch,
        uint256 indexed marketId,
        uint256 losingNetStake,
        uint256 treasuryShare
    );
    event ProtocolFeeSet(uint16 oldBps, uint16 newBps);
    event MaxLiabilityPerMarketSet(uint16 oldBps, uint16 newBps);
    event MaxLiabilityPerMatchSet(uint16 oldBps, uint16 newBps);
    event MaxBetAmountSet(uint256 oldMax, uint256 newMax);
    event DepositCooldownSet(uint48 oldSeconds, uint48 newSeconds);
    event BetRecorded(
        address indexed bettingMatch,
        uint256 indexed marketId,
        address indexed bettor,
        uint256 netStake,
        uint256 netExposure
    );
    event MarketSettled(
        address indexed bettingMatch,
        uint256 indexed marketId,
        uint256 releasedLiability
    );
    event WinnerPaid(
        address indexed bettingMatch,
        uint256 indexed marketId,
        address indexed to,
        uint256 payout
    );
    event RefundPaid(
        address indexed bettingMatch,
        uint256 indexed marketId,
        address indexed to,
        uint256 stake,
        uint256 releasedLiability
    );

    // ═══════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    error ZeroAddress();
    error ZeroAmount();
    error BpsOutOfRange(uint16 provided, uint16 max);
    error MatchNotAuthorized(address bettingMatch);
    error NotMatchAuthorizer(address caller);
    error CooldownActive(address holder, uint48 unlocksAt);
    error InsufficientFreeBalance(uint256 requested, uint256 free);
    error MarketLiabilityCapExceeded(uint256 requested, uint256 cap);
    error MatchLiabilityCapExceeded(uint256 requested, uint256 cap);
    error LiabilityUnderflow();
    error BetAmountAboveCap(uint256 requested, uint256 cap);
    error NotTreasury(address caller, address treasury);
    error NotPendingTreasury(address caller, address pending);
    error NoPendingTreasury();
    error InsufficientTreasuryBalance(uint256 requested, uint256 available);

    // ═══════════════════════════════════════════════════════════════════════
    // INITIALIZER
    // ═══════════════════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice One-shot initializer for the UUPS proxy.
    /// @param usdc_            USDC token address (asset).
    /// @param admin_           DEFAULT_ADMIN_ROLE + PAUSER_ROLE recipient.
    ///                         MUST be distinct from `treasury_` — the admin
    ///                         key cannot redirect accrued treasury funds.
    /// @param treasury_        Initial treasury address (Safe multisig). Sole
    ///                         controller of treasury rotation and accrued
    ///                         balance withdrawals.
    /// @param protocolFeeBps_  Initial protocol fee (<= MAX_BPS_SETTABLE).
    /// @param maxMarketBps_    Initial per-market cap in bps.
    /// @param maxMatchBps_     Initial per-match cap in bps.
    /// @param cooldown_        Initial withdrawal cooldown in seconds.
    function initialize(
        IERC20  usdc_,
        address admin_,
        address treasury_,
        uint16  protocolFeeBps_,
        uint16  maxMarketBps_,
        uint16  maxMatchBps_,
        uint48  cooldown_
    ) external initializer {
        if (address(usdc_) == address(0) || admin_ == address(0) || treasury_ == address(0)) {
            revert ZeroAddress();
        }
        if (protocolFeeBps_  > MAX_BPS_SETTABLE) revert BpsOutOfRange(protocolFeeBps_,  MAX_BPS_SETTABLE);
        if (maxMarketBps_    > BPS_DENOMINATOR)  revert BpsOutOfRange(maxMarketBps_,    BPS_DENOMINATOR);
        if (maxMatchBps_     > BPS_DENOMINATOR)  revert BpsOutOfRange(maxMatchBps_,     BPS_DENOMINATOR);

        __ERC20_init("ChilizTV LP", "ctvLP");
        __ERC4626_init(usdc_);
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(PAUSER_ROLE,        admin_);

        treasury                 = treasury_;
        protocolFeeBps           = protocolFeeBps_;
        maxLiabilityPerMarketBps = maxMarketBps_;
        maxLiabilityPerMatchBps  = maxMatchBps_;
        depositCooldownSeconds   = cooldown_;

        emit TreasuryAccepted(address(0), treasury_);
        emit ProtocolFeeSet(0, protocolFeeBps_);
        emit MaxLiabilityPerMarketSet(0, maxMarketBps_);
        emit MaxLiabilityPerMatchSet(0, maxMatchBps_);
        emit DepositCooldownSet(0, cooldown_);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ERC-4626 OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Assets backing LP shares.
    /// @dev    = USDC.balanceOf(this) − totalLiabilities − accruedTreasury.
    ///         Subtracting `accruedTreasury` is the critical invariant that
    ///         keeps LP NAV from double-counting the treasury's share of
    ///         losing stakes. Clamped to 0 to stay safe if a parameter
    ///         misconfiguration or rounding leaves the pool temporarily
    ///         underwater.
    function totalAssets() public view override returns (uint256) {
        uint256 bal      = IERC20(asset()).balanceOf(address(this));
        uint256 reserved = totalLiabilities + accruedTreasury;
        return bal > reserved ? bal - reserved : 0;
    }

    /// @notice USDC that LPs can collectively withdraw right now (same as
    ///         `totalAssets()`). Exposed as a named symbol so integrations
    ///         and dashboards have a stable, unambiguous endpoint.
    function freeBalance() public view returns (uint256) {
        return totalAssets();
    }

    /// @notice Pool utilization in basis points: reserved bet liabilities
    ///         as a share of LP NAV.
    /// @dev    `totalLiabilities * 10_000 / totalAssets()`. Returns
    ///         `type(uint16).max` if `totalAssets()` is 0 (fully utilized)
    ///         to avoid division-by-zero surprises in off-chain consumers.
    function utilization() public view returns (uint16) {
        uint256 assets = totalAssets();
        if (assets == 0) return totalLiabilities == 0 ? 0 : type(uint16).max;
        uint256 ratio = (totalLiabilities * BPS_DENOMINATOR) / assets;
        return ratio > type(uint16).max ? type(uint16).max : uint16(ratio);
    }

    /// @notice Treasury's currently withdrawable balance. Capped so that
    ///         pulling it can never starve outstanding bet payouts.
    function treasuryWithdrawable() public view returns (uint256) {
        uint256 accrued = accruedTreasury;
        uint256 bal     = IERC20(asset()).balanceOf(address(this));
        uint256 floor   = totalLiabilities;
        uint256 unreserved = bal > floor ? bal - floor : 0;
        return accrued < unreserved ? accrued : unreserved;
    }

    /// @dev ERC-4626 inflation-attack mitigation (OZ 5.x). A non-zero offset
    ///      multiplies share supply by `10 ** offset`, so the cost to mount
    ///      the first-depositor attack grows by the same factor. 6 mirrors
    ///      USDC's decimals and pushes the attack cost well past economic
    ///      viability without burdening normal deposits.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    /// @inheritdoc ERC4626Upgradeable
    /// @dev Bounded by (a) the LP's own share-value (standard ERC-4626) and
    ///      (b) the pool's currently unreserved balance.
    function maxWithdraw(address owner) public view override returns (uint256) {
        uint256 own = super.maxWithdraw(owner);
        uint256 free = freeBalance();
        return own < free ? own : free;
    }

    /// @inheritdoc ERC4626Upgradeable
    function maxRedeem(address owner) public view override returns (uint256) {
        uint256 free = freeBalance();
        uint256 freeInShares = _convertToShares(free, Math.Rounding.Floor);
        uint256 bal = balanceOf(owner);
        return bal < freeInShares ? bal : freeInShares;
    }

    /// @dev Block deposits/withdrawals while paused.
    function deposit(uint256 assets, address receiver)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        return super.deposit(assets, receiver);
    }

    /// @dev Block deposits/withdrawals while paused.
    function mint(uint256 shares, address receiver)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        return super.mint(shares, receiver);
    }

    /// @dev Enforce cooldown; super checks `maxWithdraw` which in turn
    ///      enforces the `freeBalance` gate.
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        _assertCooldown(owner);
        return super.withdraw(assets, receiver, owner);
    }

    /// @dev Enforce cooldown; super checks `maxRedeem` which enforces the
    ///      `freeBalance` gate in share terms.
    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        _assertCooldown(owner);
        return super.redeem(shares, receiver, owner);
    }

    /// @dev Track last-receive time for cooldown. Triggered on mint, burn,
    ///      and transfer. A share recipient inherits a fresh cooldown so the
    ///      vector of "flash-deposit → transfer → flash-withdraw" is closed.
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Upgradeable)
    {
        super._update(from, to, value);
        if (to != address(0)) {
            lastDepositAt[to] = uint48(block.timestamp);
        }
    }

    function _assertCooldown(address holder) internal view {
        uint48 last = lastDepositAt[holder];
        uint48 cooldown = depositCooldownSeconds;
        uint48 unlocks = last + cooldown;
        if (block.timestamp < unlocks) revert CooldownActive(holder, unlocks);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // BETTING-FACING (MATCH_ROLE / ROUTER_ROLE)
    // ═══════════════════════════════════════════════════════════════════════

    modifier onlyMatchOrRouter() {
        if (!hasRole(MATCH_ROLE, msg.sender) && !hasRole(ROUTER_ROLE, msg.sender)) {
            revert MatchNotAuthorized(msg.sender);
        }
        _;
    }

    modifier onlyMatch() {
        if (!hasRole(MATCH_ROLE, msg.sender)) revert MatchNotAuthorized(msg.sender);
        _;
    }

    /// @dev Treasury address is the ONLY authority for treasury rotation
    ///      and accrued-balance withdrawals. Explicitly disjoint from
    ///      DEFAULT_ADMIN_ROLE — admin compromise cannot touch funds.
    modifier onlyTreasury() {
        if (msg.sender != treasury) revert NotTreasury(msg.sender, treasury);
        _;
    }

    /// @inheritdoc ILiquidityPool
    function recordBet(
        address bettingMatch,
        uint256 marketId,
        address bettor,
        uint256 netStake,
        uint256 netExposure
    ) external override whenNotPaused nonReentrant onlyMatchOrRouter {
        if (bettingMatch == address(0) || bettor == address(0)) revert ZeroAddress();
        if (netStake == 0) revert ZeroAmount();
        if (!hasRole(MATCH_ROLE, bettingMatch)) revert MatchNotAuthorized(bettingMatch);

        // Pool-wide per-bet cap (if configured). Checked against the
        // post-fee netStake — that's the amount actually exposed to pool risk.
        uint256 betCap = maxBetAmount;
        if (betCap != 0 && netStake > betCap) revert BetAmountAboveCap(netStake, betCap);

        // netExposure == 0 is legal (1.0000x odds — boundary case). Still enforce
        // caps so a zero-exposure bet can still breach global solvency in edge
        // configurations.
        uint256 newGlobal = totalLiabilities + netExposure;
        if (newGlobal > IERC20(asset()).balanceOf(address(this))) {
            revert InsufficientFreeBalance(netExposure, freeBalance());
        }

        uint256 cap;
        uint256 newMarket = marketLiability[bettingMatch][marketId] + netExposure;
        cap = _capFor(maxLiabilityPerMarketBps);
        if (newMarket > cap) revert MarketLiabilityCapExceeded(newMarket, cap);

        uint256 newMatch = matchLiability[bettingMatch] + netExposure;
        cap = _capFor(maxLiabilityPerMatchBps);
        if (newMatch > cap) revert MatchLiabilityCapExceeded(newMatch, cap);

        totalLiabilities                         = newGlobal;
        marketLiability[bettingMatch][marketId]  = newMarket;
        matchLiability[bettingMatch]             = newMatch;

        emit BetRecorded(bettingMatch, marketId, bettor, netStake, netExposure);
    }

    /// @inheritdoc ILiquidityPool
    /// @dev Two-part settlement in one call:
    ///      1. Release the losing-side reserved liability (bets that won't
    ///         pay out).
    ///      2. Accrue `TREASURY_SHARE_BPS` (50%) of the losing net-stake
    ///         total to the treasury as a pull-based claim. The remaining
    ///         half stays in the USDC balance and compounds into LP NAV
    ///         automatically (since totalAssets tracks balance − liabilities
    ///         − accruedTreasury).
    function settleMarket(
        address bettingMatch,
        uint256 marketId,
        uint256 losingLiabilityToRelease,
        uint256 losingNetStake
    ) external override whenNotPaused nonReentrant onlyMatch {
        uint256 actualReleased;
        if (losingLiabilityToRelease > 0) {
            uint256 m = marketLiability[bettingMatch][marketId];
            actualReleased = losingLiabilityToRelease > m ? m : losingLiabilityToRelease;
            marketLiability[bettingMatch][marketId] = m - actualReleased;
            matchLiability[bettingMatch]            = _safeSub(matchLiability[bettingMatch], actualReleased);
            totalLiabilities                        = _safeSub(totalLiabilities, actualReleased);
        }
        emit MarketSettled(bettingMatch, marketId, actualReleased);

        if (losingNetStake > 0) {
            uint256 share = (losingNetStake * TREASURY_SHARE_BPS) / BPS_DENOMINATOR;
            if (share > 0) {
                accruedTreasury += share;
                emit TreasuryAccrued(bettingMatch, marketId, losingNetStake, share);
            }
        }
    }

    /// @inheritdoc ILiquidityPool
    /// @dev Pays `payout` in USDC and releases `releasedNetExposure` from
    ///      liability counters. The net effect on `totalAssets()`:
    ///         Δ = -payout + releasedNetExposure = -(payout - netExposure) = -netStake
    ///      i.e. LP equity decreases by the stake portion, because the stake
    ///      that was the pool's "pre-loss" cushion now leaves too. Correct:
    ///      at bet time `totalAssets` was unchanged (stake in, netExposure
    ///      reserved); at payout time it drops by exactly the stake, which
    ///      is the pool's realised loss on a winning bet.
    function payWinner(
        address bettingMatch,
        uint256 marketId,
        address to,
        uint256 payout,
        uint256 releasedNetExposure
    ) external override whenNotPaused nonReentrant onlyMatch {
        if (to == address(0)) revert ZeroAddress();
        if (payout == 0) revert ZeroAmount();

        marketLiability[bettingMatch][marketId] =
            _safeSub(marketLiability[bettingMatch][marketId], releasedNetExposure);
        matchLiability[bettingMatch] = _safeSub(matchLiability[bettingMatch], releasedNetExposure);
        totalLiabilities             = _safeSub(totalLiabilities, releasedNetExposure);

        SafeERC20.safeTransfer(IERC20(asset()), to, payout);
        emit WinnerPaid(bettingMatch, marketId, to, payout);
    }

    /// @inheritdoc ILiquidityPool
    function payRefund(
        address bettingMatch,
        uint256 marketId,
        address to,
        uint256 stake,
        uint256 releasedNetExposure
    ) external override whenNotPaused nonReentrant onlyMatch {
        if (to == address(0)) revert ZeroAddress();
        if (stake == 0) revert ZeroAmount();

        marketLiability[bettingMatch][marketId] =
            _safeSub(marketLiability[bettingMatch][marketId], releasedNetExposure);
        matchLiability[bettingMatch] = _safeSub(matchLiability[bettingMatch], releasedNetExposure);
        totalLiabilities             = _safeSub(totalLiabilities, releasedNetExposure);

        SafeERC20.safeTransfer(IERC20(asset()), to, stake);
        emit RefundPaid(bettingMatch, marketId, to, stake, releasedNetExposure);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // GOVERNANCE (DEFAULT_ADMIN_ROLE)
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Accepts either DEFAULT_ADMIN_ROLE (full admin) or the narrower
    ///      MATCH_AUTHORIZER_ROLE (granted to the BettingMatchFactory). Lets a
    ///      factory atomically register the match it just deployed without
    ///      holding full pool admin.
    modifier onlyMatchAuthorizer() {
        if (
            !hasRole(DEFAULT_ADMIN_ROLE, msg.sender) &&
            !hasRole(MATCH_AUTHORIZER_ROLE, msg.sender)
        ) revert NotMatchAuthorizer(msg.sender);
        _;
    }

    /// @notice Grants MATCH_ROLE to a match proxy.
    function authorizeMatch(address bettingMatch)
        external
        onlyMatchAuthorizer
    {
        if (bettingMatch == address(0)) revert ZeroAddress();
        _grantRole(MATCH_ROLE, bettingMatch);
        emit MatchAuthorized(bettingMatch);
    }

    /// @notice Revokes MATCH_ROLE from a match proxy.
    function revokeMatch(address bettingMatch)
        external
        onlyMatchAuthorizer
    {
        _revokeRole(MATCH_ROLE, bettingMatch);
        emit MatchRevoked(bettingMatch);
    }

    function setProtocolFeeBps(uint16 newBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newBps > MAX_BPS_SETTABLE) revert BpsOutOfRange(newBps, MAX_BPS_SETTABLE);
        emit ProtocolFeeSet(protocolFeeBps, newBps);
        protocolFeeBps = newBps;
    }

    function setMaxLiabilityPerMarketBps(uint16 newBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newBps > BPS_DENOMINATOR) revert BpsOutOfRange(newBps, BPS_DENOMINATOR);
        emit MaxLiabilityPerMarketSet(maxLiabilityPerMarketBps, newBps);
        maxLiabilityPerMarketBps = newBps;
    }

    function setMaxLiabilityPerMatchBps(uint16 newBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newBps > BPS_DENOMINATOR) revert BpsOutOfRange(newBps, BPS_DENOMINATOR);
        emit MaxLiabilityPerMatchSet(maxLiabilityPerMatchBps, newBps);
        maxLiabilityPerMatchBps = newBps;
    }

    function setDepositCooldownSeconds(uint48 newSeconds) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit DepositCooldownSet(depositCooldownSeconds, newSeconds);
        depositCooldownSeconds = newSeconds;
    }

    /// @notice Set the pool-wide per-bet cap. 0 disables the check.
    /// @dev    Admin-configurable. Applied to post-fee `netStake` on every
    ///         `recordBet`; does NOT retroactively affect existing bets.
    function setMaxBetAmount(uint256 newMax) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit MaxBetAmountSet(maxBetAmount, newMax);
        maxBetAmount = newMax;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // TREASURY ROTATION (2-step, onlyTreasury)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Propose a new treasury address. Admin CANNOT call this —
    ///         rotation rights belong exclusively to the current treasury.
    function proposeTreasury(address newTreasury) external onlyTreasury {
        if (newTreasury == address(0)) revert ZeroAddress();
        pendingTreasury = newTreasury;
        emit TreasuryProposed(msg.sender, newTreasury);
    }

    /// @notice Cancel a pending treasury proposal.
    function cancelTreasuryProposal() external onlyTreasury {
        address pending = pendingTreasury;
        if (pending == address(0)) revert NoPendingTreasury();
        pendingTreasury = address(0);
        emit TreasuryProposalCancelled(pending);
    }

    /// @notice Accept the treasury role. Must be called from the address
    ///         set via `proposeTreasury` — proves the new address is live
    ///         before handing over withdrawal rights.
    function acceptTreasury() external {
        address pending = pendingTreasury;
        if (pending == address(0)) revert NoPendingTreasury();
        if (msg.sender != pending) revert NotPendingTreasury(msg.sender, pending);
        address old = treasury;
        treasury = pending;
        pendingTreasury = address(0);
        emit TreasuryAccepted(old, pending);
    }

    /// @notice Pull `amount` of accrued USDC to the treasury address.
    /// @dev    Only callable by the current treasury. Funds always go to
    ///         `treasury` (no `to` parameter — the Safe pulls to itself).
    ///         Bounded by `treasuryWithdrawable()` so outstanding bet
    ///         payouts are never starved.
    function withdrawTreasury(uint256 amount)
        external
        onlyTreasury
        whenNotPaused
        nonReentrant
    {
        if (amount == 0) revert ZeroAmount();
        uint256 available = treasuryWithdrawable();
        if (amount > available) revert InsufficientTreasuryBalance(amount, available);

        // CEI: update state before external transfer.
        accruedTreasury -= amount;

        address to = treasury;
        SafeERC20.safeTransfer(IERC20(asset()), to, amount);
        emit TreasuryWithdrawn(to, amount);
    }

    function pause()   external onlyRole(PAUSER_ROLE)        { _pause(); }
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) { _unpause(); }

    /// @dev UUPS upgrade authorization — gated to the admin key (which is
    ///      disjoint from `treasury` by design).
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ═══════════════════════════════════════════════════════════════════════
    // INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════════════

    function _capFor(uint16 bps) internal view returns (uint256) {
        // Caps are relative to total LP capital (totalAssets). Expressed in bps
        // of NAV so as LPs deposit more, caps scale automatically.
        return (totalAssets() * bps) / BPS_DENOMINATOR;
    }

    function _safeSub(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : 0;
    }
}
