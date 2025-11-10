# Chiliz-TV Deployment Scripts

This directory contains comprehensive deployment scripts for the Chiliz-TV smart contract system.

## Overview

Chiliz-TV uses the **Beacon Proxy Pattern** for upgradeability. This means:
- **Implementation contracts** contain the logic
- **Registry contracts** manage upgradeable beacons
- **Factory contracts** deploy proxy instances
- **Beacon proxies** delegate calls to implementations via beacons

### Treasury Address
**Important**: The official ChilizTV treasury address is:
```
0x74E2653e4e0Adf2cb9a56C879d4C28ad0294D677
```

This is the address that receives platform fees. It's different from the deployer address because Foundry doesn't support multisig deployment directly.

## Available Scripts

### 1. `DeployAll.s.sol` - Complete System Deployment
Deploys both the betting system and streaming system in one script.

**Deploys:**
- FootballBetting & UFCBetting implementations
- StreamWallet implementation
- SportBeaconRegistry (for betting)
- StreamBeaconRegistry (for streaming)
- MatchHubBeaconFactory (creates betting matches)
- StreamWalletFactory (creates streamer wallets)

**Use when:** Setting up the entire platform from scratch.

### 2. `DeployStreaming.s.sol` - Streaming System Only
Focused deployment for the streaming/subscription system.

**Deploys:**
- StreamWallet implementation
- StreamBeaconRegistry
- StreamWalletFactory

**Use when:** Only deploying the streaming features or adding streaming to existing betting deployment.

### 3. `DeployBetting.s.sol` - Betting System Only
Focused deployment for the sports betting system.

**Deploys:**
- FootballBetting & UFCBetting implementations
- SportBeaconRegistry
- MatchHubBeaconFactory

**Use when:** Only deploying the betting features or adding betting to existing streaming deployment.

## Beacon Proxy Pattern Explained

### Architecture

```
┌─────────────────────────────────────────────────────────┐
│                   Gnosis Safe (Owner)                   │
└────────────────────────┬────────────────────────────────┘
                         │ owns
                         ▼
              ┌──────────────────────┐
              │  Registry Contract   │ ◄── Manages beacons
              │  (SportBeaconRegistry│     Creates/upgrades
              │   or StreamBeacon    │     implementations
              │   Registry)          │
              └──────────┬───────────┘
                         │ creates & manages
                         ▼
              ┌──────────────────────┐
              │ UpgradeableBeacon    │ ◄── Points to impl
              │                      │     Can be upgraded
              └──────────┬───────────┘
                         │ points to
                         ▼
              ┌──────────────────────┐
              │  Implementation      │ ◄── Logic contract
              │  (FootballBetting,   │     Never called
              │   UFCBetting, or     │     directly
              │   StreamWallet)      │
              └──────────────────────┘
                         ▲
                         │ delegatecall
                         │
              ┌──────────┴───────────┐
              │   BeaconProxy        │ ◄── Deployed by
              │   (per match or      │     factory for
              │    per streamer)     │     each instance
              └──────────────────────┘
                         ▲
                         │ deployed by
                         │
              ┌──────────┴───────────┐
              │  Factory Contract    │ ◄── Owned by
              │  (MatchHubBeacon     │     deployer/backend
              │   Factory or Stream  │     Can only create
              │   WalletFactory)     │     Cannot upgrade
              └──────────────────────┘
```

### Key Benefits

1. **Atomic Upgrades**: Upgrading the beacon upgrades ALL proxies at once
2. **Security**: Only Safe multisig can upgrade implementations
3. **Gas Efficiency**: All proxies share the same implementation
4. **Isolation**: Each proxy has its own storage
5. **Flexibility**: Different sports can be upgraded independently

## Prerequisites

1. **Foundry** installed: https://book.getfoundry.sh/getting-started/installation
2. **Environment variables** configured (see below)
3. **Gnosis Safe** deployed on target network
4. **RPC endpoint** for target network

## Environment Setup

Create a `.env` file in the `chiliz-tv` directory:

```bash
# Required
PRIVATE_KEY=0x...                                           # Deployer private key
RPC_URL=https://...                                         # Network RPC endpoint
SAFE_ADDRESS=0x...                                          # Gnosis Safe multisig address

# Optional
TOKEN_ADDRESS=0x...                                         # ERC20 token address (if not set, deploys mock)
```

**Security Note**: Never commit your `.env` file! It's already in `.gitignore`.

## Deployment Steps

### Step 1: Load Environment
```bash
cd chiliz-tv
source .env
```

### Step 2: Choose Deployment Script

#### Option A: Deploy Everything
```bash
forge script script/DeployAll.s.sol \
  --rpc-url $RPC_URL \
  --broadcast \
  --verify
```

#### Option B: Deploy Streaming Only
```bash
forge script script/DeployStreaming.s.sol \
  --rpc-url $RPC_URL \
  --broadcast \
  --verify
```

#### Option C: Deploy Betting Only
```bash
forge script script/DeployBetting.s.sol \
  --rpc-url $RPC_URL \
  --broadcast \
  --verify
```

### Step 3: Verify Deployment

The script will output all deployed addresses. Save these for future reference!

