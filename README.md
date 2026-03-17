# Universal Fee Router

> **Onchain revenue sharing primitive.**
> Immutable · Trustless · Zero-fee · EVM-native

[![Tests](https://github.com/lau90eth/universal-fee-router/actions/workflows/test.yml/badge.svg)](https://github.com/lau90eth/universal-fee-router/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

---

## The problem

Every DeFi protocol reinvents the same wheel: split fees between LPs, frontend devs, treasuries, referrers. There is no standard. Every team writes custom logic, introduces bugs, and ships something non-composable.

## The solution

One immutable contract. One line of integration. Infinite recipients.
```solidity
// Deploy once per fee configuration
UniversalFeeRouter router = new UniversalFeeRouter([
    FeeSplit(lpTreasury,   7000),  // 70%
    FeeSplit(frontendDev,  2000),  // 20%
    FeeSplit(protocol,     1000)   // 10%
]);

// Route ERC-20 fees
IERC20(token).approve(address(router), amount);
router.routeERC20(token, amount);

// Or ETH
router.routeETH{value: amount}();
```

That's it. Recipients receive funds instantly. No governance. No admin. No upgrades. Forever.

---

## Why it works

| Property | Mechanism |
|---|---|
| **Immutable splits** | Set once in constructor, never changeable |
| **No owner** | Zero privileged roles post-deploy |
| **Hybrid push/pull** | Direct transfer attempted first; credited on failure |
| **Recipient isolation** | A reverting recipient never blocks others |
| **Dust-free** | Last recipient absorbs rounding remainder |
| **Fee-on-transfer safe** | Balance delta accounting, not caller-supplied amount |
| **Gas griefing resistant** | Bounded gas stipend per push |

---

## CREATE2 Factory

Same fee configuration → same address on every chain.
```solidity
UniversalFeeRouterFactory factory = UniversalFeeRouterFactory(FACTORY_ADDRESS);

// Predict address before deploying
address predicted = factory.predict(splits);

// Deploy or return existing (idempotent)
(address router, bool fresh) = factory.deploy(splits);

// [A, B] and [B, A] → same address (canonical ordering)
```

This transforms fee configs into **addressable onchain objects** — like Uniswap pool addresses, but for revenue sharing.

### Canonical splits

| Config | Address |
|--------|---------|
| 70% / 20% / 10% | *coming soon* |
| 50% / 50% | *coming soon* |
| 100% treasury | *coming soon* |

---

## Deployments

| Network | Factory | Status |
|---------|---------|--------|
| Ethereum mainnet | [`0x42dca1984a1faac1ca7f1980a78fcd96782f36e9`](https://etherscan.io/address/0x42dca1984a1faac1ca7f1980a78fcd96782f36e9) | ✅ Live |
| Base | [`0xe3e462c58c1fe28b6b48208c4f0900d68c9d9785`](https://basescan.org/address/0xe3e462c58c1fe28b6b48208c4f0900d68c9d9785) | ✅ Live |
| Optimism | [`0x0b262cb79ebe8ff6602e41cf286280485407b360`](https://optimistic.etherscan.io/address/0x0b262cb79ebe8ff6602e41cf286280485407b360) | ✅ Live |
| Arbitrum One | [`0xe3e462c58c1fe28b6b48208c4f0900d68c9d9785`](https://arbiscan.io/address/0xe3e462c58c1fe28b6b48208c4f0900d68c9d9785) | ✅ Live |

---

## Token compatibility

| Token type | Supported |
|-----------|-----------|
| Standard ERC-20 | ✅ |
| No-bool (USDT, USDC) | ✅ |
| Fee-on-transfer | ✅ |
| 100% fee (received = 0) | ✅ reverts cleanly |
| Silent fail | ✅ reverts cleanly |
| Blacklist/revert on receive | ✅ credited to claimable |
| Native ETH | ✅ |

---

## Security

- **58 tests** covering all token behaviors, attack vectors, and conservation invariants
- **Fuzz testing** with 10,000 runs per property
- **Conservation invariant**: `total_out == total_received` — no money created or destroyed
- **Formal specification**: [SPEC.md](SPEC.md)

### Audit status

> ⚠️ **Not yet audited.** Use at your own risk until audit is complete.

---

## Integration

### As a dependency
```bash
forge install lau90eth/universal-fee-router
```
```solidity
import "universal-fee-router/src/UniversalFeeRouter.sol";
import "universal-fee-router/src/UniversalFeeRouterFactory.sol";
```

### Interface
```solidity
// Route
function routeETH() external payable;
function routeERC20(address token, uint256 amount) external;

// Claim (pull fallback for failed pushes)
function claim(address token) external;
function claimMultiple(address[] calldata tokens) external;

// Views
function getSplits() external view returns (FeeSplit[] memory);
function getClaimable(address recipient, address token) external view returns (uint256);
```

---

## Development
```bash
# Install
git clone https://github.com/lau90eth/universal-fee-router
cd universal-fee-router
forge install

# Test
forge test -vvv

# Fuzz (50k runs)
forge test --profile ci

# Coverage
forge coverage
```

---

## License

MIT — use it, fork it, build on it.

*If you integrate UFR, open a PR to add your protocol to the deployments table.*
