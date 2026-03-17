# Add Referral Fees to Uniswap V2 in 1 Transaction

[![Solidity](https://img.shields.io/badge/Solidity-0.5.16-informational)](https://soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FF0077)](https://getfoundry.sh/)

> Add referral fees to any DEX in 1 transaction.
> No custom contracts. No trust. Works on every chain.

---

## Why this matters

Most DEX frontends make $0 from swaps.

With UFR:
- Frontends can earn fees instantly
- No need to build custom fee logic
- Same setup works across all chains

→ Turn any frontend into a revenue-generating product.

---

## How it works
```
User swaps 1000 USDC → ETH
↓ V2 Pair extracts 0.3% fee (3 USDC)
↓ Fee sent to UFR
↓ UFR splits instantly:
   ├── 70% → Frontend earns: 2.1 USDC
   └── 30% → Protocol earns: 0.9 USDC
↓ Swap completes normally
```

No extra transactions. No custody. No trust required.

---

## Integration

One line change in your existing pair contract:
```solidity
// Set once at deploy
pair.setFeeRouter(UFR_ADDRESS);

// That's it — fees route automatically on every swap
```

Configure your split:
```solidity
// 70% to your frontend, 30% to protocol treasury
FeeSplit[] memory splits = [
    FeeSplit({ recipient: frontend,  bps: 7000 }),
    FeeSplit({ recipient: protocol,  bps: 3000 })
];
UniversalFeeRouter router = factory.deploy(splits);
```

---

## Live UFR Contracts

| Network  | Factory Address                            | Status |
|----------|--------------------------------------------|--------|
| Ethereum | `0x42dca1984a1faac1ca7f1980a78fcd96782f36e9` | ✅ Live |
| Base     | `0xe3e462c58c1fe28b6b48208c4f0900d68c9d9785` | ✅ Live |
| Optimism | `0x0b262cb79ebe8ff6602e41cf286280485407b360` | ✅ Live |
| Arbitrum | `0xe3e462c58c1fe28b6b48208c4f0900d68c9d9785` | ✅ Live |

Same fee configuration → same address on every chain.

---

## Quick Start
```bash
forge install
forge test -vvv
```

---

## Security

Built on [Universal Fee Router](https://github.com/lau90eth/universal-fee-router):
- Immutable splits — set once, never changeable
- No owner, no admin, no upgrade
- 58 tests with conservation invariants
- MIT license

---

## Want to integrate?

→ [Universal Fee Router](https://github.com/lau90eth/universal-fee-router)
→ DM [@lau90eth](https://x.com/Lau_6669)