Example output:
```
DEPLOYED CONTRACTS:
------------------
StreamWallet Implementation: 0x...
StreamBeaconRegistry: 0x...
  Owner: 0x... (Safe)
  Beacon: 0x...
StreamWalletFactory: 0x...
  Owner: 0x... (Deployer)
```

## Post-Deployment

### For Streaming System

1. **Test subscription flow:**
```bash
# Approve tokens
cast send $TOKEN_ADDRESS \
  "approve(address,uint256)" \
  $FACTORY_ADDRESS \
  1000000000000000000

# Subscribe to a stream
cast send $FACTORY_ADDRESS \
  "subscribeToStream(address,uint256,uint256)" \
  $STREAMER_ADDRESS \
  1000000000000000000 \
  2592000  # 30 days in seconds
```

2. **Check wallet was created:**
```bash
cast call $FACTORY_ADDRESS \
  "getWallet(address)(address)" \
  $STREAMER_ADDRESS
```

### For Betting System

1. **Create a football match:**
```bash
cast send $FACTORY_ADDRESS \
  "createFootballMatch(address,address,bytes32,uint64,uint16,address)" \
  $OWNER_ADDRESS \
  $TOKEN_ADDRESS \
  0x$(echo -n "MATCH_001" | xxd -p) \
  $(($(date +%s) + 86400)) \
  500 \
  0x74E2653e4e0Adf2cb9a56C879d4C28ad0294D677
```

2. **Place a bet:**
```bash
# Approve tokens
cast send $TOKEN_ADDRESS \
  "approve(address,uint256)" \
  $MATCH_PROXY_ADDRESS \
  1000000000000000000

# Bet on home team
cast send $MATCH_PROXY_ADDRESS \
  "betHome(uint256)" \
  1000000000000000000
```

## Upgrading Implementations

**IMPORTANT**: Only the Gnosis Safe can upgrade implementations!

### Upgrade Streaming System

1. Deploy new StreamWallet implementation:
```bash
forge create src/streamer/StreamWallet.sol:StreamWallet \
  --rpc-url $RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --verify
```

2. Via Gnosis Safe UI, call:
```solidity
streamRegistry.setImplementation(newImplementationAddress)
```

3. All existing streamer wallets now use the new implementation!

### Upgrade Betting System

#### Upgrade Football
1. Deploy new FootballBetting implementation
2. Via Safe: `sportRegistry.setSportImplementation(keccak256("FOOTBALL"), newImpl)`
3. All football matches upgraded!

#### Upgrade UFC
1. Deploy new UFCBetting implementation
2. Via Safe: `sportRegistry.setSportImplementation(keccak256("UFC"), newImpl)`
3. All UFC matches upgraded!

## Adding New Sports

1. Create new implementation contract:
```solidity
// src/betting/BasketballBetting.sol
contract BasketballBetting is MatchBettingBase {
    // Your custom basketball betting logic
}
```

2. Deploy implementation:
```bash
forge create src/betting/BasketballBetting.sol:BasketballBetting \
  --rpc-url $RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --verify
```

3. Add to registry (via Safe):
```solidity
bytes32 SPORT_BASKETBALL = keccak256("BASKETBALL");
sportRegistry.setSportImplementation(SPORT_BASKETBALL, basketballImpl);
```

4. Update factory with new creation function:
```solidity
function createBasketballMatch(...) external onlyOwner returns (address) {
    address beacon = registry.getBeacon(keccak256("BASKETBALL"));
    // ... deploy proxy
}
```

## Troubleshooting

### "SAFE_ADDRESS not set" error
- Make sure `.env` file exists with `SAFE_ADDRESS=0x...`
- Run `source .env` to load environment variables

### "Beacon not set" error when creating matches/wallets
- Registry might not be configured yet
- Run the configuration step: `registry.setImplementation(impl)`

### Transactions failing
- Check gas price and limits
- Verify deployer has enough native tokens
- Check token approvals are sufficient

### Verification failing
- Add `--etherscan-api-key $ETHERSCAN_API_KEY` to forge commands
- Some networks require different verifiers (use `--verifier blockscout`)

## Security Considerations

1. **Registry Ownership**: MUST be transferred to Gnosis Safe
2. **Factory Ownership**: Can remain with deployer (only creates, doesn't upgrade)
3. **Private Keys**: Never commit or share private keys
4. **Multisig**: Use at least 2-of-3 or 3-of-5 Safe for production
5. **Testing**: Always test on testnet before mainnet deployment
6. **Audits**: Have implementations audited before upgrading in production

## Network-Specific Notes

### Chiliz Chain
- RPC: https://rpc.chiliz.com
- Chain ID: 88888
- Block Explorer: https://scan.chiliz.com

### Chiliz Testnet (Spicy)
- RPC: https://spicy-rpc.chiliz.com
- Chain ID: 88882
- Block Explorer: https://spicy-explorer.chiliz.com
- Faucet: https://spicy-faucet.chiliz.com

## Questions?

For questions or issues:
1. Check the inline comments in the deployment scripts
2. Review the architecture diagram above
3. Read the smart contract documentation in `/docs`
4. Open an issue on GitHub

## License

MIT
