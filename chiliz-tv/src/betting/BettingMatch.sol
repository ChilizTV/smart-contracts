// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILiquidityPool} from "../interfaces/ILiquidityPool.sol";

/**
 * @title BettingMatch
 * @author ChilizTV Team
 * @notice Abstract base for UUPS-upgradeable sports betting with dynamic odds.
 *
 * @dev Since the LiquidityPool migration this contract holds NO USDC. All stakes
 *      flow into `LiquidityPool`, all payouts come back out of it. The match is
 *      pure bookkeeping: markets, odds registry, bets, resolution.
 *
 *      Storage invariant: `_marketLiabilities[mktId]` and
 *      `_selectionLiabilities[mktId][sel]` track the TOTAL potential winner
 *      payout reserved for this market/selection, NOT the net exposure. They
 *      are used to compute `losingLiab` on resolution and to release the
 *      correct amount on refund/cancellation. The pool tracks net exposure
 *      separately via its own `marketLiability` / `matchLiability` maps.
 *
 *      Odds are x10000 precision: 2.18x = 21800, min 1.0001x = 10001, max
 *      100x = 1000000.
 */
abstract contract BettingMatch is
    Initializable,
    OwnableUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    // ═══════════════════════════════════════════════════════════════════════
    // CONSTANTS & ROLES
    // ═══════════════════════════════════════════════════════════════════════

    bytes32 public constant ADMIN_ROLE       = keccak256("ADMIN_ROLE");
    bytes32 public constant RESOLVER_ROLE    = keccak256("RESOLVER_ROLE");
    bytes32 public constant PAUSER_ROLE      = keccak256("PAUSER_ROLE");
    bytes32 public constant ODDS_SETTER_ROLE = keccak256("ODDS_SETTER_ROLE");
    bytes32 public constant SWAP_ROUTER_ROLE = keccak256("SWAP_ROUTER_ROLE");

    /// @notice Odds precision: multiply by 10000 (4 decimals).
    uint32 public constant ODDS_PRECISION = 10000;
    uint32 public constant MIN_ODDS       = 10001;   // 1.0001x
    uint32 public constant MAX_ODDS       = 1000000; // 100.00x

    // ═══════════════════════════════════════════════════════════════════════
    // ENUMS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Market lifecycle states.
    enum MarketState {
        Inactive,
        Open,
        Suspended,
        Closed,
        Resolved,
        Cancelled
    }

    // ═══════════════════════════════════════════════════════════════════════
    // STRUCTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Individual bet with odds snapshot. Packed into 2 slots.
    struct Bet {
        uint256 amount;     // Net stake (USDC, 6 decimals) — protocol fee already skimmed
        uint64  selection;
        uint16  oddsIndex;
        uint40  timestamp;
        bool    claimed;
    }

    /// @notice Odds registry for a market (gas-optimized deduplication).
    struct OddsRegistry {
        uint32[] values;
        mapping(uint32 => uint16) toIndex; // 1-based; 0 = not found
        uint16 currentIndex;
    }

    struct MarketCore {
        MarketState state;
        uint64      result;
        uint40      createdAt;
        uint40      resolvedAt;
        uint256     totalPool;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // STORAGE (Upgrade-safe — do not reorder)
    // ═══════════════════════════════════════════════════════════════════════

    string public matchName;
    string public sportType;
    uint256 public marketCount;

    mapping(uint256 => OddsRegistry)                  internal _oddsRegistries;
    mapping(uint256 => mapping(address => Bet[]))     internal _userBets;
    mapping(uint256 => MarketCore)                    internal _marketCores;

    /// @notice USDC token address. Used only for quoting decimals/metadata —
    ///         this contract never holds USDC.
    IERC20 public usdcToken;

    /// @notice LiquidityPool that custodies bet stakes and pays winners.
    ILiquidityPool public liquidityPool;

    /// @notice Per-market TOTAL potential payout (= stake × odds / 10000 summed over bets).
    ///         Drives payout bookkeeping for the match.
    mapping(uint256 => uint256) internal _marketLiabilities;

    /// @notice Per-market/per-selection potential payout. Drives resolution math.
    mapping(uint256 => mapping(uint64 => uint256)) internal _selectionLiabilities;

    /// @notice Per-market TOTAL net exposure (= Σ payout - stake). Mirrors the
    ///         pool's per-market liability accounting and lets us compute the
    ///         exact losing-side release on resolution.
    mapping(uint256 => uint256) internal _marketNetExposure;

    /// @notice Per-market/per-selection net exposure. Parallel to
    ///         `_selectionLiabilities` but tracks net exposure instead of
    ///         full potential payout.
    mapping(uint256 => mapping(uint64 => uint256)) internal _selectionNetExposures;

    /// @notice Per-market TOTAL net stake (post-fee). Running sum across
    ///         all bets on the market; used at resolution to compute the
    ///         losing-side net-stake total passed to `LiquidityPool.settleMarket`
    ///         for treasury accrual.
    mapping(uint256 => uint256) internal _marketNetStake;

    /// @notice Per-market/per-selection net stake (post-fee). Incremented
    ///         on every bet; subtracted from `_marketNetStake` on resolution
    ///         for the winning selection to isolate the losing total.
    mapping(uint256 => mapping(uint64 => uint256)) internal _selectionNetStake;

    /// @notice Per-match admin-configurable maximum odds (post-4-decimal, e.g.
    ///         50000 = 5.00x). Softer cap than the hardcoded `MAX_ODDS`. 0 =
    ///         disabled (uses `MAX_ODDS` as the cap). Gives operators a knob
    ///         to tighten exposure per sport / per deployment without upgrade.
    uint32 public maxAllowedOdds;

    // ═══════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    event MatchInitialized(string indexed name, string sportType, address indexed owner);
    event MarketCreated(uint256 indexed marketId, string marketType, uint32 initialOdds);
    event MarketStateChanged(uint256 indexed marketId, MarketState oldState, MarketState newState);
    event OddsUpdated(uint256 indexed marketId, uint32 oldOdds, uint32 newOdds, uint16 oddsIndex);
    event BetPlaced(
        uint256 indexed marketId,
        address indexed user,
        uint256 betIndex,
        uint256 amount,
        uint64  selection,
        uint32  odds,
        uint16  oddsIndex
    );
    event MarketResolved(uint256 indexed marketId, uint64 result, uint40 resolvedAt);
    event MarketCancelled(uint256 indexed marketId, string reason);
    event Payout(uint256 indexed marketId, address indexed user, uint256 betIndex, uint256 amount);
    event Refund(uint256 indexed marketId, address indexed user, uint256 betIndex, uint256 amount);
    event USDCTokenSet(address indexed token);
    event LiquidityPoolSet(address indexed pool);
    event MaxAllowedOddsSet(uint32 oldMax, uint32 newMax);

    // ═══════════════════════════════════════════════════════════════════════
    // CUSTOM ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    error InvalidMarketId(uint256 marketId);
    error InvalidMarketState(uint256 marketId, MarketState current, MarketState required);
    error InvalidOddsValue(uint32 odds, uint32 min, uint32 max);
    error OddsNotSet(uint256 marketId);
    error ZeroBetAmount();
    error BetNotFound(uint256 marketId, address user, uint256 betIndex);
    error AlreadyClaimed(uint256 marketId, address user, uint256 betIndex);
    error BetLost(uint256 marketId, address user, uint256 betIndex);
    error MaxOddsEntriesReached(uint256 marketId);
    error USDCNotConfigured();
    error LiquidityPoolNotConfigured();

    // ═══════════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════

    modifier validMarket(uint256 marketId) {
        _validMarket(marketId);
        _;
    }

    modifier inState(uint256 marketId, MarketState required) {
        _inState(marketId, required);
        _;
    }

    function _validMarket(uint256 marketId) internal view {
        if (marketId >= marketCount) revert InvalidMarketId(marketId);
    }

    function _inState(uint256 marketId, MarketState required) internal view {
        MarketState current = _marketCores[marketId].state;
        if (current != required) {
            revert InvalidMarketState(marketId, current, required);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // INITIALIZER
    // ═══════════════════════════════════════════════════════════════════════

    // forge-lint: disable-next-line(mixed-case-function)
    function __BettingMatchV2_init(
        string memory _matchName,
        string memory _sportType,
        address _owner
    ) internal onlyInitializing {
        __Ownable_init(_owner);
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        // RESOLVER_ROLE is intentionally NOT granted here. Resolution must be
        // assigned to a dedicated oracle address after deployment via
        // `grantRole(RESOLVER_ROLE, oracle)` to separate the resolver key
        // from the admin key.
        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
        _grantRole(ADMIN_ROLE,         _owner);
        _grantRole(PAUSER_ROLE,        _owner);
        _grantRole(ODDS_SETTER_ROLE,   _owner);

        matchName = _matchName;
        sportType = _sportType;

        emit MatchInitialized(_matchName, _sportType, _owner);
    }

    /// @notice Set the USDC token address (metadata only — this contract holds no USDC).
    function setUSDCToken(address _usdcToken) external onlyRole(ADMIN_ROLE) {
        usdcToken = IERC20(_usdcToken);
        emit USDCTokenSet(_usdcToken);
    }

    /// @notice Set the LiquidityPool used for stake custody and payouts.
    function setLiquidityPool(address _pool) external onlyRole(ADMIN_ROLE) {
        liquidityPool = ILiquidityPool(_pool);
        emit LiquidityPoolSet(_pool);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ODDS MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Set new odds for a market (can be called multiple times).
    /// @dev    If the value already exists in the registry, reuses its index;
    ///         otherwise appends. O(1) lookup via `toIndex`.
    function setMarketOdds(uint256 marketId, uint32 newOdds)
        external
        validMarket(marketId)
        onlyRole(ODDS_SETTER_ROLE)
    {
        _validateOdds(newOdds);

        MarketCore storage core = _marketCores[marketId];
        if (core.state != MarketState.Open && core.state != MarketState.Inactive) {
            revert InvalidMarketState(marketId, core.state, MarketState.Open);
        }

        OddsRegistry storage registry = _oddsRegistries[marketId];
        uint32 oldOdds = _getCurrentOdds(marketId);
        uint16 newIndex = _getOrCreateOddsIndex(marketId, newOdds);
        registry.currentIndex = newIndex;

        emit OddsUpdated(marketId, oldOdds, newOdds, newIndex);
    }

    function _getOrCreateOddsIndex(uint256 marketId, uint32 odds) internal returns (uint16 index) {
        OddsRegistry storage registry = _oddsRegistries[marketId];
        index = registry.toIndex[odds];
        if (index != 0) return index;

        if (registry.values.length >= 65534) revert MaxOddsEntriesReached(marketId);

        registry.values.push(odds);
        index = uint16(registry.values.length); // 1-based
        registry.toIndex[odds] = index;
    }

    function _getCurrentOdds(uint256 marketId) internal view returns (uint32) {
        OddsRegistry storage registry = _oddsRegistries[marketId];
        if (registry.currentIndex == 0) return 0;
        return registry.values[registry.currentIndex - 1];
    }

    function _getOddsByIndex(uint256 marketId, uint16 oddsIndex) internal view returns (uint32) {
        if (oddsIndex == 0) return 0;
        return _oddsRegistries[marketId].values[oddsIndex - 1];
    }

    /// @dev Validates odds against (a) the hardcoded MIN/MAX boundary and
    ///      (b) the softer admin-configurable `maxAllowedOdds` (when non-zero).
    ///      Operational defence against fat-finger odds updates by the backend
    ///      odds-setter key.
    function _validateOdds(uint32 odds) internal view {
        uint32 softCap = maxAllowedOdds;
        uint32 effectiveMax = softCap == 0 ? MAX_ODDS : softCap;
        if (odds < MIN_ODDS || odds > effectiveMax) {
            revert InvalidOddsValue(odds, MIN_ODDS, effectiveMax);
        }
    }

    /// @notice Admin setter for the per-match soft odds cap.
    /// @dev    Must be 0 (disabled) or within [MIN_ODDS, MAX_ODDS]. Takes
    ///         effect for all future `setMarketOdds` calls; does NOT
    ///         retroactively invalidate bets at odds > new cap.
    function setMaxAllowedOdds(uint32 newMax) external onlyRole(ADMIN_ROLE) {
        if (newMax != 0 && (newMax < MIN_ODDS || newMax > MAX_ODDS)) {
            revert InvalidOddsValue(newMax, MIN_ODDS, MAX_ODDS);
        }
        emit MaxAllowedOddsSet(maxAllowedOdds, newMax);
        maxAllowedOdds = newMax;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARKET STATE MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════════

    function openMarket(uint256 marketId)
        external validMarket(marketId) onlyRole(ADMIN_ROLE)
    { _transitionMarketState(marketId, MarketState.Open); }

    function suspendMarket(uint256 marketId)
        external validMarket(marketId) onlyRole(ADMIN_ROLE)
    { _transitionMarketState(marketId, MarketState.Suspended); }

    function closeMarket(uint256 marketId)
        external validMarket(marketId) onlyRole(ADMIN_ROLE)
    { _transitionMarketState(marketId, MarketState.Closed); }

    function cancelMarket(uint256 marketId, string calldata reason)
        external validMarket(marketId) onlyRole(ADMIN_ROLE)
    {
        _transitionMarketState(marketId, MarketState.Cancelled);
        emit MarketCancelled(marketId, reason);
    }

    function _transitionMarketState(uint256 marketId, MarketState newState) internal {
        MarketCore storage core = _marketCores[marketId];
        MarketState oldState = core.state;

        if (newState == MarketState.Open) {
            if (oldState != MarketState.Inactive && oldState != MarketState.Suspended)
                revert InvalidMarketState(marketId, oldState, newState);
        } else if (newState == MarketState.Suspended) {
            if (oldState != MarketState.Open)
                revert InvalidMarketState(marketId, oldState, newState);
        } else if (newState == MarketState.Closed) {
            if (oldState != MarketState.Open && oldState != MarketState.Suspended)
                revert InvalidMarketState(marketId, oldState, newState);
        } else if (newState == MarketState.Cancelled) {
            if (oldState != MarketState.Open && oldState != MarketState.Suspended && oldState != MarketState.Closed)
                revert InvalidMarketState(marketId, oldState, newState);
        } else {
            revert InvalidMarketState(marketId, oldState, newState);
        }

        core.state = newState;
        emit MarketStateChanged(marketId, oldState, newState);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // BETTING CORE
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Pure view of the net exposure the pool would reserve for a bet.
    /// @dev    Returns `amount * currentOdds / 10000 - amount`. Used by the
    ///         swap router to compute `netExposure` in its fee-split flow.
    function quoteNetExposure(uint256 marketId, uint256 amount)
        external
        view
        validMarket(marketId)
        returns (uint256 netExposure)
    {
        uint32 odds = _getCurrentOdds(marketId);
        if (odds == 0) revert OddsNotSet(marketId);
        uint256 potentialPayout = (amount * odds) / ODDS_PRECISION;
        // potentialPayout >= amount since MIN_ODDS > 10000
        return potentialPayout - amount;
    }

    /// @notice Place a bet using USDC. `grossAmount` is skimmed by the pool's
    ///         protocol fee; the net stake is what ends up bound to the bet.
    /// @dev    Caller must approve `grossAmount` USDC to THIS contract.
    function placeBetUSDC(uint256 marketId, uint64 selection, uint256 grossAmount)
        external
        validMarket(marketId)
        inState(marketId, MarketState.Open)
        whenNotPaused
    {
        _placeBetUSDCInternal(msg.sender, marketId, selection, grossAmount, true);
    }

    /// @notice Place a bet on behalf of a user. Called by ChilizSwapRouter
    ///         after it has already transferred `netStake` USDC to the pool
    ///         and paid the protocol fee to treasury.
    /// @dev    Only callable by SWAP_ROUTER_ROLE. `netStake` is the post-fee
    ///         amount that will be bound to the bet.
    function placeBetUSDCFor(address user, uint256 marketId, uint64 selection, uint256 netStake)
        external
        validMarket(marketId)
        inState(marketId, MarketState.Open)
        whenNotPaused
        onlyRole(SWAP_ROUTER_ROLE)
    {
        _placeBetUSDCInternal(user, marketId, selection, netStake, false);
    }

    /// @dev Shared placement logic.
    /// @param transferFrom  true  = direct user bet. We pull gross USDC from
    ///                      the user, skim the pool's protocol fee to
    ///                      treasury, forward netStake to the pool, and
    ///                      record the bet.
    ///                      false = router bet. USDC is already on the pool
    ///                      and fee already paid by the router; we just book
    ///                      the bet.
    function _placeBetUSDCInternal(
        address user,
        uint256 marketId,
        uint64  selection,
        uint256 amount,
        bool    transferFrom
    ) internal {
        if (address(liquidityPool) == address(0)) revert LiquidityPoolNotConfigured();
        if (amount == 0) revert ZeroBetAmount();

        OddsRegistry storage registry = _oddsRegistries[marketId];
        if (registry.currentIndex == 0) revert OddsNotSet(marketId);

        _validateSelection(marketId, selection);

        uint256 netStake;
        if (transferFrom) {
            if (address(usdcToken) == address(0)) revert USDCNotConfigured();
            uint16 feeBps = liquidityPool.protocolFeeBps();
            uint256 fee    = (amount * feeBps) / 10_000;
            netStake       = amount - fee;

            if (fee > 0) {
                SafeERC20.safeTransferFrom(usdcToken, user, liquidityPool.treasury(), fee);
            }
            SafeERC20.safeTransferFrom(usdcToken, user, address(liquidityPool), netStake);
        } else {
            netStake = amount;
        }

        uint32 odds = registry.values[registry.currentIndex - 1];
        uint256 potentialPayout = (netStake * odds) / ODDS_PRECISION;
        uint256 netExposure     = potentialPayout - netStake; // odds > 10000

        _userBets[marketId][user].push(Bet({
            amount:    netStake,
            selection: selection,
            oddsIndex: registry.currentIndex,
            timestamp: uint40(block.timestamp),
            claimed:   false
        }));

        _marketCores[marketId].totalPool             += netStake;
        _marketLiabilities[marketId]                 += potentialPayout;
        _selectionLiabilities[marketId][selection]   += potentialPayout;
        _marketNetExposure[marketId]                 += netExposure;
        _selectionNetExposures[marketId][selection]  += netExposure;
        _marketNetStake[marketId]                    += netStake;
        _selectionNetStake[marketId][selection]      += netStake;

        // Pool-side bookkeeping + solvency / cap enforcement. Reverts here
        // cascade to the user; their USDC transfer is also reverted atomically.
        liquidityPool.recordBet(address(this), marketId, user, netStake, netExposure);

        emit BetPlaced(
            marketId, user,
            _userBets[marketId][user].length - 1,
            netStake, selection, odds, registry.currentIndex
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // RESOLUTION
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Resolve a market with the final result.
    /// @dev    Releases every losing selection's reserved net exposure on the
    ///         pool AND signals the losing net-stake total so the pool can
    ///         accrue the treasury's 50% share. Winning-side reservations
    ///         stay until each winner claims. Net-exposure bookkeeping
    ///         parallels the payout bookkeeping (= `payout - stake`).
    function resolveMarket(uint256 marketId, uint64 result)
        external
        validMarket(marketId)
        onlyRole(RESOLVER_ROLE)
    {
        MarketCore storage core = _marketCores[marketId];
        if (core.state != MarketState.Closed) {
            revert InvalidMarketState(marketId, core.state, MarketState.Closed);
        }
        _validateSelection(marketId, result);

        core.result     = result;
        core.resolvedAt = uint40(block.timestamp);
        core.state      = MarketState.Resolved;

        uint256 losingNetExposure =
            _marketNetExposure[marketId] - _selectionNetExposures[marketId][result];
        uint256 losingPayout =
            _marketLiabilities[marketId] - _selectionLiabilities[marketId][result];
        uint256 losingNetStake =
            _marketNetStake[marketId] - _selectionNetStake[marketId][result];

        _marketNetExposure[marketId] -= losingNetExposure;
        _marketLiabilities[marketId] -= losingPayout;

        liquidityPool.settleMarket(
            address(this),
            marketId,
            losingNetExposure,
            losingNetStake
        );

        emit MarketResolved(marketId, result, core.resolvedAt);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // CLAIM / REFUND
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Claim payout for a winning bet.
    function claim(uint256 marketId, uint256 betIndex)
        external
        nonReentrant
        validMarket(marketId)
        inState(marketId, MarketState.Resolved)
        whenNotPaused
    {
        Bet[] storage userBets = _userBets[marketId][msg.sender];
        if (betIndex >= userBets.length) revert BetNotFound(marketId, msg.sender, betIndex);

        Bet storage bet = userBets[betIndex];
        if (bet.claimed) revert AlreadyClaimed(marketId, msg.sender, betIndex);

        MarketCore storage core = _marketCores[marketId];
        if (bet.selection != core.result) revert BetLost(marketId, msg.sender, betIndex);

        uint32 betOdds = _getOddsByIndex(marketId, bet.oddsIndex);
        uint256 payout = (bet.amount * betOdds) / ODDS_PRECISION;

        // CEI: effects before interactions.
        bet.claimed = true;

        // Our per-market ledger tracked `potentialPayout` for this winning
        // bet. Release it as the winner takes their money out.
        _marketLiabilities[marketId]                  -= payout;
        _selectionLiabilities[marketId][bet.selection] -= payout;

        uint256 netExp = payout - bet.amount;
        _marketNetExposure[marketId]                  -= netExp;
        _selectionNetExposures[marketId][bet.selection] -= netExp;

        // Pool transfers `payout` to the winner and releases `netExp` from
        // its liability ledger (the exact reservation made on `recordBet`).
        liquidityPool.payWinner(address(this), marketId, msg.sender, payout, netExp);

        emit Payout(marketId, msg.sender, betIndex, payout);
    }

    /// @notice Claim refund for a cancelled market.
    function claimRefund(uint256 marketId, uint256 betIndex)
        external
        nonReentrant
        validMarket(marketId)
        inState(marketId, MarketState.Cancelled)
    {
        Bet[] storage userBets = _userBets[marketId][msg.sender];
        if (betIndex >= userBets.length) revert BetNotFound(marketId, msg.sender, betIndex);

        Bet storage bet = userBets[betIndex];
        if (bet.claimed) revert AlreadyClaimed(marketId, msg.sender, betIndex);

        uint256 refund = bet.amount;
        uint32  betOdds = _getOddsByIndex(marketId, bet.oddsIndex);
        uint256 potentialPayout = (refund * betOdds) / ODDS_PRECISION;
        uint256 netExp          = potentialPayout - refund;

        bet.claimed = true;

        _marketLiabilities[marketId]                  -= potentialPayout;
        _selectionLiabilities[marketId][bet.selection] -= potentialPayout;
        _marketNetExposure[marketId]                  -= netExp;
        _selectionNetExposures[marketId][bet.selection] -= netExp;

        liquidityPool.payRefund(address(this), marketId, msg.sender, refund, netExp);
        emit Refund(marketId, msg.sender, betIndex, refund);
    }

    /// @notice Batch claim all winning/refund bets for a market.
    /// @dev    May revert OOG for users with very many bets; use `claimRange`.
    function claimAll(uint256 marketId)
        external
        nonReentrant
        validMarket(marketId)
        whenNotPaused
    {
        MarketState state = _marketCores[marketId].state;
        if (state != MarketState.Resolved && state != MarketState.Cancelled) {
            revert InvalidMarketState(marketId, state, MarketState.Resolved);
        }
        uint256 count = _userBets[marketId][msg.sender].length;
        if (count > 0) _processClaims(marketId, 0, count);
    }

    /// @notice Paginated batch claim — safe alternative for large bet arrays.
    function claimRange(uint256 marketId, uint256 start, uint256 end)
        external
        nonReentrant
        validMarket(marketId)
        whenNotPaused
    {
        MarketState state = _marketCores[marketId].state;
        if (state != MarketState.Resolved && state != MarketState.Cancelled) {
            revert InvalidMarketState(marketId, state, MarketState.Resolved);
        }
        uint256 count = _userBets[marketId][msg.sender].length;
        uint256 cap = end > count ? count : end;
        if (start < cap) _processClaims(marketId, start, cap);
    }

    /// @dev Internal: process winning/refund claims for bets[start..end).
    function _processClaims(uint256 marketId, uint256 start, uint256 end) internal {
        MarketCore storage core = _marketCores[marketId];
        Bet[] storage userBets = _userBets[marketId][msg.sender];

        for (uint256 i = start; i < end; i++) {
            Bet storage bet = userBets[i];
            if (bet.claimed) continue;

            if (core.state == MarketState.Resolved && bet.selection == core.result) {
                uint32 betOdds = _getOddsByIndex(marketId, bet.oddsIndex);
                uint256 payout = (bet.amount * betOdds) / ODDS_PRECISION;
                uint256 netExp = payout - bet.amount;

                bet.claimed = true;
                _marketLiabilities[marketId]                  -= payout;
                _selectionLiabilities[marketId][bet.selection] -= payout;
                _marketNetExposure[marketId]                  -= netExp;
                _selectionNetExposures[marketId][bet.selection] -= netExp;

                liquidityPool.payWinner(address(this), marketId, msg.sender, payout, netExp);
                emit Payout(marketId, msg.sender, i, payout);
            } else if (core.state == MarketState.Cancelled) {
                uint32 betOdds = _getOddsByIndex(marketId, bet.oddsIndex);
                uint256 refund = bet.amount;
                uint256 potentialPayout = (refund * betOdds) / ODDS_PRECISION;
                uint256 netExp = potentialPayout - refund;

                bet.claimed = true;
                _marketLiabilities[marketId]                  -= potentialPayout;
                _selectionLiabilities[marketId][bet.selection] -= potentialPayout;
                _marketNetExposure[marketId]                  -= netExp;
                _selectionNetExposures[marketId][bet.selection] -= netExp;

                liquidityPool.payRefund(address(this), marketId, msg.sender, refund, netExp);
                emit Refund(marketId, msg.sender, i, refund);
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    function getCurrentOdds(uint256 marketId)
        external view validMarket(marketId) returns (uint32)
    { return _getCurrentOdds(marketId); }

    function getOddsHistory(uint256 marketId)
        external view validMarket(marketId) returns (uint32[] memory)
    { return _oddsRegistries[marketId].values; }

    function getUserBets(uint256 marketId, address user)
        external view validMarket(marketId) returns (Bet[] memory)
    { return _userBets[marketId][user]; }

    function getBetDetails(uint256 marketId, address user, uint256 betIndex)
        external
        view
        validMarket(marketId)
        returns (
            uint256 amount,
            uint64  selection,
            uint32  odds,
            uint40  timestamp,
            bool    claimed,
            uint256 potentialPayout
        )
    {
        Bet[] storage userBets = _userBets[marketId][user];
        if (betIndex >= userBets.length) revert BetNotFound(marketId, user, betIndex);
        Bet storage bet = userBets[betIndex];
        uint32 betOdds = _getOddsByIndex(marketId, bet.oddsIndex);
        return (
            bet.amount, bet.selection, betOdds, bet.timestamp, bet.claimed,
            (bet.amount * betOdds) / ODDS_PRECISION
        );
    }

    function getMarketCore(uint256 marketId)
        external view validMarket(marketId) returns (MarketCore memory)
    { return _marketCores[marketId]; }

    /// @notice Per-market potential payout for all open winning-side bets.
    function getMarketLiability(uint256 marketId)
        external view validMarket(marketId) returns (uint256)
    { return _marketLiabilities[marketId]; }

    // ═══════════════════════════════════════════════════════════════════════
    // ADMIN
    // ═══════════════════════════════════════════════════════════════════════

    function emergencyPause() external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause()        external onlyRole(ADMIN_ROLE)  { _unpause(); }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ═══════════════════════════════════════════════════════════════════════
    // ABSTRACT (sport-specific)
    // ═══════════════════════════════════════════════════════════════════════

    function _validateSelection(uint256 marketId, uint64 selection) internal view virtual;

    function addMarketWithLine(bytes32 marketType, uint32 initialOdds, int16 line) external virtual;

    function getMarketInfo(uint256 marketId) external view virtual returns (
        bytes32 marketType,
        MarketState state,
        uint32 currentOdds,
        uint64 result,
        uint256 totalPool
    );

    // ═══════════════════════════════════════════════════════════════════════
    // STORAGE GAP
    // ═══════════════════════════════════════════════════════════════════════

    // Named slots above:
    //   1. matchName
    //   2. sportType
    //   3. marketCount
    //   4. _oddsRegistries (mapping)
    //   5. _userBets (mapping)
    //   6. _marketCores (mapping)
    //   7. usdcToken
    //   8. liquidityPool
    //   9. _marketLiabilities (mapping)
    //  10. _selectionLiabilities (mapping)
    //  11. _marketNetExposure (mapping)
    //  12. _selectionNetExposures (mapping)
    //  13. _marketNetStake (mapping)
    //  14. _selectionNetStake (mapping)
    //  15. maxAllowedOdds (uint32)
    // 15 named slots + 35 gap = 50 total (OZ upgradeable convention).
    uint256[35] private __gap;
}
