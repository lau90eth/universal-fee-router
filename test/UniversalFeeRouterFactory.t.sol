// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/UniversalFeeRouter.sol";
import "../src/UniversalFeeRouterFactory.sol";

contract UniversalFeeRouterFactoryTest is Test {
    UniversalFeeRouterFactory factory;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");

    function setUp() public {
        factory = new UniversalFeeRouterFactory();
    }

    function _splits2() internal view returns (UniversalFeeRouter.FeeSplit[] memory s) {
        s = new UniversalFeeRouter.FeeSplit[](2);
        s[0] = UniversalFeeRouter.FeeSplit(alice, 5_000);
        s[1] = UniversalFeeRouter.FeeSplit(bob, 5_000);
    }

    function _splits3() internal view returns (UniversalFeeRouter.FeeSplit[] memory s) {
        s = new UniversalFeeRouter.FeeSplit[](3);
        s[0] = UniversalFeeRouter.FeeSplit(alice, 3_000);
        s[1] = UniversalFeeRouter.FeeSplit(bob, 3_000);
        s[2] = UniversalFeeRouter.FeeSplit(charlie, 4_000);
    }

    // ═══════════════════════════════════════════════════
    // F1 — predict == deploy address
    // ═══════════════════════════════════════════════════

    function test_predictMatchesDeploy() public {
        UniversalFeeRouter.FeeSplit[] memory s = _splits2();
        address predicted = factory.predict(s);
        (address deployed, bool fresh) = factory.deploy(s);
        assertEq(predicted, deployed);
        assertTrue(fresh);
    }

    function test_predictBeforeAndAfterDeploy() public {
        UniversalFeeRouter.FeeSplit[] memory s = _splits3();
        address pre = factory.predict(s);
        assertFalse(factory.isDeployed(s));
        (address deployed,) = factory.deploy(s);
        address post = factory.predict(s);
        assertEq(pre, deployed);
        assertEq(post, deployed);
        assertTrue(factory.isDeployed(s));
    }

    // ═══════════════════════════════════════════════════
    // F2 — deploy is idempotent
    // ═══════════════════════════════════════════════════

    function test_deployIdempotent() public {
        UniversalFeeRouter.FeeSplit[] memory s = _splits2();
        (address first, bool fresh1) = factory.deploy(s);
        (address second, bool fresh2) = factory.deploy(s);
        assertEq(first, second);
        assertTrue(fresh1);
        assertFalse(fresh2);
    }

    // ═══════════════════════════════════════════════════
    // F3 — different splits → different addresses
    // ═══════════════════════════════════════════════════

    function test_differentSplits_differentAddresses() public {
        (address r2,) = factory.deploy(_splits2());
        (address r3,) = factory.deploy(_splits3());
        assertTrue(r2 != r3);
    }

    // ═══════════════════════════════════════════════════
    // F4 — deployed router is functional
    // ═══════════════════════════════════════════════════

    function test_deployedRouter_routesETH() public {
        (address r,) = factory.deploy(_splits2());
        UniversalFeeRouter router = UniversalFeeRouter(payable(r));

        vm.deal(address(this), 1 ether);
        router.routeETH{value: 1 ether}();

        assertEq(alice.balance, 0.5 ether);
        assertEq(bob.balance, 0.5 ether);
    }

    // ═══════════════════════════════════════════════════
    // F5 — same config, different factory = different address
    //      (shows why factory address must be canonical)
    // ═══════════════════════════════════════════════════

    function test_sameConfig_differentFactory_differentAddress() public {
        UniversalFeeRouterFactory factory2 = new UniversalFeeRouterFactory();
        UniversalFeeRouter.FeeSplit[] memory s = _splits2();

        (address r1,) = factory.deploy(s);
        (address r2,) = factory2.deploy(s);

        // Same splits but different factory → different CREATE2 address
        assertTrue(r1 != r2);
    }

    // ═══════════════════════════════════════════════════
    // F6 — salt is deterministic
    // ═══════════════════════════════════════════════════

    function test_saltIsDeterministic() public view {
        UniversalFeeRouter.FeeSplit[] memory s = _splits2();
        bytes32 s1 = factory.computeSalt(s);
        bytes32 s2 = factory.computeSalt(s);
        assertEq(s1, s2);
    }

    function test_differentSplits_differentSalt() public view {
        bytes32 s1 = factory.computeSalt(_splits2());
        bytes32 s2 = factory.computeSalt(_splits3());
        assertTrue(s1 != s2);
    }

    // ═══════════════════════════════════════════════════
    // Fuzz — predict always matches deploy
    // ═══════════════════════════════════════════════════

    function testFuzz_predictMatchesDeploy(uint16 bpsA) public {
        vm.assume(bpsA > 0 && bpsA < 10_000);
        uint16 bpsB = 10_000 - bpsA;

        UniversalFeeRouter.FeeSplit[] memory s = new UniversalFeeRouter.FeeSplit[](2);
        s[0] = UniversalFeeRouter.FeeSplit(alice, bpsA);
        s[1] = UniversalFeeRouter.FeeSplit(bob, bpsB);

        address predicted = factory.predict(s);
        (address deployed,) = factory.deploy(s);
        assertEq(predicted, deployed);
    }

    // ═══════════════════════════════════════════════════
    // F7 — Canonical ordering: [A,B] == [B,A]
    // ═══════════════════════════════════════════════════

    function test_canonicalOrdering_ABequalsBA() public {
        UniversalFeeRouter.FeeSplit[] memory ab = new UniversalFeeRouter.FeeSplit[](2);
        ab[0] = UniversalFeeRouter.FeeSplit(alice, 5_000);
        ab[1] = UniversalFeeRouter.FeeSplit(bob, 5_000);

        UniversalFeeRouter.FeeSplit[] memory ba = new UniversalFeeRouter.FeeSplit[](2);
        ba[0] = UniversalFeeRouter.FeeSplit(bob, 5_000);
        ba[1] = UniversalFeeRouter.FeeSplit(alice, 5_000);

        // Same salt regardless of input order
        assertEq(factory.computeSalt(ab), factory.computeSalt(ba));

        // Same predicted address
        assertEq(factory.predict(ab), factory.predict(ba));

        // Deploy AB, predict BA → same address
        (address rAB,) = factory.deploy(ab);
        address predBA = factory.predict(ba);
        assertEq(rAB, predBA);

        // Deploy BA → returns existing (idempotent)
        (address rBA, bool fresh) = factory.deploy(ba);
        assertEq(rAB, rBA);
        assertFalse(fresh);
    }

    function test_canonicalOrdering_3way() public {
        // All 6 permutations of [alice, bob, charlie] → same address
        UniversalFeeRouter.FeeSplit[] memory s1 = new UniversalFeeRouter.FeeSplit[](3);
        s1[0] = UniversalFeeRouter.FeeSplit(alice, 3_000);
        s1[1] = UniversalFeeRouter.FeeSplit(bob, 3_000);
        s1[2] = UniversalFeeRouter.FeeSplit(charlie, 4_000);

        UniversalFeeRouter.FeeSplit[] memory s2 = new UniversalFeeRouter.FeeSplit[](3);
        s2[0] = UniversalFeeRouter.FeeSplit(charlie, 4_000);
        s2[1] = UniversalFeeRouter.FeeSplit(alice, 3_000);
        s2[2] = UniversalFeeRouter.FeeSplit(bob, 3_000);

        UniversalFeeRouter.FeeSplit[] memory s3 = new UniversalFeeRouter.FeeSplit[](3);
        s3[0] = UniversalFeeRouter.FeeSplit(bob, 3_000);
        s3[1] = UniversalFeeRouter.FeeSplit(charlie, 4_000);
        s3[2] = UniversalFeeRouter.FeeSplit(alice, 3_000);

        bytes32 salt1 = factory.computeSalt(s1);
        bytes32 salt2 = factory.computeSalt(s2);
        bytes32 salt3 = factory.computeSalt(s3);

        assertEq(salt1, salt2);
        assertEq(salt2, salt3);

        // All predict same address
        assertEq(factory.predict(s1), factory.predict(s2));
        assertEq(factory.predict(s2), factory.predict(s3));
    }

    // ═══════════════════════════════════════════════════
    // F8 — Different bps same recipients → different address
    // ═══════════════════════════════════════════════════

    function test_samePeople_differentBps_differentAddress() public {
        UniversalFeeRouter.FeeSplit[] memory s6040 = new UniversalFeeRouter.FeeSplit[](2);
        s6040[0] = UniversalFeeRouter.FeeSplit(alice, 6_000);
        s6040[1] = UniversalFeeRouter.FeeSplit(bob, 4_000);

        UniversalFeeRouter.FeeSplit[] memory s5050 = new UniversalFeeRouter.FeeSplit[](2);
        s5050[0] = UniversalFeeRouter.FeeSplit(alice, 5_000);
        s5050[1] = UniversalFeeRouter.FeeSplit(bob, 5_000);

        assertTrue(factory.computeSalt(s6040) != factory.computeSalt(s5050));
        assertTrue(factory.predict(s6040) != factory.predict(s5050));
    }

    // ═══════════════════════════════════════════════════
    // F9 — Factory-level validation
    // ═══════════════════════════════════════════════════

    function test_factory_revert_duplicateAfterSort() public {
        // [A,A] — duplicate becomes adjacent after sort
        UniversalFeeRouter.FeeSplit[] memory s = new UniversalFeeRouter.FeeSplit[](2);
        s[0] = UniversalFeeRouter.FeeSplit(alice, 5_000);
        s[1] = UniversalFeeRouter.FeeSplit(alice, 5_000);
        vm.expectRevert("UFR-F: duplicate recipient");
        factory.deploy(s);
    }

    function test_factory_revert_duplicateOutOfOrder() public {
        // [B,A,B] — after sort [A,B,B] → duplicate detected
        UniversalFeeRouter.FeeSplit[] memory s = new UniversalFeeRouter.FeeSplit[](3);
        s[0] = UniversalFeeRouter.FeeSplit(bob, 3_000);
        s[1] = UniversalFeeRouter.FeeSplit(alice, 3_000);
        s[2] = UniversalFeeRouter.FeeSplit(bob, 4_000);
        vm.expectRevert("UFR-F: duplicate recipient");
        factory.deploy(s);
    }

    function test_factory_revert_zeroBps() public {
        UniversalFeeRouter.FeeSplit[] memory s = new UniversalFeeRouter.FeeSplit[](2);
        s[0] = UniversalFeeRouter.FeeSplit(alice, 0);
        s[1] = UniversalFeeRouter.FeeSplit(bob, 10_000);
        vm.expectRevert("UFR-F: zero bps");
        factory.deploy(s);
    }

    function test_factory_predict_revert_duplicateAfterSort() public {
        UniversalFeeRouter.FeeSplit[] memory s = new UniversalFeeRouter.FeeSplit[](2);
        s[0] = UniversalFeeRouter.FeeSplit(alice, 5_000);
        s[1] = UniversalFeeRouter.FeeSplit(alice, 5_000);
        vm.expectRevert("UFR-F: duplicate recipient");
        factory.predict(s);
    }

    function test_factory_computeSalt_revert_zeroBps() public {
        UniversalFeeRouter.FeeSplit[] memory s = new UniversalFeeRouter.FeeSplit[](2);
        s[0] = UniversalFeeRouter.FeeSplit(alice, 0);
        s[1] = UniversalFeeRouter.FeeSplit(bob, 10_000);
        vm.expectRevert("UFR-F: zero bps");
        factory.computeSalt(s);
    }
}
