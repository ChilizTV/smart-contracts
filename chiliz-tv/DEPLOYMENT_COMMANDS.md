# ChilizTV Deployment Commands

Complete guide for deploying the ChilizTV smart contract system.

---

## Prerequisites

### 1. Set Environment Variables

Create a `.env` file (already exists) and ensure these are set:

```bash
# Deployer wallet (hot wallet with minimal funds)
PRIVATE_KEY=<your_deployer_private_key>

# Treasury/Multisig address (receives fees and ownership)
SAFE_ADDRESS=<your_gnosis_safe_address>

# RPC endpoint
RPC_URL=<network_rpc_url>

# Block explorer API key (for verification)
CHILIZ_EXPLORER_API_KEY=<your_api_key>
```

### 2. Fund Deployer Wallet

Ensure your deployer wallet has sufficient CHZ for gas:
- **Testnet**: ~1-2 CHZ (free from faucet)
- **Mainnet**: ~5-10 CHZ (for deployment + buffer)

---

## Deployment Commands

### Option 1: Deploy Complete System (Betting + Streaming)

Deploys everything in one transaction:

```bash
# Testnet (Chiliz Spicy)
wsl -e bash -c "cd /mnt/e/Helder/GitHub_Repo/smart-contracts/chiliz-tv && \
  source ~/.bashrc && \
  forge script script/DeployAll.s.sol \
    --rpc-url https://spicy-rpc.chiliz.com \
    --private-key \$PRIVATE_KEY \
    --broadcast \
    --verify \
    --verifier blockscout \
    --verifier-url https://api.routescan.io/v2/network/testnet/evm/88882/etherscan/api \
    --etherscan-api-key \$CHILIZ_EXPLORER_API_KEY \
    -vvvv"

# Mainnet (Chiliz)
wsl -e bash -c "cd /mnt/e/Helder/GitHub_Repo/smart-contracts/chiliz-tv && \
  source ~/.bashrc && \
  forge script script/DeployAll.s.sol \
    --rpc-url https://rpc.ankr.com/chiliz \
    --private-key \$PRIVATE_KEY \
    --broadcast \
    --verify \
    --verifier blockscout \
    --verifier-url https://api.routescan.io/v2/network/mainnet/evm/88888/etherscan/api \
    --etherscan-api-key \$CHILIZ_EXPLORER_API_KEY \
    -vvvv"
```

---

### Option 2: Deploy Betting System Only

```bash
# Testnet
wsl -e bash -c "cd /mnt/e/Helder/GitHub_Repo/smart-contracts/chiliz-tv && \
  source ~/.bashrc && \
  forge script script/DeployBetting.s.sol \
    --rpc-url https://spicy-rpc.chiliz.com \
    --private-key \$PRIVATE_KEY \
    --broadcast \
    --verify \
    --verifier blockscout \
    --verifier-url https://api.routescan.io/v2/network/testnet/evm/88882/etherscan/api \
    --etherscan-api-key \$CHILIZ_EXPLORER_API_KEY \
    -vvvv"
```

---

### Option 3: Deploy Streaming System Only

```bash
# Testnet
wsl -e bash -c "cd /mnt/e/Helder/GitHub_Repo/smart-contracts/chiliz-tv && \
  source ~/.bashrc && \
  forge script script/DeployStreaming.s.sol \
    --rpc-url https://spicy-rpc.chiliz.com \
    --private-key \$PRIVATE_KEY \
    --broadcast \
    --verify \
    --verifier blockscout \
    --verifier-url https://api.routescan.io/v2/network/testnet/evm/88882/etherscan/api \
    --etherscan-api-key \$CHILIZ_EXPLORER_API_KEY \
    -vvvv"

# Mainnet
wsl -e bash -c "cd /mnt/e/Helder/GitHub_Repo/smart-contracts/chiliz-tv && \
  source ~/.bashrc && \
  forge script script/DeployStreaming.s.sol \
    --rpc-url https://rpc.ankr.com/chiliz \
    --private-key \$PRIVATE_KEY \
    --broadcast \
    --verify \
    --verifier blockscout \
    --verifier-url https://api.routescan.io/v2/network/mainnet/evm/88888/etherscan/api \
    --etherscan-api-key \$CHILIZ_EXPLORER_API_KEY \
    -vvvv"
```

---

## Using .env File (Recommended)

Instead of passing variables inline, load from `.env`:

