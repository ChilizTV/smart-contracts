// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.20;

// import "forge-std/Test.sol";
// import "../src/MatchHubFactory.sol"; // adapte le chemin si besoin

// /// @dev Mock minimal d'un MatchHub compatible proxy pour les tests.
// /// - stocke un owner fixé via initialize(address)
// /// - interdit l'init multiple
// contract MockMatchHub {
//     address private _owner;
//     bool private _initialized;

//     event Initialized(address indexed owner);

//     error AlreadyInitialized();

//     function initialize(address owner_) external {
//         if (_initialized) revert AlreadyInitialized();
//         _initialized = true;
//         _owner = owner_;
//         emit Initialized(owner_);
//     }

//     function owner() external view returns (address) {
//         return _owner;
//     }
// }

// contract MatchHubFactoryTest is Test {
//     MatchHubFactory private factory;
//     MockMatchHub private impl;

//     address internal deployer = makeAddr("deployer");
//     address internal alice = makeAddr("alice");
//     address internal bob = makeAddr("bob");
//     address internal newImplAddr;

//     function setUp() public {
//         vm.startPrank(deployer);
//         impl = new MockMatchHub();
//         factory = new MatchHubFactory(address(impl));
//         vm.stopPrank();
//     }

//     /*//////////////////////////////////////////////////////////////////////////
//                                   CONSTRUCTOR
//     //////////////////////////////////////////////////////////////////////////*/

//     function test_constructor_setsImplementation() public view {
//         assertEq(factory.implementation(), address(impl), "impl addr mismatch");
//     }

//     function test_constructor_revertsOnZeroImplementation() public {
//         vm.expectRevert(MatchHubFactory.ZeroAddress.selector);
//         new MatchHubFactory(address(0));
//     }

//     /*//////////////////////////////////////////////////////////////////////////
//                                setImplementation (onlyOwner)
//     //////////////////////////////////////////////////////////////////////////*/

//     function test_setImplementation_updates_and_emits() public {
//         vm.prank(deployer);
//         MockMatchHub newImpl = new MockMatchHub();

//         vm.expectEmit(true, false, false, true);
//         emit MatchHubFactory.ImplementationUpdated(address(newImpl));

//         vm.prank(deployer);
//         factory.setImplementation(address(newImpl));

//         assertEq(factory.implementation(), address(newImpl), "impl not updated");
//     }

//     function test_setImplementation_revertsOnZeroAddress() public {
//         vm.prank(deployer);
//         vm.expectRevert(MatchHubFactory.ZeroAddress.selector);
//         factory.setImplementation(address(0));
//     }

//     function test_setImplementation_onlyOwner() public {
//         vm.prank(bob);
//         // OpenZeppelin Ownable (v5+) : OwnableUnauthorizedAccount(address)
//         vm.expectRevert(
//             abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", bob)
//         );
//         factory.setImplementation(address(impl));
//     }

//     /*//////////////////////////////////////////////////////////////////////////
//                                     createHub
//     //////////////////////////////////////////////////////////////////////////*/

//     // function test_createHub_deploysProxy_initializesOwner_emits_and_tracks() public {
//     //     // alice crée un hub
//     //     vm.prank(alice);

//     //     vm.expectEmit(true, true, true, true);
//     //     // event MatchHubCreated(address proxy, address owner)
//     //     // On ne peut pas connaître l'adresse du proxy avant, on n'asserte que l'owner (indexed)
//     //     emit MatchHubFactory.MatchHubCreated(address(0), alice);

//     //     address proxy = MatchHubFactory(factory).createHub();

//     //     // 1) Proxy enregistré
//     //     assertEq(factory.allHubs(0), proxy, "not stored at index 0");

//     //     // 2) getAllHubs retourne la même liste
//     //     address[] memory hubs = factory.getAllHubs();
//     //     assertEq(hubs.length, 1, "getAllHubs length");
//     //     assertEq(hubs[0], proxy, "getAllHubs[0] mismatch");

//     //     // 3) L'impl Mock expose owner(), on s'assure que initialize(msg.sender) a bien été appelé
//     //     //    Appels via le proxy (delegatecall)
//     //     (bool ok, bytes memory ret) = proxy.call(abi.encodeWithSignature("owner()"));
//     //     assertTrue(ok, "owner() call failed");
//     //     address recordedOwner = abi.decode(ret, (address));
//     //     assertEq(recordedOwner, alice, "owner after initialize must be alice");
//     // }

//     function test_createHub_multiple() public {
//         // Crée 3 hubs depuis des accounts différents
//         vm.prank(alice);
//         address p1 = factory.createHub();

//         vm.prank(bob);
//         address p2 = factory.createHub();

//         address charlie = makeAddr("charlie");
//         vm.prank(charlie);
//         address p3 = factory.createHub();

//         // Vérifie l'ordre et la taille
//         assertEq(factory.allHubs(0), p1);
//         assertEq(factory.allHubs(1), p2);
//         assertEq(factory.allHubs(2), p3);

//         address[] memory hubs = factory.getAllHubs();
//         assertEq(hubs.length, 3);
//         assertEq(hubs[0], p1);
//         assertEq(hubs[1], p2);
//         assertEq(hubs[2], p3);

//         // Vérifie l'owner initial pour l'un d'eux
//         (bool ok2, bytes memory ret2) = p2.call(abi.encodeWithSignature("owner()"));
//         assertTrue(ok2, "owner() call failed");
//         assertEq(abi.decode(ret2, (address)), bob, "owner of second hub must be bob");
//     }

//     /*//////////////////////////////////////////////////////////////////////////
//                                   EVENTS FORMAT
//     //////////////////////////////////////////////////////////////////////////*/

//     // function test_matchHubCreated_eventHasIndexedOwner() public {
//     //     // On vérifie la conformité d'indexation sur l'event
//     //     vm.recordLogs();
//     //     vm.prank(alice);
//     //     address proxy = factory.createHub();

//     //     Vm.Log[] memory entries = vm.getRecordedLogs();
//     //     // On récupère le dernier log et on compare le topic[2] (owner indexé)
//     //     // topics: [keccak(eventSig), proxy, owner]
//     //     bytes32 sig = keccak256("MatchHubCreated(address,address)");
//     //     bool found;
//     //     for (uint256 i = 0; i < entries.length; i++) {
//     //         if (entries[i].topics.length == 3 && entries[i].topics[0] == sig) {
//     //             // topic[2] = indexed owner (bytes32(addr))
//     //             address ownerFromTopic = address(uint160(uint256(entries[i].topics[2])));
//     //             assertEq(ownerFromTopic, alice, "indexed owner mismatch");
//     //             // le data contient 0x… ? Ici, proxy est indexed aussi => data vide
//     //             found = true;
//     //         }
//     //     }
//     //     assertTrue(found, "MatchHubCreated not found");
//     //     assertTrue(proxy != address(0), "proxy must be nonzero");
//     // }
// }
