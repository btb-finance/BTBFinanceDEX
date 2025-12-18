# BTB Finance DEX

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.27-blue.svg)](https://soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-orange.svg)](https://book.getfoundry.sh/)

> **Open Source DEX** - Free to use, fork, and build upon. We're continuously improving!

🔗 **GitHub**: https://github.com/btb-finance/BTBFinanceDEX.git

---

## 🚀 What is BTB Finance DEX?

A modern, gas-efficient decentralized exchange featuring:

- ✅ **V2 AMM Pools** - Classic x*y=k and Curve-style stableswap
- ✅ **Concentrated Liquidity (CL)** - Uniswap V3-style tick-based pools
- ✅ **Vote-Escrowed Governance** - Lock BTB → veBTB → Vote on emissions
- ✅ **Gauge Voting System** - Direct emissions to your favorite pools
- ✅ **UUPS Upgradeable** - Future-proof architecture

---

## 📦 Contracts

| Category | Contract | Description |
|----------|----------|-------------|
| **Token** | `BTB.sol` | ERC20 + Votes + Permit, 1B max supply |
| **Core V2** | `Pool.sol` | Volatile & stable AMM curves |
| **Core V2** | `PoolFactory.sol` | CREATE2 pool deployment |
| **Core CL** | `CLPool.sol` | Concentrated liquidity pools |
| **Core CL** | `CLFactory.sol` | CL pool deployment |
| **Governance** | `VotingEscrow.sol` | veBTB NFT with time-weighted voting |
| **Governance** | `Voter.sol` | Gauge creation & voting |
| **Governance** | `Minter.sol` | Weekly emissions with decay |
| **Governance** | `RewardsDistributor.sol` | veBTB rebases |
| **Gauges** | `Gauge.sol` | LP staking rewards |
| **Periphery** | `Router.sol` | V2 swaps & liquidity |
| **Periphery** | `CLRouter.sol` | CL swaps |

---

## 🏗️ Quick Start

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Node.js 18+

### Installation

```bash
# Clone the repo
git clone https://github.com/btb-finance/BTBFinanceDEX.git
cd BTBFinanceDEX

# Install dependencies
forge install

# Build
forge build

# Test
forge test
```

### Run Tests

```bash
# Run all tests
forge test

# Run with verbosity
forge test -vvv

# Run specific test
forge test --match-test test_createLock
```

---

## 🚀 Deployment

1. Create `.env` file:

```bash
RPC_URL=https://your-rpc-url
PRIVATE_KEY=0x...
WETH_ADDRESS=0x...
```

2. Deploy:

```bash
source .env
forge script script/Deploy.s.sol:DeployBTBFinance --rpc-url $RPC_URL --broadcast
```

See [DEPLOYMENT.md](./DEPLOYMENT.md) for detailed instructions.

---

## 🔥 Why BTB Finance?

### vs Other DEXs

| Feature | Others | BTB Finance |
|---------|--------|-------------|
| Solidity Version | 0.8.13-0.8.19 | **0.8.27** |
| Gas Costs | Higher | **~20% Lower** |
| Upgradeable | ❌ | ✅ UUPS |
| veBTB Split/Merge | ❌ | ✅ |
| Gasless Approvals | Limited | ✅ ERC20Permit |
| CL + V2 Pools | Separate | ✅ Unified |

### Gas Savings

- **Swaps**: ~20% cheaper
- **Add Liquidity**: ~20% cheaper  
- **Create Lock**: ~25% cheaper
- **Vote**: ~22% cheaper

---

## 📁 Project Structure

```
BTBFinanceDEX/
├── src/
│   ├── token/           # BTB token
│   ├── core/            # Pool, PoolFactory, CLPool, CLFactory
│   ├── governance/      # VotingEscrow, Voter, Minter, RewardsDistributor
│   ├── gauges/          # Gauge contracts
│   ├── periphery/       # Router, CLRouter
│   ├── interfaces/      # All interfaces
│   └── libraries/       # Math, TickMath, FullMath, LiquidityMath
├── test/                # Foundry tests
├── script/              # Deployment scripts
└── foundry.toml         # Foundry config
```

---

## 🤝 Contributing

We welcome contributions! This is open source software.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing`)
5. Open a Pull Request

---

## 📜 License

This project is licensed under the **MIT License** - see the [LICENSE](./LICENSE) file for details.

**Free to use** for any purpose - commercial or personal.

---

## 🔗 Links

- **GitHub**: https://github.com/btb-finance/BTBFinanceDEX
- **Website**: https://btb.finance (coming soon)
- **Docs**: Coming soon

---

## ⚠️ Disclaimer

This software is provided "as is" without warranty of any kind. Use at your own risk. Always audit smart contracts before deploying to production.

---

**Built with ❤️ by BTB Finance**

*We're continuously improving this DEX. Star the repo to stay updated!*
