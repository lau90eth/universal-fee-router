# Universal Fee Router — Specification v1

> **Status:** Draft · **Version:** 1.0.0 · **Author:** lau90

---

## 1. Overview

The Universal Fee Router (UFR) is an immutable, trustless primitive for
programmable onchain fee distribution.

It solves one problem with zero assumptions:

> Given a set of recipients and basis-point shares fixed at deploy time,
> route any amount of ETH or ERC-20 tokens to those recipients atomically,
> without custody, without governance, and without trust.

**Positioning:** Onchain revenue sharing primitive.
Not a router. Not a product. Infrastructure.

---

## 2. Invariants

These properties hold at every external call boundary and are enforced
by the test suite (see `test/UniversalFeeRouter.t.sol`).

| ID  | Invariant | Enforcement |
|-----|-----------|-------------|
| I1  | `Σ splits[i].bps == 10_000` | Constructor revert |
| I2  | `splits.length ∈ [1, MAX_RECIPIENTS]` | Constructor revert |
| I3  | No recipient is `address(0)` | Constructor revert |
| I4  | No duplicate recipients | Constructor revert |
| I5  | `claimable[r][t] == 0` after successful claim | CEI in `_claim` |
| I6  | `contract.balance == Σ claimable[r][t]` | Accounting identity |
| I7  | `total_out == total_received` (conservation) | Fuzz: SECTION 22 |
| I8  | A failing recipient never blocks others | Push isolation |

---

## 3. Execution Model

### 3.1 Route
```
Caller → routeETH() / routeERC20()
           │
           ▼
      _distribute(token, received)
           │
           ├─ for each recipient i:
           │     share_i = amount * bps_i / 10_000
           │     last recipient gets remainder (dust-free)
           │
           ├─ _tryPush(token, recipient, share)
           │     ├─ success → FeePushed event
           │     └─ failure → claimable[r][t] += share → FeeCredited event
           │
           └─ emit FeeRouted
```

### 3.2 Claim (pull fallback)
```
Recipient → claim(token)
              │
              ▼
         amount = claimable[msg.sender][token]
         claimable[msg.sender][token] = 0      ← Effects (CEI)
         transfer(recipient, amount)            ← Interactions
         emit Claimed
```

### 3.3 Gas bounds

| Operation | Recipients | Approx gas |
|-----------|-----------|------------|
| routeETH  | 1         | ~30k       |
| routeETH  | 10        | ~180k      |
| routeETH  | 20        | ~350k      |
| routeERC20| 1         | ~60k       |
| routeERC20| 20        | ~500k      |

Execution cost grows **linearly** with recipient count.
Recommended maximum: **N = 20** (enforced by `MAX_RECIPIENTS`).

---

## 4. Token Assumptions

The router is designed to work correctly with the following token behaviors:

| Token type | Behavior | Handled |
|-----------|----------|---------|
| Standard ERC-20 | Returns bool, credits recipient | ✅ |
| No-bool (USDT-style) | Returns nothing | ✅ via `data.length == 0` check |
| Fee-on-transfer | Burns % on transfer | ✅ via balance delta accounting |
| Deflationary (100% fee) | Received = 0 | ✅ reverts with `UFR: nothing received` |
| Silent fail | Returns true, transfers nothing | ✅ reverts with `UFR: nothing received` |
| Blacklist/revert on transfer | Push fails | ✅ credited to claimable |
| ERC-777 / callback | Reenters during transfer | ✅ CEI prevents double-spend |
| Rebasing | Balance changes post-transfer | ⚠️ Not in scope for v1 |
| Upgradeable proxy tokens | Behavior may change | ⚠️ Caller responsibility |

---

## 5. Failure Modes

### 5.1 Push failure → Pull credit
If a push fails (recipient reverts, burns gas, or token transfer fails),
the share is credited to `claimable[recipient][token]`.
The recipient can claim at any time via `claim(token)`.

### 5.2 Below MIN_CREDIT threshold
Shares below `MIN_CREDIT = 1000 wei/units` are absorbed silently on
push failure and are not written to storage.
This prevents storage-bloat DoS via micro-amount spam.

