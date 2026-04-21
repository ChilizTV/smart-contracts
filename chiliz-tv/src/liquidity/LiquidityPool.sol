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
///         receive transferable ERC-4626 shares that auto-compound the house
///         edge priced into fixed odds. All bet stakes enter this contract;
///         `BettingMatch` proxies hold no USDC.
/// @dev    NAV model: `totalAssets() = USDC.balanceOf(this) - totalLiabilities`.
///         Withdrawals are gated on `freeBalance` (unreserved USDC) and a
///         per-depositor cooldown to prevent flash-NAV manipulation.
///
///         Roles:
///         - DEFAULT_ADMIN_ROLE: Safe multisig. Controls setters and upgrades.
///         - MATCH_ROLE:        one per authorized BettingMatch proxy.
///         - ROUTER_ROLE:       ChilizSwapRouter.
///         - PAUSER_ROLE:       emergency stop.
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

    bytes32 public constant MATCH_ROLE  = keccak256("MATCH_ROLE");
    bytes32 public constant ROUTER_ROLE = keccak256("ROUTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ═══════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Basis-point denominator (1 bp = 1 / 10_000).
    uint16 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Upper bound for configurable fees and caps (10%).
    uint16 public constant MAX_BPS_SETTABLE = 1_000;

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

    /// @dev Reserved for upgrades. Size chosen to pad the structure to a
    ///      predictable 50-slot footprint.
    uint256[43] private __gap;

    // ═══════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    event MatchAuthorized(address indexed bettingMatch);
    event MatchRevoked(address indexed bettingMatch);
    event TreasurySet(address indexed oldTreasury, address indexed newTreasury);
    event ProtocolFeeSet(uint16 oldBps, uint16 newBps);
    event MaxLiabilityPerMarketSet(uint16 oldBps, uint16 newBps);
    event MaxLiabilityPerMatchSet(uint16 oldBps, uint16 newBps);
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
    error CooldownActive(address holder, uint48 unlocksAt);
    error InsufficientFreeBalance(uint256 requested, uint256 free);
    error MarketLiabilityCapExceeded(uint256 requested, uint256 cap);
    error MatchLiabilityCapExceeded(uint256 requested, uint256 cap);
    error LiabilityUnderflow();

    // ═══════════════════════════════════════════════════════════════════════
    // INITIALIZER
    // ═══════════════════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice One-shot initializer for the UUPS proxy.
    /// @param usdc_            USDC token address (asset).
    /// @param admin_           DEFAULT_ADMIN_ROLE + PAUSER_ROLE recipient (Safe).
    /// @param treasury_        Protocol fee recipient.
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

        emit TreasurySet(address(0), treasury_);
        emit ProtocolFeeSet(0, protocolFeeBps_);
        emit MaxLiabilityPerMarketSet(0, maxMarketBps_);
        emit MaxLiabilityPerMatchSet(0, maxMatchBps_);
        emit DepositCooldownSet(0, cooldown_);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ERC-4626 OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Assets backing LP shares = USDC balance minus reserved winner liabilities.
    function totalAssets() public view override returns (uint256) {
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        return bal > totalLiabilities ? bal - totalLiabilities : 0;
    }

    /// @notice USDC not reserved for potential winners. Same value as
    ///         `totalAssets()` in this design; kept as a distinct symbol for
    ///         readability in revert messages and integration code.
    function freeBalance() public view returns (uint256) {
        return totalAssets();
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
    function settleMarket(
        address bettingMatch,
        uint256 marketId,
        uint256 losingLiabilityToRelease
    ) external override whenNotPaused nonReentrant onlyMatch {
        if (losingLiabilityToRelease == 0) {
            emit MarketSettled(bettingMatch, marketId, 0);
            return;
        }

        uint256 m = marketLiability[bettingMatch][marketId];
        uint256 actual = losingLiabilityToRelease > m ? m : losingLiabilityToRelease;

        marketLiability[bettingMatch][marketId] = m - actual;
        matchLiability[bettingMatch]            = _safeSub(matchLiability[bettingMatch], actual);
        totalLiabilities                        = _safeSub(totalLiabilities, actual);

        emit MarketSettled(bettingMatch, marketId, actual);
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

    /// @notice Grants MATCH_ROLE to a match proxy.
    function authorizeMatch(address bettingMatch)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (bettingMatch == address(0)) revert ZeroAddress();
        _grantRole(MATCH_ROLE, bettingMatch);
        emit MatchAuthorized(bettingMatch);
    }

    /// @notice Revokes MATCH_ROLE from a match proxy.
    function revokeMatch(address bettingMatch)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _revokeRole(MATCH_ROLE, bettingMatch);
        emit MatchRevoked(bettingMatch);
    }

    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasury == address(0)) revert ZeroAddress();
        emit TreasurySet(treasury, newTreasury);
        treasury = newTreasury;
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

    function pause()   external onlyRole(PAUSER_ROLE)        { _pause(); }
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) { _unpause(); }

    /// @dev UUPS upgrade authorization — restricted to Safe.
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
