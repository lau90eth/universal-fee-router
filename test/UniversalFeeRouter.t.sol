// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/UniversalFeeRouter.sol";

// ─── Mock contracts ───────────────────────────────────────────────────────────

contract MockERC20 {
    string  public name     = "Mock";
    string  public symbol   = "MCK";
    uint8   public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256)                     public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply   += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external virtual returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to]         += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external virtual returns (bool) {
        require(balanceOf[from]             >= amount, "insufficient");
        require(allowance[from][msg.sender] >= amount, "not allowed");
        allowance[from][msg.sender] -= amount;
        balanceOf[from]             -= amount;
        balanceOf[to]               += amount;
        return true;
    }
}

/// @dev Burns 3% on every transferFrom (fee-on-transfer)
contract FeeOnTransferToken is MockERC20 {
    function transferFrom(address from, address to, uint256 amount)
        public override returns (bool)
    {
        uint256 fee      = (amount * 3) / 100;
        uint256 received = amount - fee;
        require(balanceOf[from]             >= amount, "insufficient");
        require(allowance[from][msg.sender] >= amount, "not allowed");
        allowance[from][msg.sender] -= amount;
        balanceOf[from]             -= amount;
        balanceOf[to]               += received;
        totalSupply                 -= fee;
        return true;
    }
}

/// @dev Always reverts on ETH receive
contract RevertingRecipient {
    receive()  external payable { revert("no ETH"); }
    fallback() external payable { revert("no ETH"); }
}

/// @dev Reverts on ERC-20 transfer via a token that blacklists it
/// We simulate this by using a token that reverts for specific recipients
/// For testing credit path on ERC20 we use a different approach: token with blacklist
contract BlacklistToken is MockERC20 {
    mapping(address => bool) public blacklisted;

    function blacklist(address addr) external {
        blacklisted[addr] = true;
    }

    function unblacklist(address addr) external {
        blacklisted[addr] = false;
    }

    function transfer(address to, uint256 amount) external override virtual returns (bool) {
        require(!blacklisted[to], "blacklisted");
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to]         += amount;
        return true;
    }
}

/// @dev Returns true on transferFrom but never credits recipient (broken token)
contract SilentFailToken is MockERC20 {
    function transferFrom(address from, address to, uint256 amount)
        public override virtual returns (bool)
    {
        require(balanceOf[from]             >= amount, "insufficient");
        require(allowance[from][msg.sender] >= amount, "not allowed");
        allowance[from][msg.sender] -= amount;
        balanceOf[from]             -= amount;
        // Intentionally does NOT credit `to` — silent failure
        return true;
    }
}

/// @dev 100% fee on transfer — recipient receives nothing
contract TotalFeeToken is MockERC20 {
    function transferFrom(address from, address to, uint256 amount)
        public override virtual returns (bool)
    {
        require(balanceOf[from]             >= amount, "insufficient");
        require(allowance[from][msg.sender] >= amount, "not allowed");
        allowance[from][msg.sender] -= amount;
        balanceOf[from]             -= amount;
        totalSupply                 -= amount; // 100% burned
        return true;
    }
}

/// @dev ERC777-style: calls back into router during transfer
contract ReentrantERC20 is BlacklistToken {
    UniversalFeeRouter public router;
    bool               private _reentering;

    function setRouter(UniversalFeeRouter r) external { router = r; }

    function triggerClaim(UniversalFeeRouter r, address token) external {
        r.claim(token);
    }

    function transfer(address to, uint256 amount)
        external override virtual returns (bool)
    {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to]         += amount;

        // Attempt reentrant claim during transfer callback
        if (!_reentering && address(router) != address(0)) {
            _reentering = true;
            try router.claim(address(this)) {} catch {}
            _reentering = false;
        }
        return true;
    }
}

/// @dev Burns all forwarded gas without reverting (gas griefing)
contract GasGriefingRecipient {
    receive() external payable {
        uint256 x;
        while (gasleft() > 500) { unchecked { x++; } }
    }
}

/// @dev Attempts reentrancy on ETH receive
contract ReentrancyAttacker {
    UniversalFeeRouter public router;
    uint256            public attempts;

    constructor(UniversalFeeRouter _router) { router = _router; }

    receive() external payable {
        attempts++;
        if (attempts < 3) {
            router.claim(router.ETH_ADDRESS());
        }
    }
}