### 5.3 Forced ETH via selfdestruct
ETH sent directly via `selfdestruct(router_address)` bypasses `receive()`
and is NOT routed to recipients. It accumulates as untracked balance.
**This is not a vulnerability** — it is a known EVM limitation.
Integrators should not rely on the router's ETH balance for accounting;
use events (`FeeRouted`, `FeePushed`, `FeeCredited`) instead.

### 5.4 Immutability
Splits are immutable. To change recipient configuration, deploy a new
router instance. Old routers remain functional; pending `claimable`
balances are never locked.

---

## 6. Security Considerations

### 6.1 Reentrancy
The Checks-Effects-Interactions pattern is strictly followed throughout.
`claimable` is zeroed before any external call in `_claim()`.
ETH push uses `ETH_PUSH_GAS = 5_000` gas cap (prevents full reentrancy).
ERC-20 push uses `ERC20_PUSH_GAS = 50_000` gas cap (covers standard tokens).

### 6.2 Gas griefing
Each push is bounded by a fixed gas stipend.
A griefing recipient consumes at most `ETH_PUSH_GAS` or `ERC20_PUSH_GAS`
before the call returns, and their share is credited for pull.
Maximum loop iterations are bounded by `MAX_RECIPIENTS = 20`.

### 6.3 No privileged roles
The contract has no owner, no admin, no upgrade proxy.
Post-deploy behavior is fully determined by constructor arguments.

### 6.4 Integer arithmetic
All arithmetic is performed under Solidity ^0.8 checked semantics.
Overflow is impossible. Dust is handled by last-recipient remainder.

### 6.5 Fee-on-transfer accounting
Received amount is always computed as `balanceAfter - balanceBefore`,
never from the caller-supplied `amount` parameter.
This prevents accounting errors with deflationary or taxed tokens.

---

## 7. Constants Reference

| Constant | Value | Rationale |
|----------|-------|-----------|
| `BPS_DENOMINATOR` | 10,000 | 1 bps = 0.01% |
| `MAX_RECIPIENTS` | 20 | Anti gas-DoS; linear cost |
| `ETH_PUSH_GAS` | 5,000 | Enough for EOA; prevents reentrancy |
| `ERC20_PUSH_GAS` | 50,000 | Covers USDT/USDC/standard tokens |
| `MIN_CREDIT` | 1,000 | Anti storage-bloat threshold |
| `ETH_ADDRESS` | `0xEeee...EEeE` | Convention from WETH/1inch |

---

## 8. Events
```solidity
event FeeRouted   (address indexed token, uint256 totalAmount);
event FeePushed   (address indexed recipient, address indexed token, uint256 amount);
event FeeCredited (address indexed recipient, address indexed token, uint256 amount);
event Claimed     (address indexed recipient, address indexed token, uint256 amount);
```

Use `FeeRouted` for total volume tracking (Dune Analytics).
Use `FeePushed` + `FeeCredited` for per-recipient accounting.
Use `Claimed` for pull-model tracking.

---

## 9. Integration Guide

### Minimal integration (3 lines)
```solidity
// 1. Deploy once per fee configuration
UniversalFeeRouter router = new UniversalFeeRouter([
    FeeSplit(lpTreasury,   7000),  // 70%
    FeeSplit(frontendDev,  2000),  // 20%
    FeeSplit(protocol,     1000)   // 10%
]);

// 2. In your fee-collecting function
IERC20(feeToken).approve(address(router), feeAmount);
router.routeERC20(feeToken, feeAmount);

// 3. Or for ETH
router.routeETH{value: feeAmount}();
```

### Deployment (CREATE2 — same splits → same address)
```bash
# Coming in v1.1: CREATE2 factory for deterministic addresses
# Same FeeSplit[] config → same router address across all chains
```

---

## 10. Audit Scope

**In scope:**
- `src/UniversalFeeRouter.sol`
- All invariants listed in Section 2
- All token types listed in Section 4

**Out of scope:**
- Integrating contracts
- Upgradeable token behavior
- Forced ETH via selfdestruct (documented, not a bug)

---

*This specification is the canonical reference for UFR v1.*
*The test suite in `test/UniversalFeeRouter.t.sol` is the executable proof.*
