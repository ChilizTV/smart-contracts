// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {BettingMatchFactory} from "../src/betting/BettingMatchFactory.sol";
import {FootballMatch} from "../src/betting/FootballMatch.sol";
import {BasketballMatch} from "../src/betting/BasketballMatch.sol";

/**
 * @title BettingMatchFactoryTest
 * @notice Tests for BettingMatchFactory — covers M-03 (mutable implementations) fix
 *
 * Coverage:
 *   1. Initial state: implementations deployed in constructor
 *   2. setFootballImplementation updates address and emits event
 *   3. setFootballImplementation reverts on zero address
 *   4. setBasketballImplementation updates address and emits event
 *   5. setBasketballImplementation reverts on zero address
 *   6. Non-owner cannot update implementations
 *   7. createFootballMatch registers proxy in isMatch registry
 *   8. createBasketballMatch registers proxy in isMatch registry
 *   9. New proxy uses updated implementation (ERC1967 slot verified)
 *  10. getSportType reverts for unknown match address
 */
contract BettingMatchFactoryTest is Test {
    BettingMatchFactory public factory;

    address public matchOwner = address(0x10);
    address public nonOwner   = address(0x99);

    // ══════════════════════════════════════════════════════════════════════════
    // SETUP
    // ══════════════════════════════════════════════════════════════════════════

    function setUp() public {
        factory = new BettingMatchFactory();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Initial state
    // ══════════════════════════════════════════════════════════════════════════

    function test_InitialImplementationsSet() public view {
        assertTrue(factory.footballImplementation() != address(0));
        assertTrue(factory.basketballImplementation() != address(0));
        assertEq(factory.getAllMatches().length, 0);
        assertEq(factory.owner(), address(this));
    }

    // ══════════════════════════════════════════════════════════════════════════
    // M-03: setFootballImplementation
    // ══════════════════════════════════════════════════════════════════════════

    function test_M03_SetFootballImplementation_UpdatesAndEmits() public {
        address oldImpl = factory.footballImplementation();
        address newImpl = address(new FootballMatch());

        vm.expectEmit(true, true, false, false);
        emit BettingMatchFactory.FootballImplementationUpdated(oldImpl, newImpl);

        factory.setFootballImplementation(newImpl);
        assertEq(factory.footballImplementation(), newImpl);
    }

    function test_M03_SetFootballImplementation_ZeroReverts() public {
        vm.expectRevert(BettingMatchFactory.InvalidAddress.selector);
        factory.setFootballImplementation(address(0));
    }

    function test_M03_NonOwner_CannotSetFootballImpl() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        factory.setFootballImplementation(address(0x1));
    }

    // ══════════════════════════════════════════════════════════════════════════
    // M-03: setBasketballImplementation
    // ══════════════════════════════════════════════════════════════════════════

    function test_M03_SetBasketballImplementation_UpdatesAndEmits() public {
        address oldImpl = factory.basketballImplementation();
        address newImpl = address(new BasketballMatch());

        vm.expectEmit(true, true, false, false);
        emit BettingMatchFactory.BasketballImplementationUpdated(oldImpl, newImpl);

        factory.setBasketballImplementation(newImpl);
        assertEq(factory.basketballImplementation(), newImpl);
    }

    function test_M03_SetBasketballImplementation_ZeroReverts() public {
        vm.expectRevert(BettingMatchFactory.InvalidAddress.selector);
        factory.setBasketballImplementation(address(0));
    }

    function test_M03_NonOwner_CannotSetBasketballImpl() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        factory.setBasketballImplementation(address(0x1));
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Match creation and registry
    // ══════════════════════════════════════════════════════════════════════════

    function test_CreateFootballMatch_Registered() public {
        address proxy = factory.createFootballMatch("Test Match", matchOwner);

        assertTrue(factory.isMatch(proxy));
        assertEq(
            uint8(factory.matchSportType(proxy)),
            uint8(BettingMatchFactory.SportType.FOOTBALL)
        );
        assertEq(factory.getAllMatches().length, 1);
        assertEq(factory.getAllMatches()[0], proxy);
    }

    function test_CreateBasketballMatch_Registered() public {
        address proxy = factory.createBasketballMatch("Test Match", matchOwner);

        assertTrue(factory.isMatch(proxy));
        assertEq(
            uint8(factory.matchSportType(proxy)),
            uint8(BettingMatchFactory.SportType.BASKETBALL)
        );
    }

    function test_MultipleMatches_AllRegistered() public {
        address fb1 = factory.createFootballMatch("FB1", matchOwner);
        address fb2 = factory.createFootballMatch("FB2", matchOwner);
        address bb1 = factory.createBasketballMatch("BB1", matchOwner);

        assertEq(factory.getAllMatches().length, 3);
        assertTrue(factory.isMatch(fb1));
        assertTrue(factory.isMatch(fb2));
        assertTrue(factory.isMatch(bb1));
        assertFalse(factory.isMatch(address(0xDEAD)));
    }

    // ══════════════════════════════════════════════════════════════════════════
    // M-03: New proxy respects updated implementation
    // ══════════════════════════════════════════════════════════════════════════

    function test_M03_NewMatchUsesUpdatedImplementation() public {
        address newImpl = address(new FootballMatch());
        factory.setFootballImplementation(newImpl);

        address proxy = factory.createFootballMatch("New Match", matchOwner);
        assertTrue(factory.isMatch(proxy));

        // Verify the proxy's ERC1967 implementation slot points to newImpl
        bytes32 implSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        address storedImpl = address(uint160(uint256(vm.load(proxy, implSlot))));
        assertEq(storedImpl, newImpl);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // getSportType
    // ══════════════════════════════════════════════════════════════════════════

    function test_GetSportType_Football() public {
        address proxy = factory.createFootballMatch("Match", matchOwner);
        assertEq(
            uint8(factory.getSportType(proxy)),
            uint8(BettingMatchFactory.SportType.FOOTBALL)
        );
    }

    function test_GetSportType_Basketball() public {
        address proxy = factory.createBasketballMatch("Match", matchOwner);
        assertEq(
            uint8(factory.getSportType(proxy)),
            uint8(BettingMatchFactory.SportType.BASKETBALL)
        );
    }

    function test_GetSportType_UnknownMatch_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(
            BettingMatchFactory.MatchNotFound.selector,
            address(0xDEAD)
        ));
        factory.getSportType(address(0xDEAD));
    }
}
