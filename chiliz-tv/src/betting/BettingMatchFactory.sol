// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FootballMatch} from "./FootballMatch.sol";
import {BasketballMatch} from "./BasketballMatch.sol";
import {BettingMatch} from "./BettingMatch.sol";
import {ILiquidityPool} from "../interfaces/ILiquidityPool.sol";

/// @title BettingMatchFactory
/// @notice Factory contract to deploy UUPS-upgradeable sport-specific match proxies.
/// @dev Implementation addresses are mutable so bug-fixed implementations can be rolled
///      out to new match deployments without redeploying the factory. Existing proxies
///      are NOT auto-upgraded; their DEFAULT_ADMIN_ROLE holder must call
///      upgradeToAndCall directly (or use the UpgradeBetting script).
///
///      Atomic wiring: `createFootballMatch` / `createBasketballMatch` initialize the
///      match with the factory as temporary admin, then in the same transaction:
///        (1) set USDC + LiquidityPool addresses on the match,
///        (2) grant SWAP_ROUTER_ROLE and RESOLVER_ROLE,
///        (3) grant all admin roles to the intended owner + transfer Ownable,
///        (4) renounce every role held by the factory (DEFAULT_ADMIN last),
///        (5) call `pool.authorizeMatch(proxy)` to whitelist the match.
///
///      Step (5) requires the factory to hold `MATCH_AUTHORIZER_ROLE` on the pool —
///      granted once at deploy time by the pool admin. After construction the
///      match is fully live and ready for bets; no manual cast-send sequence.
contract BettingMatchFactory is Ownable {

    // ══════════════════════════════════════════════════════════════════════════
    // TYPES
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Sport types supported by the factory
    enum SportType { FOOTBALL, BASKETBALL }

    /// @notice Back-compat shorthand for `SportType.FOOTBALL` / `SportType.BASKETBALL`,
    ///         accessible as `BettingMatchFactory.FOOTBALL` / `.BASKETBALL` from
    ///         legacy scripts that predate the named-getter API.
    uint8 public constant FOOTBALL   = uint8(SportType.FOOTBALL);
    uint8 public constant BASKETBALL = uint8(SportType.BASKETBALL);

    // ══════════════════════════════════════════════════════════════════════════
    // STATE
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice List of all deployed match proxy addresses (insertion order)
    address[] public allMatches;

    /// @notice Sport type for each deployed proxy
    mapping(address => SportType) public matchSportType;

    /// @notice Whether an address was deployed by this factory
    mapping(address => bool) public isMatch;

    /// @notice Current FootballMatch implementation used for new proxy deployments.
    /// @dev Mutable — update via setFootballImplementation(). Existing proxies unaffected.
    address public footballImplementation;

    /// @notice Current BasketballMatch implementation used for new proxy deployments.
    /// @dev Mutable — update via setBasketballImplementation(). Existing proxies unaffected.
    address public basketballImplementation;

    /// @notice LiquidityPool that new matches are wired to.
    /// @dev Must be set via `setWiring` before any match is created.
    address public liquidityPool;

    /// @notice USDC token set on every new match.
    address public usdcToken;

    /// @notice ChilizSwapRouter granted SWAP_ROUTER_ROLE on every new match.
    address public swapRouter;

    // ══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Emitted when a new match proxy is created (post-wiring)
    event MatchCreated(address indexed proxy, SportType sportType, address indexed owner);

    /// @notice Emitted when the football implementation pointer is updated
    event FootballImplementationUpdated(address indexed oldImpl, address indexed newImpl);

    /// @notice Emitted when the basketball implementation pointer is updated
    event BasketballImplementationUpdated(address indexed oldImpl, address indexed newImpl);

    /// @notice Emitted when the post-deploy wiring config is updated
    event WiringSet(address indexed liquidityPool, address indexed usdcToken, address indexed swapRouter);

    // ══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ══════════════════════════════════════════════════════════════════════════

    error MatchNotFound(address matchAddress);
    error InvalidAddress();
    error WiringNotConfigured();

    // ══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Deploy initial implementations and initialize the factory
    constructor() Ownable(msg.sender) {
        footballImplementation   = address(new FootballMatch());
        basketballImplementation = address(new BasketballMatch());
    }

    // ══════════════════════════════════════════════════════════════════════════
    // WIRING CONFIG
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Set the pool / USDC / swap router addresses that new matches are wired to.
    /// @dev Must be called before the first `createFootballMatch` / `createBasketballMatch`.
    ///      Pool admin must additionally grant `MATCH_AUTHORIZER_ROLE` on the pool to
    ///      this factory, otherwise the in-transaction `pool.authorizeMatch` call reverts.
    function setWiring(address _liquidityPool, address _usdcToken, address _swapRouter)
        external
        onlyOwner
    {
        if (_liquidityPool == address(0) || _usdcToken == address(0) || _swapRouter == address(0)) {
            revert InvalidAddress();
        }
        liquidityPool = _liquidityPool;
        usdcToken     = _usdcToken;
        swapRouter    = _swapRouter;
        emit WiringSet(_liquidityPool, _usdcToken, _swapRouter);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // MATCH DEPLOYMENT
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Deploy, initialize, and fully wire a FootballMatch UUPS proxy.
    /// @param _matchName Human-readable match name
    /// @param _owner     Address that receives ownership + admin roles on the match
    /// @param _oracle    Address that receives `RESOLVER_ROLE` on the match
    /// @return proxy     Address of the newly deployed, ready-to-bet match
    function createFootballMatch(
        string calldata _matchName,
        address _owner,
        address _oracle
    ) external onlyOwner returns (address proxy) {
        _requireWiring();
        if (_owner == address(0) || _oracle == address(0)) revert InvalidAddress();

        // Initialize with the factory as temp admin so we can configure + hand off.
        bytes memory initData = abi.encodeWithSelector(
            FootballMatch.initialize.selector,
            _matchName,
            address(this)
        );
        proxy = address(new ERC1967Proxy(footballImplementation, initData));
        allMatches.push(proxy);
        isMatch[proxy]        = true;
        matchSportType[proxy] = SportType.FOOTBALL;

        _wireMatch(proxy, _owner, _oracle);

        emit MatchCreated(proxy, SportType.FOOTBALL, _owner);
    }

    /// @notice Deploy, initialize, and fully wire a BasketballMatch UUPS proxy.
    /// @param _matchName Human-readable match name
    /// @param _owner     Address that receives ownership + admin roles on the match
    /// @param _oracle    Address that receives `RESOLVER_ROLE` on the match
    /// @return proxy     Address of the newly deployed, ready-to-bet match
    function createBasketballMatch(
        string calldata _matchName,
        address _owner,
        address _oracle
    ) external onlyOwner returns (address proxy) {
        _requireWiring();
        if (_owner == address(0) || _oracle == address(0)) revert InvalidAddress();

        bytes memory initData = abi.encodeWithSelector(
            BasketballMatch.initialize.selector,
            _matchName,
            address(this)
        );
        proxy = address(new ERC1967Proxy(basketballImplementation, initData));
        allMatches.push(proxy);
        isMatch[proxy]        = true;
        matchSportType[proxy] = SportType.BASKETBALL;

        _wireMatch(proxy, _owner, _oracle);

        emit MatchCreated(proxy, SportType.BASKETBALL, _owner);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // IMPLEMENTATION MANAGEMENT (Owner)
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Point the factory at a new FootballMatch implementation for future deployments.
    /// @dev Does NOT affect already-deployed proxies. Upgrade existing matches individually
    ///      via the UpgradeBetting script or upgradeToAndCall on the proxy directly.
    function setFootballImplementation(address newImpl) external onlyOwner {
        if (newImpl == address(0)) revert InvalidAddress();
        address old = footballImplementation;
        footballImplementation = newImpl;
        emit FootballImplementationUpdated(old, newImpl);
    }

    /// @notice Point the factory at a new BasketballMatch implementation for future deployments.
    function setBasketballImplementation(address newImpl) external onlyOwner {
        if (newImpl == address(0)) revert InvalidAddress();
        address old = basketballImplementation;
        basketballImplementation = newImpl;
        emit BasketballImplementationUpdated(old, newImpl);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Retrieve all deployed proxy addresses (insertion order)
    function getAllMatches() external view returns (address[] memory) {
        return allMatches;
    }

    /// @notice Get the sport type of a specific match proxy
    function getSportType(address matchAddress) external view returns (SportType) {
        if (!isMatch[matchAddress]) revert MatchNotFound(matchAddress);
        return matchSportType[matchAddress];
    }

    /// @notice Back-compat accessor: look up an implementation address by sport id.
    /// @dev    Legacy callers used `factory.implementations(FOOTBALL)`. The modern
    ///         equivalents are `footballImplementation()` / `basketballImplementation()`.
    ///         Kept here so older deployment scripts compile unchanged.
    function implementations(uint8 sport) external view returns (address) {
        if (sport == FOOTBALL)   return footballImplementation;
        if (sport == BASKETBALL) return basketballImplementation;
        revert InvalidAddress();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // INTERNAL
    // ══════════════════════════════════════════════════════════════════════════

    function _requireWiring() internal view {
        if (liquidityPool == address(0) || usdcToken == address(0) || swapRouter == address(0)) {
            revert WiringNotConfigured();
        }
    }

    /// @dev Full wiring sequence for a freshly-initialized match where the factory
    ///      is the current DEFAULT_ADMIN / ADMIN / PAUSER / ODDS_SETTER and Ownable owner.
    ///      After this function:
    ///        - match is configured with USDC + LiquidityPool
    ///        - swap router + oracle have their roles
    ///        - intended owner holds every admin role + Ownable ownership
    ///        - factory holds NO role on the match
    ///        - match is authorized on the pool (MATCH_ROLE granted)
    function _wireMatch(address proxy, address _owner, address _oracle) internal {
        BettingMatch m = BettingMatch(payable(proxy));

        // 1) Wire USDC + pool (ADMIN_ROLE-gated).
        m.setUSDCToken(usdcToken);
        m.setLiquidityPool(liquidityPool);

        // 2) Grant operational roles (DEFAULT_ADMIN_ROLE-gated).
        m.grantRole(m.SWAP_ROUTER_ROLE(), swapRouter);
        m.grantRole(m.RESOLVER_ROLE(),    _oracle);

        // 3) Hand admin roles to the intended owner.
        m.grantRole(m.DEFAULT_ADMIN_ROLE(), _owner);
        m.grantRole(m.ADMIN_ROLE(),        _owner);
        m.grantRole(m.PAUSER_ROLE(),       _owner);
        m.grantRole(m.ODDS_SETTER_ROLE(),  _owner);
        m.transferOwnership(_owner);

        // 4) Authorize the match on the pool BEFORE we drop our admin — if the
        //    factory doesn't hold MATCH_AUTHORIZER_ROLE on the pool this reverts
        //    and the entire match deployment is rolled back.
        ILiquidityPool(liquidityPool).authorizeMatch(proxy);

        // 5) Renounce every role the factory still holds. DEFAULT_ADMIN_ROLE last
        //    because it is the admin role for the others in AccessControl.
        m.renounceRole(m.ADMIN_ROLE(),         address(this));
        m.renounceRole(m.PAUSER_ROLE(),        address(this));
        m.renounceRole(m.ODDS_SETTER_ROLE(),   address(this));
        m.renounceRole(m.DEFAULT_ADMIN_ROLE(), address(this));
    }
}