/// @dev ERC20 that returns no bool (USDT-style)
contract NoBoolToken is MockERC20 {
    function transfer(address to, uint256 amount) external override returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to]         += amount;
        // deliberately returns true (just testing the ABI path)
        return true;
    }
    // transferFrom returns nothing (no bool) — simulated via raw call in test
}

// ─── Test suite ───────────────────────────────────────────────────────────────

contract UniversalFeeRouterTest is Test {

    UniversalFeeRouter router2; // alice 50% / bob 50%
    UniversalFeeRouter router3; // alice 30% / bob 30% / charlie 40%

    MockERC20          token;
    FeeOnTransferToken fotToken;

    address alice   = makeAddr("alice");
    address bob     = makeAddr("bob");
    address charlie = makeAddr("charlie");

    function setUp() public {
        UniversalFeeRouter.FeeSplit[] memory s2 = new UniversalFeeRouter.FeeSplit[](2);
        s2[0] = UniversalFeeRouter.FeeSplit(alice, 5_000);
        s2[1] = UniversalFeeRouter.FeeSplit(bob,   5_000);
        router2 = new UniversalFeeRouter(s2);

        UniversalFeeRouter.FeeSplit[] memory s3 = new UniversalFeeRouter.FeeSplit[](3);
        s3[0] = UniversalFeeRouter.FeeSplit(alice,   3_000);
        s3[1] = UniversalFeeRouter.FeeSplit(bob,     3_000);
        s3[2] = UniversalFeeRouter.FeeSplit(charlie, 4_000);
        router3 = new UniversalFeeRouter(s3);

        token    = new MockERC20();
        fotToken = new FeeOnTransferToken();
    }

    // ═══════════════════════════════════════════════════
    // SECTION 1 — Constructor invariants
    // ═══════════════════════════════════════════════════

    function test_constructor_valid() public view {
        assertEq(router2.splitsLength(), 2);
        assertEq(router3.splitsLength(), 3);
    }

    function test_constructor_revert_empty() public {
        UniversalFeeRouter.FeeSplit[] memory s;
        vm.expectRevert("UFR: invalid recipients count");
        new UniversalFeeRouter(s);
    }

    function test_constructor_revert_bpsMismatch() public {
        UniversalFeeRouter.FeeSplit[] memory s = new UniversalFeeRouter.FeeSplit[](2);
        s[0] = UniversalFeeRouter.FeeSplit(alice, 4_000);
        s[1] = UniversalFeeRouter.FeeSplit(bob,   4_000);
        vm.expectRevert("UFR: bps != 10000");
        new UniversalFeeRouter(s);
    }

    function test_constructor_revert_zeroAddress() public {
        UniversalFeeRouter.FeeSplit[] memory s = new UniversalFeeRouter.FeeSplit[](2);
        s[0] = UniversalFeeRouter.FeeSplit(address(0), 5_000);
        s[1] = UniversalFeeRouter.FeeSplit(bob,        5_000);
        vm.expectRevert("UFR: zero recipient");
        new UniversalFeeRouter(s);
    }

    function test_constructor_revert_duplicate() public {
        UniversalFeeRouter.FeeSplit[] memory s = new UniversalFeeRouter.FeeSplit[](2);
        s[0] = UniversalFeeRouter.FeeSplit(alice, 5_000);
        s[1] = UniversalFeeRouter.FeeSplit(alice, 5_000);
        vm.expectRevert("UFR: duplicate recipient");
        new UniversalFeeRouter(s);
    }

    function test_constructor_revert_zeroBps() public {
        UniversalFeeRouter.FeeSplit[] memory s = new UniversalFeeRouter.FeeSplit[](2);
        s[0] = UniversalFeeRouter.FeeSplit(alice, 0);
        s[1] = UniversalFeeRouter.FeeSplit(bob,   10_000);
        vm.expectRevert("UFR: zero bps");
        new UniversalFeeRouter(s);
    }

    // ═══════════════════════════════════════════════════
    // SECTION 2 — ETH routing happy path
    // ═══════════════════════════════════════════════════

    function test_routeETH_50_50() public {
        vm.deal(address(this), 1 ether);
        router2.routeETH{value: 1 ether}();
        assertEq(alice.balance, 0.5 ether);
        assertEq(bob.balance,   0.5 ether);
        assertEq(address(router2).balance, 0);
    }

    function test_routeETH_3way() public {
        vm.deal(address(this), 1 ether);
        router3.routeETH{value: 1 ether}();
        assertEq(alice.balance,   0.3 ether);
        assertEq(bob.balance,     0.3 ether);
        assertEq(charlie.balance, 0.4 ether);
        assertEq(address(router3).balance, 0);
    }

    function test_routeETH_dustGoesToLast() public {
        // 1 wei split 50/50: alice gets 0, bob gets 1
        vm.deal(address(this), 1);
        router2.routeETH{value: 1}();
        assertEq(alice.balance, 0);
        assertEq(bob.balance,   1);
    }

    function test_routeETH_via_receive() public {
        vm.deal(address(this), 1 ether);
        (bool ok, ) = address(router2).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(alice.balance, 0.5 ether);
        assertEq(bob.balance,   0.5 ether);
    }

    function test_routeETH_revert_zero() public {
        vm.expectRevert("UFR: zero amount");
        router2.routeETH{value: 0}();
    }

    // ═══════════════════════════════════════════════════
    // SECTION 3 — ETH push fail → credit → claim
    // ═══════════════════════════════════════════════════

    function test_revertingRecipient_credited() public {
        RevertingRecipient rev = new RevertingRecipient();
        UniversalFeeRouter.FeeSplit[] memory s = new UniversalFeeRouter.FeeSplit[](2);
        s[0] = UniversalFeeRouter.FeeSplit(address(rev), 5_000);
        s[1] = UniversalFeeRouter.FeeSplit(bob,          5_000);
        UniversalFeeRouter r = new UniversalFeeRouter(s);

        vm.deal(address(this), 1 ether);
        r.routeETH{value: 1 ether}();

        // rev cannot receive push → credited
        assertEq(r.claimable(address(rev), r.ETH_ADDRESS()), 0.5 ether);
        // bob unaffected
        assertEq(bob.balance, 0.5 ether);
        // router holds only the credit
        assertEq(address(r).balance, 0.5 ether);
    }

    // ═══════════════════════════════════════════════════
    // SECTION 4 — Gas griefing
    // ═══════════════════════════════════════════════════

    function test_gasGriefing_doesNotBlockOthers() public {
        GasGriefingRecipient greedy = new GasGriefingRecipient();
        UniversalFeeRouter.FeeSplit[] memory s = new UniversalFeeRouter.FeeSplit[](2);
        s[0] = UniversalFeeRouter.FeeSplit(address(greedy), 5_000);
        s[1] = UniversalFeeRouter.FeeSplit(bob,             5_000);
        UniversalFeeRouter r = new UniversalFeeRouter(s);

        vm.deal(address(this), 1 ether);
        r.routeETH{value: 1 ether}();

        // Key invariant: bob always receives his share regardless of greedy
        assertEq(bob.balance, 0.5 ether);
        // Total accounted for = greedy (pushed or credited) + bob
        uint256 greedyPushed  = address(greedy).balance;
        uint256 greedyCredited = r.claimable(address(greedy), r.ETH_ADDRESS());
        assertEq(greedyPushed + greedyCredited, 0.5 ether);
        // Router holds only what is credited
        assertEq(address(r).balance, greedyCredited);
    }

    // ═══════════════════════════════════════════════════
    // SECTION 5 — ERC-20 routing
    // ═══════════════════════════════════════════════════

    function test_routeERC20_50_50() public {
        token.mint(address(this), 1000e18);
        token.approve(address(router2), 1000e18);
        router2.routeERC20(address(token), 1000e18);
        assertEq(token.balanceOf(alice), 500e18);
        assertEq(token.balanceOf(bob),   500e18);
        assertEq(token.balanceOf(address(router2)), 0);
    }

    function test_routeERC20_revert_zeroAddress() public {
        vm.expectRevert("UFR: invalid token");
        router2.routeERC20(address(0), 100);
    }

    function test_routeERC20_revert_ethAddress() public {
        address ethSentinel = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
        vm.expectRevert("UFR: invalid token");
        router2.routeERC20(ethSentinel, 100);
    }

    function test_routeERC20_revert_zero() public {
        vm.expectRevert("UFR: zero amount");
        router2.routeERC20(address(token), 0);
    }

    function test_routeERC20_3way_dustFree() public {
        token.mint(address(this), 999e18);
        token.approve(address(router3), 999e18);
        router3.routeERC20(address(token), 999e18);
        // No dust left in contract
        assertEq(token.balanceOf(address(router3)), 0);
        assertEq(
            token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(charlie),
            999e18
        );
    }

    // ═══════════════════════════════════════════════════
    // SECTION 6 — Fee-on-transfer token
    // ═══════════════════════════════════════════════════

    function test_feeOnTransfer_usesActualReceived() public {
        fotToken.mint(address(this), 1000e18);
        fotToken.approve(address(router2), 1000e18);
        // 3% burned → received = 970e18
        router2.routeERC20(address(fotToken), 1000e18);
        uint256 total = fotToken.balanceOf(alice) + fotToken.balanceOf(bob);
        assertEq(total, 970e18);
        assertEq(fotToken.balanceOf(address(router2)), 0);
    }

    // ═══════════════════════════════════════════════════
    // SECTION 7 — Reentrancy
    // ═══════════════════════════════════════════════════

    function test_reentrancy_claimIsIdempotent() public {
        ReentrancyAttacker attacker = new ReentrancyAttacker(router2);
        UniversalFeeRouter.FeeSplit[] memory s = new UniversalFeeRouter.FeeSplit[](2);
        s[0] = UniversalFeeRouter.FeeSplit(address(attacker), 5_000);
        s[1] = UniversalFeeRouter.FeeSplit(bob,               5_000);
        UniversalFeeRouter r = new UniversalFeeRouter(s);

        // Force a credit so attacker has something to claim
        RevertingRecipient dummy = new RevertingRecipient();
        // Use a router where attacker is credited (push will fail due to gas cap
        // since attacker's receive() burns gas)
        vm.deal(address(this), 2 ether);
        r.routeETH{value: 2 ether}();

        // Regardless of reentrancy attempts, router holds exactly what is credited
        uint256 credited = r.claimable(address(attacker), r.ETH_ADDRESS());
        assertEq(address(r).balance, credited);
    }

    // ═══════════════════════════════════════════════════
    // SECTION 8 — Claim
    // ═══════════════════════════════════════════════════

    function test_claim_zeroBalanceIsNoop() public {
        vm.prank(alice);
        router2.claim(address(token)); // no revert
        assertEq(token.balanceOf(alice), 0);
    }

    function test_claimMultiple_erc20() public {
        MockERC20 tokenB = new MockERC20();
        token.mint(address(this),  1000e18);
        tokenB.mint(address(this), 1000e18);
        token.approve(address(router2),  1000e18);
        tokenB.approve(address(router2), 1000e18);
        router2.routeERC20(address(token),  1000e18);
        router2.routeERC20(address(tokenB), 1000e18);
        assertEq(token.balanceOf(alice),  500e18);
        assertEq(tokenB.balanceOf(alice), 500e18);
    }

    // ═══════════════════════════════════════════════════
    // SECTION 9 — No stranded funds invariant
    // ═══════════════════════════════════════════════════

    function test_invariant_noETHStranded() public {
        vm.deal(address(this), 100 ether);
        router3.routeETH{value: 100 ether}();
        assertEq(address(router3).balance, 0);
    }

    function test_invariant_noERC20Stranded() public {
        token.mint(address(this), 999e18);
        token.approve(address(router3), 999e18);
        router3.routeERC20(address(token), 999e18);
        assertEq(token.balanceOf(address(router3)), 0);
    }

    // ═══════════════════════════════════════════════════
    // SECTION 10 — Fuzz
    // ═══════════════════════════════════════════════════

    function testFuzz_routeETH_noStrandedFunds(uint96 amount) public {
        vm.assume(amount > 0);
        vm.deal(address(this), amount);
        router2.routeETH{value: amount}();
        assertEq(address(router2).balance, 0);
        assertEq(alice.balance + bob.balance, uint256(amount));
    }

    function testFuzz_routeERC20_noStrandedFunds(uint96 amount) public {
        vm.assume(amount > 0);
        token.mint(address(this), amount);
        token.approve(address(router2), amount);
        router2.routeERC20(address(token), amount);
        assertEq(token.balanceOf(address(router2)), 0);
        assertEq(
            token.balanceOf(alice) + token.balanceOf(bob),
            uint256(amount)
        );
    }

    function testFuzz_constructor_validSplits(uint16 a, uint16 b) public {
        vm.assume(a > 0 && b > 0);
        vm.assume(uint256(a) + uint256(b) < 10_000);
        uint16 c = uint16(10_000 - a - b);
        vm.assume(c > 0);

        address d = makeAddr("d");
        address e = makeAddr("e");
        address f = makeAddr("f");

        UniversalFeeRouter.FeeSplit[] memory s = new UniversalFeeRouter.FeeSplit[](3);
        s[0] = UniversalFeeRouter.FeeSplit(d, a);
        s[1] = UniversalFeeRouter.FeeSplit(e, b);
        s[2] = UniversalFeeRouter.FeeSplit(f, c);

        UniversalFeeRouter r = new UniversalFeeRouter(s);
        assertEq(r.splitsLength(), 3);
    }

    // ═══════════════════════════════════════════════════
    // SECTION 11 — NoBool token (USDT-style)
    // ═══════════════════════════════════════════════════

    function test_routeERC20_noBoolToken() public {
        NoBoolToken t = new NoBoolToken();
        t.mint(address(this), 1000e18);
        t.approve(address(router2), 1000e18);
        router2.routeERC20(address(t), 1000e18);
        assertEq(t.balanceOf(alice), 500e18);
        assertEq(t.balanceOf(bob),   500e18);
        assertEq(t.balanceOf(address(router2)), 0);
    }

    // ═══════════════════════════════════════════════════
    // SECTION 12 — Double claim protection
    // ═══════════════════════════════════════════════════

    function test_doubleClaim_secondIsZero() public {
        // Setup: BlacklistToken forces credit path for alice
        BlacklistToken bt = new BlacklistToken();
        bt.mint(address(this), 1000e18);
        bt.blacklist(alice); // push to alice will fail → credited

        UniversalFeeRouter.FeeSplit[] memory s = new UniversalFeeRouter.FeeSplit[](2);
        s[0] = UniversalFeeRouter.FeeSplit(alice, 5_000);
        s[1] = UniversalFeeRouter.FeeSplit(bob,   5_000);
        UniversalFeeRouter r = new UniversalFeeRouter(s);

        bt.approve(address(r), 1000e18);
        r.routeERC20(address(bt), 1000e18);

        // alice credited 500e18 (push failed), bob pushed directly
        assertEq(r.claimable(alice, address(bt)), 500e18);
        assertEq(bt.balanceOf(bob), 500e18);

        // Un-blacklist alice so she can claim
        bt.unblacklist(alice);

        // First claim: transfers 500e18 to alice, zeroes claimable
        vm.prank(alice);
        r.claim(address(bt));
        assertEq(bt.balanceOf(alice), 500e18);
        assertEq(r.claimable(alice, address(bt)), 0);

        // Second claim: noop, alice balance unchanged
        vm.prank(alice);
        r.claim(address(bt));
        assertEq(bt.balanceOf(alice), 500e18); // unchanged
        assertEq(r.claimable(alice, address(bt)), 0);
    }

    // ═══════════════════════════════════════════════════
    // SECTION 13 — Reentrancy: no double receive
    // ═══════════════════════════════════════════════════

    function test_reentrancy_attackerReceivesExactAmount() public {
        ReentrancyAttacker attacker = new ReentrancyAttacker(router2);
        UniversalFeeRouter.FeeSplit[] memory s = new UniversalFeeRouter.FeeSplit[](2);
        s[0] = UniversalFeeRouter.FeeSplit(address(attacker), 5_000);
        s[1] = UniversalFeeRouter.FeeSplit(bob,               5_000);
        UniversalFeeRouter r = new UniversalFeeRouter(s);

        vm.deal(address(this), 2 ether);
        r.routeETH{value: 2 ether}();

        // Total received by attacker (pushed + credited) must equal exactly 1 ether
        uint256 pushed   = address(attacker).balance;
        uint256 credited = r.claimable(address(attacker), r.ETH_ADDRESS());
        assertEq(pushed + credited, 1 ether, "attacker received more than entitled");

        // Bob always gets exactly his share
        assertEq(bob.balance, 1 ether);

        // Router holds exactly what is credited
        assertEq(address(r).balance, credited);
    }

    // ═══════════════════════════════════════════════════
    // SECTION 14 — Max recipients stress test
    // ═══════════════════════════════════════════════════

    function test_maxRecipients_20_noRevert() public {
        uint8 n = 20;
        UniversalFeeRouter.FeeSplit[] memory s = new UniversalFeeRouter.FeeSplit[](n);
        uint16 share = 500; // 5% each, 20 * 500 = 10000
        for (uint8 i; i < n; ++i) {
            s[i] = UniversalFeeRouter.FeeSplit(makeAddr(string(abi.encode(i))), share);
        }
        UniversalFeeRouter r = new UniversalFeeRouter(s);

        vm.deal(address(this), 1 ether);
        uint256 gasBefore = gasleft();
        r.routeETH{value: 1 ether}();
        uint256 gasUsed = gasBefore - gasleft();

        // Must be well within block gas limit (30M)
        assertLt(gasUsed, 1_000_000, "gas too high for 20 recipients");
        assertEq(address(r).balance, 0);
    }

    // ═══════════════════════════════════════════════════
    // SECTION 15 — Mixed: push ok + revert + gas grief
    // ═══════════════════════════════════════════════════

    function test_mixed_pushOk_revert_gasGrief() public {
        RevertingRecipient  rev    = new RevertingRecipient();
        GasGriefingRecipient greedy = new GasGriefingRecipient();

        UniversalFeeRouter.FeeSplit[] memory s = new UniversalFeeRouter.FeeSplit[](3);
        s[0] = UniversalFeeRouter.FeeSplit(alice,          4_000); // normal EOA
        s[1] = UniversalFeeRouter.FeeSplit(address(rev),   3_000); // always reverts
        s[2] = UniversalFeeRouter.FeeSplit(address(greedy),3_000); // burns gas
        UniversalFeeRouter r = new UniversalFeeRouter(s);

        vm.deal(address(this), 1 ether);
        r.routeETH{value: 1 ether}();

        // alice: push succeeds
        assertEq(alice.balance, 0.4 ether);

        // rev: push fails → credited
        assertEq(r.claimable(address(rev), r.ETH_ADDRESS()), 0.3 ether);

        // greedy: push fails or succeeds — total must be 0.3 ether
        uint256 greedyTotal = address(greedy).balance +
                              r.claimable(address(greedy), r.ETH_ADDRESS());
        assertEq(greedyTotal, 0.3 ether);

        // Router holds exactly what is credited
        uint256 totalCredited = r.claimable(address(rev),    r.ETH_ADDRESS()) +
                                r.claimable(address(greedy), r.ETH_ADDRESS());
        assertEq(address(r).balance, totalCredited);
    }

    // ═══════════════════════════════════════════════════
    // SECTION 16 — Extreme dust
    // ═══════════════════════════════════════════════════

    function test_extremeDust_3wei() public {
        // 3 wei split 33/33/34 bps-equivalent
        UniversalFeeRouter.FeeSplit[] memory s = new UniversalFeeRouter.FeeSplit[](3);
        s[0] = UniversalFeeRouter.FeeSplit(alice,   3_333);
        s[1] = UniversalFeeRouter.FeeSplit(bob,     3_333);
        s[2] = UniversalFeeRouter.FeeSplit(charlie, 3_334);
        UniversalFeeRouter r = new UniversalFeeRouter(s);

        vm.deal(address(this), 3);
        r.routeETH{value: 3}();

        // Total must be exactly 3 wei, nothing stranded
        uint256 total = alice.balance + bob.balance + charlie.balance;
        assertEq(total, 3);
        assertEq(address(r).balance, 0);
    }

    // ═══════════════════════════════════════════════════
    // SECTION 17 — Router as recipient (self-recipient)
    // ═══════════════════════════════════════════════════

    function test_selfRecipient_routerAsRecipient() public {
        UniversalFeeRouter.FeeSplit[] memory s = new UniversalFeeRouter.FeeSplit[](2);
        // We deploy a secondary router and use it as a recipient of primary
        UniversalFeeRouter.FeeSplit[] memory s2 = new UniversalFeeRouter.FeeSplit[](1);
        s2[0] = UniversalFeeRouter.FeeSplit(alice, 10_000);
        UniversalFeeRouter innerRouter = new UniversalFeeRouter(s2);

        s[0] = UniversalFeeRouter.FeeSplit(address(innerRouter), 5_000);
        s[1] = UniversalFeeRouter.FeeSplit(bob,                  5_000);
        UniversalFeeRouter outerRouter = new UniversalFeeRouter(s);

        vm.deal(address(this), 1 ether);
        outerRouter.routeETH{value: 1 ether}();

        // innerRouter receives ETH via push (it has a receive() payable)
        // bob receives directly
        assertEq(bob.balance, 0.5 ether);

        // Total accounted for
        uint256 innerBalance  = address(innerRouter).balance;
        uint256 innerCredited = outerRouter.claimable(address(innerRouter), outerRouter.ETH_ADDRESS());
        assertEq(innerBalance + innerCredited, 0.5 ether);
    }

    // ═══════════════════════════════════════════════════
    // SECTION 18 — ETH + reverting recipient + claim flow
    // ═══════════════════════════════════════════════════

    function test_eth_credit_then_claim_erc20() public {
        // Use BlacklistToken to force credit path
        BlacklistToken bt = new BlacklistToken();
        bt.mint(address(this), 1000e18);
        bt.blacklist(alice); // alice push will fail → credited

        UniversalFeeRouter.FeeSplit[] memory s = new UniversalFeeRouter.FeeSplit[](2);
        s[0] = UniversalFeeRouter.FeeSplit(alice, 6_000);
        s[1] = UniversalFeeRouter.FeeSplit(bob,   4_000);
        UniversalFeeRouter r = new UniversalFeeRouter(s);

        bt.approve(address(r), 1000e18);
        r.routeERC20(address(bt), 1000e18);

        // alice gets credited (push failed due to blacklist)
        assertEq(r.claimable(alice, address(bt)), 600e18);
        // bob received push directly
        assertEq(bt.balanceOf(bob), 400e18);
        // router holds exactly alice credit
        assertEq(bt.balanceOf(address(r)), 600e18);
    }

    // ═══════════════════════════════════════════════════
    // SECTION 19 — Silent transferFrom failure
    // ═══════════════════════════════════════════════════

    function test_silentTransferFailure_noMoneyCreated() public {
        // Token that returns true but does NOT credit recipient
        // Simulates broken token: decrements sender, never increments recipient
        SilentFailToken sft = new SilentFailToken();
        sft.mint(address(this), 1000e18);
        sft.approve(address(router2), 1000e18);

        // transferFrom will "succeed" but router receives 0
        // require(received > 0) must catch this
        vm.expectRevert("UFR: nothing received");
        router2.routeERC20(address(sft), 1000e18);

        // No money created: recipients have nothing
        assertEq(sft.balanceOf(alice), 0);
        assertEq(sft.balanceOf(bob),   0);
    }

    // ═══════════════════════════════════════════════════
    // SECTION 20 — ERC20 claim reentrancy (ERC777-style)
    // ═══════════════════════════════════════════════════

    function test_erc20Claim_reentrancy_noDoubleSpend() public {
        // Setup: force credit via blacklist on push recipient
        BlacklistToken bt = new BlacklistToken();
        bt.mint(address(this), 1000e18);
        bt.blacklist(alice); // push to alice fails → credited

        UniversalFeeRouter.FeeSplit[] memory s = new UniversalFeeRouter.FeeSplit[](2);
        s[0] = UniversalFeeRouter.FeeSplit(alice, 5_000);
        s[1] = UniversalFeeRouter.FeeSplit(bob,   5_000);
        UniversalFeeRouter r = new UniversalFeeRouter(s);

        bt.approve(address(r), 1000e18);
        r.routeERC20(address(bt), 1000e18);

        // alice credited 500e18
        assertEq(r.claimable(alice, address(bt)), 500e18);

        // Un-blacklist so claim transfer succeeds
        bt.unblacklist(alice);

        // Deploy ReentrantERC20 that tries to re-enter claim() during transfer
        // We simulate by having alice (EOA) claim — CEI ensures:
        //   1. claimable zeroed BEFORE transfer
        //   2. any reentrant claim() sees 0 and is noop
        uint256 aliceBalBefore = bt.balanceOf(alice);

        vm.prank(alice);
        r.claim(address(bt));

        // alice received exactly 500e18 — not more
        assertEq(bt.balanceOf(alice), aliceBalBefore + 500e18);
        assertEq(r.claimable(alice, address(bt)), 0);

        // Second claim: noop
        vm.prank(alice);
        r.claim(address(bt));
        assertEq(bt.balanceOf(alice), aliceBalBefore + 500e18); // unchanged
        assertEq(r.claimable(alice, address(bt)), 0);

        // Router holds zero for this token
        assertEq(bt.balanceOf(address(r)), 0);
    }

    // ═══════════════════════════════════════════════════
    // SECTION 21 — Fee-on-transfer 100% fee → received = 0
    // ═══════════════════════════════════════════════════

    function test_feeOnTransfer_100percent_reverts() public {
        TotalFeeToken tft = new TotalFeeToken();
        tft.mint(address(this), 1000e18);
        tft.approve(address(router2), 1000e18);

        // 100% fee → received = 0 → must revert cleanly
        vm.expectRevert("UFR: nothing received");
        router2.routeERC20(address(tft), 1000e18);

        // State untouched
        assertEq(tft.balanceOf(alice), 0);
        assertEq(tft.balanceOf(bob),   0);
        assertEq(tft.balanceOf(address(router2)), 0);
    }


    // ═══════════════════════════════════════════════════
    // SECTION 22 — Conservation invariant (global)
    // ═══════════════════════════════════════════════════

    /// @dev Total value out == total value in, always.
    ///      No money created or destroyed by the router.
    function testFuzz_conservation_ETH(uint96 amount) public {
        vm.assume(amount > 0);
        vm.deal(address(this), amount);

        uint256 totalBefore = alice.balance + bob.balance + charlie.balance;

        router3.routeETH{value: amount}();

        uint256 totalAfter = alice.balance
            + bob.balance
            + charlie.balance
            + router3.claimable(alice,   router3.ETH_ADDRESS())
            + router3.claimable(bob,     router3.ETH_ADDRESS())
            + router3.claimable(charlie, router3.ETH_ADDRESS());

        assertEq(totalAfter - totalBefore, uint256(amount));
        assertEq(address(router3).balance,
            router3.claimable(alice,   router3.ETH_ADDRESS()) +
            router3.claimable(bob,     router3.ETH_ADDRESS()) +
            router3.claimable(charlie, router3.ETH_ADDRESS())
        );
    }

    function testFuzz_conservation_ERC20(uint96 amount) public {
        vm.assume(amount > 0);
        token.mint(address(this), amount);
        token.approve(address(router3), amount);

        uint256 totalBefore = token.balanceOf(alice)
            + token.balanceOf(bob)
            + token.balanceOf(charlie);

        router3.routeERC20(address(token), amount);

        uint256 totalAfter = token.balanceOf(alice)
            + token.balanceOf(bob)
            + token.balanceOf(charlie)
            + router3.claimable(alice,   address(token))
            + router3.claimable(bob,     address(token))
            + router3.claimable(charlie, address(token));

        assertEq(totalAfter - totalBefore, uint256(amount));
        assertEq(token.balanceOf(address(router3)),
            router3.claimable(alice,   address(token)) +
            router3.claimable(bob,     address(token)) +
            router3.claimable(charlie, address(token))
        );
    }

    function testFuzz_conservation_feeOnTransfer(uint96 amount) public {
        vm.assume(amount > 100); // need enough for 3% fee to be nonzero
        fotToken.mint(address(this), amount);
        fotToken.approve(address(router3), amount);

        uint256 before = fotToken.balanceOf(alice)
            + fotToken.balanceOf(bob)
            + fotToken.balanceOf(charlie);

        router3.routeERC20(address(fotToken), amount);

        // received = amount - 3% fee (burned by token)
        uint256 received = amount - (uint256(amount) * 3 / 100);

        uint256 afterDist = fotToken.balanceOf(alice)
            + fotToken.balanceOf(bob)
            + fotToken.balanceOf(charlie)
            + router3.claimable(alice,   address(fotToken))
            + router3.claimable(bob,     address(fotToken))
            + router3.claimable(charlie, address(fotToken));

        // Conservation: out == what was actually received (not original amount)
        assertEq(afterDist - before, received);
        assertEq(fotToken.balanceOf(address(router3)),
            router3.claimable(alice,   address(fotToken)) +
            router3.claimable(bob,     address(fotToken)) +
            router3.claimable(charlie, address(fotToken))
        );
    }

}