```bash
# Load environment variables first
wsl -e bash -c "cd /mnt/e/Helder/GitHub_Repo/smart-contracts/chiliz-tv && \
  export \$(cat .env | grep -v '^#' | xargs) && \
  forge script script/DeployAll.s.sol \
    --rpc-url \$RPC_URL_CHILIZ_SPICY_TESTNET \
    --private-key \$PRIVATE_KEY \
    --broadcast \
    --verify \
    --verifier blockscout \
    --verifier-url https://api.routescan.io/v2/network/testnet/evm/88882/etherscan/api \
    --etherscan-api-key \$CHILIZ_EXPLORER_API_KEY \
    -vvvv"
```

---

## Dry Run (No Broadcasting)

Test deployment without actually sending transactions:

```bash
wsl -e bash -c "cd /mnt/e/Helder/GitHub_Repo/smart-contracts/chiliz-tv && \
  source ~/.bashrc && \
  forge script script/DeployAll.s.sol \
    --rpc-url https://spicy-rpc.chiliz.com \
    -vvvv"
```

---

## Post-Deployment Steps

### 1. Save Deployed Addresses

After deployment, copy the addresses from console output:

```
DEPLOYED CONTRACTS:
------------------
FootballMatch Implementation: 0x...
BasketballMatch Implementation: 0x...
BettingMatchFactory: 0x...
StreamWallet Implementation: 0x...
StreamWalletFactory: 0x...
```

### 2. Verify Ownership Transfer

Check that factory ownership was transferred to your Safe:

```bash
# Check BettingMatchFactory owner
cast call <BETTING_FACTORY_ADDRESS> "owner()(address)" --rpc-url $RPC_URL

# Check StreamWalletFactory owner
cast call <STREAM_FACTORY_ADDRESS> "owner()(address)" --rpc-url $RPC_URL

# Should both return your SAFE_ADDRESS
```

### 3. Create First Match (Test)

```bash
# Create a football match
cast send <BETTING_FACTORY_ADDRESS> \
  "createFootballMatch(string,address)" \
  "Real Madrid vs Barcelona" \
  <MATCH_OWNER_ADDRESS> \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY
```

### 4. Create First Stream Wallet (Test)

```bash
# Deploy wallet for a streamer
cast send <STREAM_FACTORY_ADDRESS> \
  "deployWalletFor(address)" \
  <STREAMER_ADDRESS> \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY
```

---

## Troubleshooting

### Error: "SAFE_ADDRESS environment variable not set"

Set the variable before running:
```bash
export SAFE_ADDRESS=0xYourGnosisSafeAddress
```

### Error: "forge: command not found"

Forge not in PATH. Use full path:
```bash
~/.foundry/bin/forge script ...
```

### Error: "insufficient funds for gas"

Fund your deployer wallet with more CHZ.

### Verification Failed

Manually verify contracts:
```bash
forge verify-contract \
  <CONTRACT_ADDRESS> \
  src/betting/FootballMatch.sol:FootballMatch \
  --verifier blockscout \
  --verifier-url https://api.routescan.io/v2/network/testnet/evm/88882/etherscan/api \
  --compiler-version 0.8.24
```

---

## Quick Reference

| Network | Chain ID | RPC URL | Explorer |
|---------|----------|---------|----------|
| Chiliz Mainnet | 88888 | https://rpc.ankr.com/chiliz | https://chiliscan.com |
| Chiliz Spicy Testnet | 88882 | https://spicy-rpc.chiliz.com | https://testnet.chiliscan.com |

| Contract | Purpose |
|----------|---------|
| `FootballMatch` | Football betting implementation |
| `BasketballMatch` | Basketball betting implementation |
| `BettingMatchFactory` | Creates sport-specific match proxies |
| `StreamWallet` | Streamer wallet implementation |
| `StreamWalletFactory` | Creates streamer wallet proxies + owns beacon |

---

## Gas Estimates

| Operation | Estimated Gas | CHZ Cost (@30 gwei) |
|-----------|---------------|---------------------|
| Deploy Complete System | ~8M gas | ~0.24 CHZ |
| Deploy Betting Only | ~5M gas | ~0.15 CHZ |
| Deploy Streaming Only | ~3M gas | ~0.09 CHZ |
| Create Football Match | ~400K gas | ~0.012 CHZ |
| Create Stream Wallet | ~300K gas | ~0.009 CHZ |

---

**Last Updated**: December 3, 2025  
**Forge Version**: 0.3.0  
**Solidity Version**: 0.8.24
