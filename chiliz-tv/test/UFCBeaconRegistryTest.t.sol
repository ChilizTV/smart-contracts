// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/MatchHubBeaconFactory.sol"; // adapte le chemin si besoin
import "../src/SportBeaconRegistry.sol"; // adapte le chemin si besoin
import "../src/betting/UFCBetting.sol";
import "../src/MockERC20.sol";

contract UFCBeaconRegistryTest is Test {

    SportBeaconRegistry public registry;
    MatchHubBeaconFactory public factory;

    UFCBetting public ufcImpl;

    bytes32 public constant SPORT_UFC = keccak256("UFC");

    address admin = makeAddr("ADMIN");
    address treasury = makeAddr("TREASURY");
    address public user1 = makeAddr("USER1");
    address public user2 = makeAddr("USER2");

    MockERC20 public token;

    function setUp() public {
        vm.startPrank(admin);
        // deploy registry and implementation, register beacon and deploy factory
        registry = new SportBeaconRegistry(admin);

        ufcImpl = new UFCBetting();
        registry.setSportImplementation(SPORT_UFC, address(ufcImpl));

        factory = new MatchHubBeaconFactory(admin, address(registry));

        token = new MockERC20();

        vm.stopPrank();
    }

    function testCreateUFCMatch() public {
        vm.startPrank(admin);

        bytes32 matchId = keccak256(abi.encodePacked("UFC_MATCH_1"));
        uint64 cutoff = uint64(block.timestamp + 1 days);
        uint16 feeBps = 300; // 3%
        bool allowDraw = true;

        address proxy = factory.createUFCMatch(
            admin,
            address(token),
            matchId,
            cutoff,
            feeBps,
            treasury,
            allowDraw
        );

        assertTrue(proxy != address(0), "proxy should be non-zero");
        assertTrue(address(proxy).code.length > 0, "proxy must have code");

        // check ADMIN_ROLE granted
        bytes32 ADMIN_ROLE = ufcImpl.ADMIN_ROLE();
        assertTrue(UFCBetting(payable(proxy)).hasRole(ADMIN_ROLE, admin), "proxy admin must be admin");

        // check treasury set
        assertEq(UFCBetting(payable(proxy)).treasury(), treasury, "proxy treasury must be treasury safe");

        address beacon = registry.getBeacon(SPORT_UFC);
        assertTrue(beacon != address(0), "ufc beacon must be set");

        vm.stopPrank();
    }

    function _createUFCMatch(
        address owner_,
        bytes32 matchId_,
        uint64 cutoffTs_,
        uint16 feeBps_,
        address treasury_,
        bool allowDraw_
    ) internal returns (address proxy, UFCBetting fb) {
        proxy = factory.createUFCMatch(owner_, address(token), matchId_, cutoffTs_, feeBps_, treasury_, allowDraw_);
        fb = UFCBetting(payable(proxy));
    }
}
