// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test, console} from "forge-std/Test.sol";
import {FootballMatch} from "../src/betting/FootballMatch.sol";
import {BettingMatch} from "../src/betting/BettingMatch.sol";
import {LiquidityPool} from "../src/liquidity/LiquidityPool.sol";
import {ILiquidityPool} from "../src/interfaces/ILiquidityPool.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @title LiquidityPoolV2Test
/// @notice Tests for the V2 LiquidityPool behaviours introduced alongside the
///         BettingMatch ↔ LiquidityPool integration:
///           - 50/50 loss split (LP / accruedTreasury)
///           - Pull-based `withdrawTreasury` with solvency bound
///           - 2-step treasury rotation (propose / accept / cancel)
///           - Admin / treasury role separation
///           - Pool-wide `maxBetAmount` cap
///           - `maxAllowedOdds` per-match soft cap
///           - ERC-4626 inflation-attack mitigation via `_decimalsOffset = 6`
///           - `utilization()` and `maxWithdraw` gating
contract LiquidityPoolV2Test is Test {
    // ────────────────────────── actors ──────────────────────────
    address internal admin    = address(0xA11CE);
    address internal treasury = address(0xB0B);
    address internal newSafe  = address(0xCAFEBABE);
    address internal oddsSetter = address(0xDEAD);
    address internal resolver   = address(0xBEEF);
    address internal lp       = address(0x1111);
    address internal alice    = address(0x2222);
    address internal bob      = address(0x3333);

    // ────────────────────────── contracts ───────────────────────
    MockUSDC      internal usdc;
    LiquidityPool internal pool;
    FootballMatch internal footballMatch;

    // ────────────────────────── constants ───────────────────────
    bytes32 constant ADMIN_ROLE         = keccak256("ADMIN_ROLE");
    bytes32 constant ODDS_SETTER_ROLE   = keccak256("ODDS_SETTER_ROLE");
    bytes32 constant RESOLVER_ROLE      = keccak256("RESOLVER_ROLE");
    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 constant MARKET_WINNER      = keccak256("WINNER");

    uint32 constant ODDS_PRECISION = 10_000;

    function setUp() public {
        usdc = new MockUSDC();

        // Pool: admin ≠ treasury (role separation under test)
        LiquidityPool poolImpl = new LiquidityPool();
        bytes memory poolInit = abi.encodeWithSelector(
            LiquidityPool.initialize.selector,
            address(usdc),
            admin,
            treasury,
            uint16(0),      // protocol fee: 0 for clean math
            uint16(9000),   // per-market cap: 90%
            uint16(9500),   // per-match cap: 95%
            uint48(0)       // cooldown: 0
        );
        pool = LiquidityPool(address(new ERC1967Proxy(address(poolImpl), poolInit)));

        // BettingMatch
        FootballMatch impl = new FootballMatch();
        bytes memory matchInit = abi.encodeWithSelector(
            FootballMatch.initialize.selector,
            "Test Match",
            admin
        );
        footballMatch = FootballMatch(payable(address(new ERC1967Proxy(address(impl), matchInit))));

        vm.startPrank(admin);
        footballMatch.grantRole(ODDS_SETTER_ROLE, oddsSetter);
        footballMatch.grantRole(RESOLVER_ROLE, resolver);
        footballMatch.setUSDCToken(address(usdc));
        footballMatch.setLiquidityPool(address(pool));
        pool.authorizeMatch(address(footballMatch));
        vm.stopPrank();

        // Fund actors
        usdc.mint(lp,    1_000_000e6);
        usdc.mint(alice,   100_000e6);
        usdc.mint(bob,     100_000e6);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ERC-4626 INFLATION-ATTACK MITIGATION
    // ═══════════════════════════════════════════════════════════════════════

    function test_DecimalsOffsetPreventsFirstDepositorAttack() public {
        // OZ 5.x _decimalsOffset = 6 → ctvLP has 12 decimals (USDC 6 + 6).
        assertEq(pool.decimals(), 12, "ctvLP should have 12 decimals");

        // First depositor receives shares scaled by 10^6 — attacker trying to
        // inflate share price via 1-wei deposit + direct transfer would need
        // to commit impractical capital to deflate later depositors' shares.
        vm.startPrank(lp);
        usdc.approve(address(pool), 1e6); // 1 USDC
        uint256 shares = pool.deposit(1e6, lp);
        vm.stopPrank();

        // With offset = 6: 1 USDC asset → 10^6 × 10^6 = 10^12 shares.
        assertEq(shares, 1e12, "1 USDC should mint 1e12 shares (offset defends inflation)");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // LOSS SPLIT (50% LP / 50% accrued treasury)
    // ═══════════════════════════════════════════════════════════════════════

    function test_LossSplit_AccruesHalfToTreasury_HalfToLPs() public {
        // LP seeds 10,000 USDC → totalAssets 10,000 → shares = 10,000 × 10^6 = 10^10
        _seedPool(10_000e6);
        uint256 lpShares = pool.balanceOf(lp);
        uint256 navBefore = pool.totalAssets();
        assertEq(navBefore, 10_000e6, "seed NAV");

        // Market: alice bets 100 at 2.00x on selection 0. Resolve selection 1.
        uint256 marketId = _newMarketAtOdds(20_000);
        _placeBet(alice, marketId, 0 /* losing */, 100e6);

        vm.prank(admin);
        footballMatch.closeMarket(marketId);
        vm.prank(resolver);
        footballMatch.resolveMarket(marketId, 1 /* alice's bet loses */);

        // Post-resolve expectations:
        //   accruedTreasury = 50 (50% × 100 losing netStake)
        //   LP NAV = 10,000 + 50 (the other half of the losing stake)
        assertEq(pool.accruedTreasury(), 50e6, "treasury accrued 50 USDC");
        assertEq(pool.totalAssets(), 10_050e6, "LP NAV up by 50 USDC");
        assertEq(pool.balanceOf(lp), lpShares, "LP shares unchanged");

        // Share price ≈ 1.005 USDC for 1e12 shares (= 1 ctvLP "unit"). Exact
        // value is 1.005 × 10^6 − 1 wei due to OZ's _decimalsOffset virtual
        // +1 / +10^offset rounding in convertToAssets.
        uint256 assetsPerShare = pool.convertToAssets(1e12);
        assertApproxEqAbs(assetsPerShare, 1_005_000, 1, "share price ~1.005 USDC");
    }

    function test_LossSplit_NoAccrualWhenAllBetsWin() public {
        _seedPool(10_000e6);

        uint256 marketId = _newMarketAtOdds(20_000);
        _placeBet(alice, marketId, 0, 100e6);

        vm.prank(admin);
        footballMatch.closeMarket(marketId);
        vm.prank(resolver);
        footballMatch.resolveMarket(marketId, 0 /* alice wins */);

        assertEq(pool.accruedTreasury(), 0, "no accrual when winner-only market");
    }

    function test_LossSplit_MixedBetsOnlyAccrueLosingStakes() public {
        _seedPool(10_000e6);

        uint256 marketId = _newMarketAtOdds(20_000);
        _placeBet(alice, marketId, 0 /* wins */, 100e6);
        _placeBet(bob,   marketId, 1 /* loses */, 300e6);

        vm.prank(admin);
        footballMatch.closeMarket(marketId);
        vm.prank(resolver);
        footballMatch.resolveMarket(marketId, 0);

        // Only bob's 300 losing netStake accrues → 150 to treasury.
        assertEq(pool.accruedTreasury(), 150e6, "accruedTreasury = 50% of losing");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // WITHDRAW TREASURY (pull-based)
    // ═══════════════════════════════════════════════════════════════════════

    function test_WithdrawTreasury_TransfersToTreasury() public {
        _accrueTreasury(400e6);
        uint256 balBefore = usdc.balanceOf(treasury);

        vm.prank(treasury);
        pool.withdrawTreasury(100e6);

        assertEq(usdc.balanceOf(treasury) - balBefore, 100e6, "treasury received 100 USDC");
        assertEq(pool.accruedTreasury(), 300e6, "accrued reduced");
    }

    function test_WithdrawTreasury_RevertsForNonTreasuryCaller() public {
        _accrueTreasury(400e6);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidityPool.NotTreasury.selector, admin, treasury
            )
        );
        pool.withdrawTreasury(100e6);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidityPool.NotTreasury.selector, alice, treasury
            )
        );
        pool.withdrawTreasury(100e6);
    }

    function test_WithdrawTreasury_RevertsWhenAmountExceedsAccrued() public {
        _accrueTreasury(400e6);

        vm.prank(treasury);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidityPool.InsufficientTreasuryBalance.selector, 500e6, 400e6
            )
        );
        pool.withdrawTreasury(500e6);
    }

    function test_WithdrawTreasury_RevertsOnZeroAmount() public {
        _accrueTreasury(100e6);

        vm.prank(treasury);
        vm.expectRevert(LiquidityPool.ZeroAmount.selector);
        pool.withdrawTreasury(0);
    }

    function test_WithdrawTreasury_DoesNotChangeLPNAV() public {
        _accrueTreasury(400e6);
        uint256 navBefore = pool.totalAssets();

        vm.prank(treasury);
        pool.withdrawTreasury(400e6);

        assertEq(pool.totalAssets(), navBefore, "LP NAV untouched by treasury pull");
    }

    function test_TreasuryWithdrawable_BoundedByFreeUSDC() public {
        // Accrue 400. Then create outstanding liabilities that eat into USDC.
        _accrueTreasury(400e6);

        // Take a huge bet to lock the pool: netExposure grows totalLiabilities.
        // We'll stop short of actually creating liabilities > USDC, but the
        // view must correctly cap withdrawable to `USDC − totalLiabilities`.
        // Simulate by placing a losing-side bet that does NOT resolve — it
        // keeps liability live.
        uint256 marketId = _newMarketAtOdds(50_000); // 5.00x
        // Need a large LP buffer to allow this bet; pool already has seed + accrued funds
        _placeBet(alice, marketId, 0, 3_000e6); // netExposure = 12_000e6
        // Don't resolve; liability stays reserved.

        uint256 avail = pool.treasuryWithdrawable();
        uint256 accrued = pool.accruedTreasury();
        uint256 bal = usdc.balanceOf(address(pool));
        uint256 totalLiab = pool.totalLiabilities();
        uint256 unreserved = bal > totalLiab ? bal - totalLiab : 0;
        assertEq(avail, accrued < unreserved ? accrued : unreserved, "withdrawable bound");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // TREASURY ROTATION (2-step)
    // ═══════════════════════════════════════════════════════════════════════

    function test_ProposeTreasury_OnlyCurrentTreasuryCanCall() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(LiquidityPool.NotTreasury.selector, admin, treasury)
        );
        pool.proposeTreasury(newSafe);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(LiquidityPool.NotTreasury.selector, alice, treasury)
        );
        pool.proposeTreasury(newSafe);
    }

    function test_AcceptTreasury_RequiresPendingMatch() public {
        vm.prank(treasury);
        pool.proposeTreasury(newSafe);
        assertEq(pool.pendingTreasury(), newSafe);

        // Random address cannot accept
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(LiquidityPool.NotPendingTreasury.selector, alice, newSafe)
        );
        pool.acceptTreasury();

        // Admin cannot accept
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(LiquidityPool.NotPendingTreasury.selector, admin, newSafe)
        );
        pool.acceptTreasury();

        // pendingTreasury CAN accept
        vm.prank(newSafe);
        pool.acceptTreasury();

        assertEq(pool.treasury(), newSafe, "rotated");
        assertEq(pool.pendingTreasury(), address(0), "pending cleared");
    }

    function test_AcceptTreasury_RevertsIfNoPending() public {
        vm.prank(newSafe);
        vm.expectRevert(LiquidityPool.NoPendingTreasury.selector);
        pool.acceptTreasury();
    }

    function test_CancelTreasuryProposal_ClearsPending() public {
        vm.prank(treasury);
        pool.proposeTreasury(newSafe);

        vm.prank(treasury);
        pool.cancelTreasuryProposal();
        assertEq(pool.pendingTreasury(), address(0), "cleared");

        // newSafe can no longer accept
        vm.prank(newSafe);
        vm.expectRevert(LiquidityPool.NoPendingTreasury.selector);
        pool.acceptTreasury();
    }

    function test_AfterRotation_OldTreasuryLosesWithdrawalRights() public {
        _accrueTreasury(200e6);

        vm.prank(treasury);
        pool.proposeTreasury(newSafe);
        vm.prank(newSafe);
        pool.acceptTreasury();

        // Old treasury is now a regular address
        vm.prank(treasury);
        vm.expectRevert(
            abi.encodeWithSelector(LiquidityPool.NotTreasury.selector, treasury, newSafe)
        );
        pool.withdrawTreasury(100e6);

        // New treasury can withdraw
        vm.prank(newSafe);
        pool.withdrawTreasury(100e6);
        assertEq(usdc.balanceOf(newSafe), 100e6, "new treasury received funds");
    }

    function test_Admin_CannotRotateTreasury() public {
        // The old admin-callable `setTreasury` is intentionally removed. The
        // only path is propose/accept gated by the current treasury.
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(LiquidityPool.NotTreasury.selector, admin, treasury)
        );
        pool.proposeTreasury(newSafe);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MAX BET AMOUNT (pool-wide cap)
    // ═══════════════════════════════════════════════════════════════════════

    function test_MaxBetAmount_EnforcedOnRecordBet() public {
        _seedPool(100_000e6);
        vm.prank(admin);
        pool.setMaxBetAmount(100e6); // 100 USDC cap

        uint256 marketId = _newMarketAtOdds(20_000);

        // 100e6 is at the cap → allowed
        _placeBet(alice, marketId, 0, 100e6);

        // 101e6 → revert
        vm.startPrank(alice);
        usdc.approve(address(footballMatch), 101e6);
        vm.expectRevert(
            abi.encodeWithSelector(LiquidityPool.BetAmountAboveCap.selector, 101e6, 100e6)
        );
        footballMatch.placeBetUSDC(marketId, 0, 101e6);
        vm.stopPrank();
    }

    function test_MaxBetAmount_ZeroDisablesCap() public {
        _seedPool(100_000e6);
        // default is 0 → disabled
        uint256 marketId = _newMarketAtOdds(20_000);
        _placeBet(alice, marketId, 0, 50_000e6); // huge bet, works
        assertEq(pool.totalLiabilities(), 50_000e6, "big bet recorded");
    }

    function test_SetMaxBetAmount_OnlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert(); // AccessControl revert
        pool.setMaxBetAmount(100e6);

        vm.prank(admin);
        pool.setMaxBetAmount(500e6);
        assertEq(pool.maxBetAmount(), 500e6);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MAX ALLOWED ODDS (per-match soft cap)
    // ═══════════════════════════════════════════════════════════════════════

    function test_MaxAllowedOdds_BlocksSettingOddsAboveCap() public {
        vm.prank(admin);
        footballMatch.setMaxAllowedOdds(20_000); // 2.00x max

        // Creating a market with 3.00x initial odds should revert
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                BettingMatch.InvalidOddsValue.selector, uint32(30_000), uint32(10_001), uint32(20_000)
            )
        );
        footballMatch.addMarketWithLine(MARKET_WINNER, 30_000, 0);
    }

    function test_MaxAllowedOdds_ZeroUsesDefaultMaxOdds() public {
        // No setMaxAllowedOdds call → falls back to MAX_ODDS = 1_000_000 (100x)
        vm.prank(admin);
        footballMatch.addMarketWithLine(MARKET_WINNER, 500_000, 0); // 50x — allowed
    }

    function test_SetMaxAllowedOdds_RejectsOutOfRange() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                BettingMatch.InvalidOddsValue.selector,
                uint32(5_000), uint32(10_001), uint32(1_000_000)
            )
        );
        footballMatch.setMaxAllowedOdds(5_000); // below MIN_ODDS

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                BettingMatch.InvalidOddsValue.selector,
                uint32(2_000_000), uint32(10_001), uint32(1_000_000)
            )
        );
        footballMatch.setMaxAllowedOdds(2_000_000); // above MAX_ODDS
    }

    // ═══════════════════════════════════════════════════════════════════════
    // UTILIZATION & MAX-WITHDRAW GATING
    // ═══════════════════════════════════════════════════════════════════════

    function test_Utilization_ZeroWhenNoLiabilities() public {
        _seedPool(10_000e6);
        assertEq(pool.utilization(), 0, "zero utilization with no open bets");
    }

    function test_Utilization_ReflectsLiabilityShare() public {
        _seedPool(10_000e6);
        uint256 marketId = _newMarketAtOdds(20_000); // 2x → netExposure = netStake
        _placeBet(alice, marketId, 0, 2_000e6);

        // liab = 2000, totalAssets = 10_000 (stake in, liability out, no accrual).
        // utilization = 2000 / 10_000 = 2000 bps = 20%.
        assertEq(pool.utilization(), 2000, "20% utilization");
    }

    function test_MaxWithdraw_CappedByFreeBalance() public {
        _seedPool(10_000e6);
        uint256 marketId = _newMarketAtOdds(50_000); // 5x → netExposure = 4×stake
        // Bet that locks big liability. netStake=2_000 at 5x → netExposure=8_000.
        // After bet: pool USDC = 12_000, totalLiabilities = 8_000.
        // LP NAV (totalAssets) = 12_000 − 8_000 = 4_000.
        _placeBet(alice, marketId, 0, 2_000e6);

        uint256 lpShareValue = pool.convertToAssets(pool.balanceOf(lp));
        assertEq(lpShareValue, 4_000e6, "LP share-value tracks NAV");

        uint256 cap = pool.maxWithdraw(lp);
        assertEq(cap, 4_000e6, "maxWithdraw = min(shareValue, freeBalance) = 4_000");

        // Attempting to withdraw above the cap reverts.
        vm.prank(lp);
        vm.expectRevert(); // OZ ERC4626: ERC4626ExceededMaxWithdraw
        pool.withdraw(4_001e6, lp, lp);

        // At-cap withdraw succeeds.
        vm.prank(lp);
        pool.withdraw(cap, lp, lp);
    }

    function test_FreeBalance_ExcludesAccruedTreasury() public {
        _seedPool(10_000e6);
        _accrueTreasury(500e6); // 1000 losing stake → 500 treasury + 500 LP

        uint256 free = pool.freeBalance();
        uint256 ta   = pool.totalAssets();
        assertEq(free, ta, "freeBalance mirrors totalAssets");
        // Pool USDC: 10_000 seed + 1_000 losing stake = 11_000.
        // accruedTreasury = 500. LP NAV = 11_000 − 500 = 10_500.
        assertEq(free, 10_500e6, "LP NAV = USDC minus accruedTreasury");
        assertEq(pool.accruedTreasury(), 500e6, "treasury = 50% of losing");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // HELPERS
    // ═══════════════════════════════════════════════════════════════════════

    function _seedPool(uint256 amount) internal {
        vm.startPrank(lp);
        usdc.approve(address(pool), amount);
        pool.deposit(amount, lp);
        vm.stopPrank();
    }

    function _newMarketAtOdds(uint32 odds) internal returns (uint256 marketId) {
        vm.prank(admin);
        footballMatch.addMarketWithLine(MARKET_WINNER, odds, 0);
        marketId = footballMatch.marketCount() - 1;
        vm.prank(admin);
        footballMatch.openMarket(marketId);
    }

    function _placeBet(address user, uint256 marketId, uint64 selection, uint256 amount) internal {
        vm.startPrank(user);
        usdc.approve(address(footballMatch), amount);
        footballMatch.placeBetUSDC(marketId, selection, amount);
        vm.stopPrank();
    }

    /// @dev Funds `accruedTreasury` to exactly `target` USDC by running one
    ///      losing bet of `2 × target` net-stake (50% share → target).
    ///      Assumes the pool is already seeded with enough LP capital; callers
    ///      that don't seed themselves should call `_seedPool(100_000e6)` first.
    function _accrueTreasury(uint256 target) internal {
        if (pool.totalSupply() == 0) _seedPool(100_000e6);
        uint256 losingStake = target * 2;
        uint256 marketId = _newMarketAtOdds(20_000);
        _placeBet(alice, marketId, 0, losingStake);
        vm.prank(admin);
        footballMatch.closeMarket(marketId);
        vm.prank(resolver);
        footballMatch.resolveMarket(marketId, 1); // alice's selection 0 loses
    }
}
