# Arbitrum Foundation Grant Application
## Universal Fee Router — Multichain Track

**Project:** Universal Fee Router  
**Track:** Multichain Track ($20,000 - $60,000)  
**Applicant:** lau90eth  
**GitHub:** https://github.com/lau90eth/universal-fee-router  
**Stage:** Live on mainnet (Ethereum, Base, Optimism, Arbitrum)  

---

## Project Description

Universal Fee Router (UFR) is an immutable, trustless primitive for
programmable onchain fee distribution.

It solves the universal DeFi problem: how to split protocol fees between
multiple recipients (LPs, frontend devs, treasuries, referrers) without
writing custom logic, without governance, without trust.

**One contract. One line of integration. Any recipients. Any chain.**

---

## Problem Statement

Every DeFi protocol on Arbitrum that collects fees faces the same challenge:
distributing those fees to multiple parties. Today this requires:

1. Custom Solidity logic per protocol
2. Separate audits for each implementation
3. Different edge case handling across protocols
4. No composability between implementations

This is solved infrastructure — yet every team rebuilds it.

---

## Solution

UFR provides a single, auditable, composable primitive:
```solidity
// Integrate in 3 lines
IERC20(token).approve(address(router), feeAmount);
router.routeERC20(token, feeAmount);
// Done — fees split automatically to all recipients
```

**Key properties:**
- Immutable splits — set at deploy, never changeable
- No owner — zero privileged roles
- Hybrid push/pull — direct transfer first, credited on failure
- Fee-on-transfer safe — balance delta accounting
- Conservation guaranteed — total_out == total_received (fuzz verified)

**CREATE2 Factory:**
Same fee configuration → same address on every chain.
This transforms fee configs into addressable onchain objects.
Protocols on Arbitrum can use the same router address as on Ethereum.

---

## Traction

- Deployed and verified on 4 chains: Ethereum, Base, Optimism, Arbitrum
- 58 tests with full conservation invariants
- Formal specification (SPEC.md)
- MIT license

---

## Arbitrum Integration

UFR is already live on Arbitrum One:
`0xe3e462c58c1fe28b6b48208c4f0900d68c9d9785`

Target integrations on Arbitrum:
- GMX ecosystem (fee distribution to stakers/treasury)
- Camelot DEX forks (LP/protocol fee split)
- Uniswap v4 hook builders on Arbitrum
- NFT marketplaces (royalty splitting)

---

## Milestones

**Milestone 1 — Audit ($20,000)**
- Complete security audit via Cantina competitive audit
- Address all findings
- Publish audit report

**Milestone 2 — SDK + Integrations ($20,000)**
- TypeScript SDK published on npm
- 3+ documented integrations on Arbitrum
- Dune dashboard tracking volume

**Milestone 3 — Ecosystem Growth ($20,000)**
- 10+ integrations across Arbitrum ecosystem
- Canonical registry of common fee configurations
- Developer documentation and integration guides

---

## Budget Breakdown

| Milestone | Deliverable | Amount |
|-----------|------------|--------|
| 1 | Security audit | $20,000 |
| 2 | SDK + 3 integrations | $20,000 |
| 3 | Ecosystem growth | $20,000 |
| **Total** | | **$60,000** |

---

## Team

Solo developer with background in:
- Smart contract security research (Cantina, Immunefi bug bounty)
- Production Solidity development
- Open source infrastructure

---

## Links

- GitHub: https://github.com/lau90eth/universal-fee-router
- Arbitrum deploy: https://arbiscan.io/address/0xe3e462c58c1fe28b6b48208c4f0900d68c9d9785
- Spec: https://github.com/lau90eth/universal-fee-router/blob/main/SPEC.md
