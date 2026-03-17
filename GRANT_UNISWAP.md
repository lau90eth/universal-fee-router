# Uniswap Foundation Grant Application
## Universal Fee Router (UFR)

**Applicant:** lau90eth  
**GitHub:** https://github.com/lau90eth/universal-fee-router  
**Contact:** netwsolutionap@gmail.com  
**Grant type:** Infrastructure / Developer Tooling  
**Requested amount:** $15,000 - $25,000  

---

## Summary

Universal Fee Router is an immutable, trustless primitive for onchain fee
distribution. It solves a problem every Uniswap v4 hook builder faces: how
to split fees between LPs, frontend devs, treasuries, and referrers without
writing custom logic every time.

One deploy. One line of integration. Any number of recipients.

---

## Problem

Every hook builder reinvents the same wheel.

Flaunch splits fees between creators and buybacks.
Zora splits fees between creators and protocol.
Clanker splits fees between protocol and MEV module.
Bunni splits fees between LPs and lending vaults.

Each team writes custom fee distribution logic. Each implementation has
different edge cases, different security assumptions, different bugs.

There is no standard.

---

## Solution

Universal Fee Router is the missing standard.
```solidity
// Deploy once per fee configuration
UniversalFeeRouter router = new UniversalFeeRouter([
    FeeSplit(lpTreasury,   7000),  // 70%
    FeeSplit(frontendDev,  2000),  // 20%
    FeeSplit(protocol,     1000)   // 10%
]);

// In your hook — route fees in one line
router.routeERC20(feeToken, feeAmount);
```

The CREATE2 factory guarantees that identical fee configurations produce
the same address on every chain. Fee configs become addressable onchain
objects — like Uniswap pool addresses, but for revenue sharing.

---

## What we built

- **UniversalFeeRouter.sol** — immutable, trustless fee splitting contract
- **UniversalFeeRouterFactory.sol** — CREATE2 factory for deterministic addresses
- **58 tests** covering all token behaviors, attack vectors, conservation invariants
- **Formal specification** (SPEC.md) with invariants, failure modes, security analysis
- **Fuzz testing** with 10,000 runs per property

Security properties:
- Zero owner, zero governance, zero upgrade surface
- Hybrid push/pull: direct transfer attempted first, credited on failure
- Conservation invariant: total_out == total_received (verified by fuzz)
- Gas griefing resistant: bounded gas stipend per push
- Fee-on-transfer safe: balance delta accounting

---

## Deployments

| Network | Factory |
|---------|---------|
| Ethereum | 0x42dca1984a1faac1ca7f1980a78fcd96782f36e9 |
| Base | 0xe3e462c58c1fe28b6b48208c4f0900d68c9d9785 |
| Optimism | 0x0b262cb79ebe8ff6602e41cf286280485407b360 |
| Arbitrum | 0xe3e462c58c1fe28b6b48208c4f0900d68c9d9785 |

All contracts verified on respective block explorers.

---

## Why this matters for Uniswap v4

Uniswap v4 has 150+ hooks deployed. Every hook that collects fees needs
fee distribution logic. Today each team builds this from scratch.

UFR gives hook builders:
- A battle-tested, audited primitive to drop in
- Deterministic addresses (same config = same address cross-chain)
- Zero trust assumptions post-deploy

This directly reduces:
- Time to market for hook builders
- Audit surface per hook
- Bugs in fee distribution logic across the ecosystem

---

## Use of funds

| Item | Amount |
|------|--------|
| Security audit (Cantina/Sherlock) | $15,000 |
| SDK development (TypeScript) | $5,000 |
| Documentation + integration guides | $3,000 |
| Canonical registry deployment + maintenance | $2,000 |
| **Total** | **$25,000** |

---

## Milestones

**Milestone 1 (Month 1):** Security audit complete, findings addressed  
**Milestone 2 (Month 2):** TypeScript SDK published (npm), 3+ integrations  
**Milestone 3 (Month 3):** Canonical registry live, Dune dashboard, 10+ integrations  

---

## Why us

- Solo developer, security researcher background (Cantina, Immunefi)
- Shipped production-ready code with formal spec before asking for funding
- MIT license — no strings attached, ecosystem owns the standard

---

## Links

- GitHub: https://github.com/lau90eth/universal-fee-router
- Spec: https://github.com/lau90eth/universal-fee-router/blob/main/SPEC.md
- Ethereum: https://etherscan.io/address/0x42dca1984a1faac1ca7f1980a78fcd96782f36e9
