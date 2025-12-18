# BTB Finance DEX Deployment

## Prerequisites

1. Install Foundry: https://book.getfoundry.sh/getting-started/installation
2. Set environment variables

## Environment Setup

Create a `.env` file:

```bash
# Network RPC
RPC_URL=https://your-rpc-url

# Deployer private key
PRIVATE_KEY=0x...

# WETH address for the target chain
WETH_ADDRESS=0x...

# Optional: Etherscan API key for verification
ETHERSCAN_API_KEY=...
```

## Deployment Commands

### Deploy All Contracts

```bash
# Load environment
source .env

# Dry run (simulation)
forge script script/Deploy.s.sol:DeployBTBFinance --rpc-url $RPC_URL -vvvv

# Deploy to mainnet
forge script script/Deploy.s.sol:DeployBTBFinance --rpc-url $RPC_URL --broadcast --verify -vvvv
```

### Verify Contracts (if not auto-verified)

```bash
forge verify-contract <CONTRACT_ADDRESS> src/token/BTB.sol:BTB --chain-id <CHAIN_ID> --etherscan-api-key $ETHERSCAN_API_KEY
```

## Post-Deployment Steps

1. **Create Initial Gauges**: Call `voter.createGauge(poolAddress)` for each pool
2. **Nudge Minter**: Call `minter.nudge()` then `minter.updatePeriod()`
3. **Transfer Ownership**: Transfer team roles to multisig

## Contract Addresses

After deployment, the script will output all contract addresses. Save them for frontend configuration.

## Network-Specific WETH Addresses

| Network | WETH Address |
|---------|--------------|
| Ethereum | 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 |
| Arbitrum | 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1 |
| Base | 0x4200000000000000000000000000000000000006 |
| Optimism | 0x4200000000000000000000000000000000000006 |
| Polygon | 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270 |
| SEI | <YOUR_WSEI_ADDRESS> |
