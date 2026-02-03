# Chiliz-TV Deployment Scripts

This directory contains deployment scripts for the Chiliz-TV smart contract system.

## Overview

Chiliz-TV uses two different proxy patterns:

### Betting System (UUPS + Factory Pattern)
- **BettingMatchFactory** deploys sport-specific match proxies
- **FootballMatch** and **BasketballMatch** are UUPS upgradeable implementations
- Each match is independently upgradeable by its admin
- Dynamic odds system with x10000 precision

### Streaming System (Beacon Proxy Pattern)
- **StreamWalletFactory** deploys BeaconProxy instances for streamers
- All streamer wallets share the same implementation via UpgradeableBeacon
- Atomic upgrades: upgrading beacon upgrades all proxies at once

## Available Scripts

| Script | Purpose | Deploys |
|--------|---------|---------|
| `DeployAll.s.sol` | Complete system | BettingMatchFactory + StreamWalletFactory |
| `DeployBetting.s.sol` | Betting only | BettingMatchFactory (with FootballMatch & BasketballMatch implementations) |
| `DeployStreaming.s.sol` | Streaming only | StreamWallet + StreamWalletFactory |
| `SetupFootballMatch.s.sol` | Create & configure a match | Football match with markets, ready for betting |

## Environment Setup

Create a `.env` file in the `chiliz-tv` directory:

```bash
# Required for deployment
PRIVATE_KEY=0x...           # Deployer private key
SAFE_ADDRESS=0x...          # Gnosis Safe multisig (treasury)

# Optional for match setup
FACTORY_ADDRESS=0x...       # BettingMatchFactory address (for SetupFootballMatch)
```

**Security Note**: Never commit your `.env` file! It's already in `.gitignore`.

## Deployment Commands

### Deploy Everything (Betting + Streaming)

```bash
forge script script/DeployAll.s.sol \
  --rpc-url https://base-sepolia.drpc.org \
  --broadcast \
  --private-key $PRIVATE_KEY \
  -vvvv
```

### Deploy Betting System Only

```bash
forge script script/DeployBetting.s.sol \
  --rpc-url https://base-sepolia.drpc.org \
  --broadcast \
  --private-key $PRIVATE_KEY \
  -vvvv
```

### Deploy Streaming System Only

```bash
forge script script/DeployStreaming.s.sol \
  --rpc-url https://base-sepolia.drpc.org \
  --broadcast \
  --private-key $PRIVATE_KEY \
  -vvvv
```

### Setup a Football Match (After Factory Deployed)

```bash
export FACTORY_ADDRESS=0x...   # Your deployed factory

forge script script/SetupFootballMatch.s.sol \
  --rpc-url https://base-sepolia.drpc.org \
  --broadcast \
  --private-key $PRIVATE_KEY \
  -vvvv
```

## Network Configurations

### Base Sepolia (Testnet)
```bash
RPC_URL=https://base-sepolia.drpc.org
# No --legacy flag needed (supports EIP-1559)
```

### Chiliz Testnet (Spicy)
```bash
RPC_URL=https://spicy-rpc.chiliz.com
CHAIN_ID=88882
# Add: --legacy --with-gas-price 2501
```

### Chiliz Mainnet
```bash
RPC_URL=https://rpc.ankr.com/chiliz
CHAIN_ID=88888
# Add: --legacy --with-gas-price 2501
```

## Post-Deployment: Betting System

### Create a Football Match

```bash
cast send $FACTORY_ADDRESS \
  "createFootballMatch(string,address)" \
  "Barcelona vs Real Madrid" \
  $OWNER_ADDRESS \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY
```

### Add a Market (Admin)

```bash
# Add WINNER market with 2.20x odds (22000 in x10000 precision)
cast send $MATCH_ADDRESS \
  "addMarket(bytes32,uint32)" \
  $(cast keccak "WINNER") \
  22000 \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY
```

### Open Market for Betting (Admin)

```bash
cast send $MATCH_ADDRESS \
  "openMarket(uint256)" \
  0 \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY
```

### Place a Bet (User)

```bash
# Bet 0.1 ETH on Home Win (market 0, selection 0)
cast send $MATCH_ADDRESS \
  "placeBet(uint256,uint64)" \
  0 0 \
  --value 0.1ether \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY
```

### Update Odds (Odds Setter)

```bash
# Change to 2.50x (new bets get new odds, existing bets keep locked odds)
cast send $MATCH_ADDRESS \
  "setMarketOdds(uint256,uint32)" \
  0 25000 \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY
```

### Resolve Market (Resolver)

```bash
# Home team won (result = 0)
cast send $MATCH_ADDRESS \
  "resolveMarket(uint256,uint64)" \
  0 0 \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY
```

### Claim Winnings (User)

```bash
cast send $MATCH_ADDRESS \
  "claim(uint256,uint256)" \
  0 0 \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY
```

## Post-Deployment: Streaming System

### Create Streamer Wallet

```bash
cast send $STREAM_FACTORY \
  "createStreamWallet(address)" \
  $STREAMER_ADDRESS \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY
```

### Subscribe to Stream

```bash
cast send $STREAM_FACTORY \
  "subscribeToStream(address)" \
  $STREAMER_ADDRESS \
  --value 10ether \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY
```

### Donate to Streamer

```bash
cast send $STREAM_FACTORY \
  "donateToStream(address)" \
  $STREAMER_ADDRESS \
  --value 1ether \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY
```

## Odds Precision Reference

| Decimal | x10000 Value | Notes |
|---------|--------------|-------|
| 1.0001x | 10001 | Minimum |
| 1.50x | 15000 | |
| 2.00x | 20000 | Even money |
| 2.18x | 21800 | Common |
| 3.50x | 35000 | |
| 10.00x | 100000 | |
| 100.00x | 1000000 | Maximum |

## Football Market Selections

| Market | Selection 0 | Selection 1 | Selection 2 |
|--------|-------------|-------------|-------------|
| WINNER | Home | Draw | Away |
| GOALS_TOTAL | Under | Over | - |
| BOTH_SCORE | No | Yes | - |
| HALFTIME | Home | Draw | Away |

## Access Control Roles

| Role | Permissions |
|------|-------------|
| `DEFAULT_ADMIN_ROLE` | Grant/revoke all roles, upgrade contract |
| `ADMIN_ROLE` | Add markets, change market state |
| `ODDS_SETTER_ROLE` | Update market odds |
| `RESOLVER_ROLE` | Resolve markets with results |
| `PAUSER_ROLE` | Pause/unpause contract |
| `TREASURY_ROLE` | Emergency fund withdrawal |

## Upgrading Contracts

### Betting System (UUPS - Per Match)

Each match can be upgraded independently by its DEFAULT_ADMIN:

```bash
# 1. Deploy new implementation
forge create src/betting/FootballMatchV2.sol:FootballMatchV2 \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY

# 2. Upgrade specific match
cast send $MATCH_ADDRESS \
  "upgradeToAndCall(address,bytes)" \
  $NEW_IMPL_ADDRESS \
  0x \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY
```

### Streaming System (Beacon - All At Once)

All streamer wallets upgrade atomically via the registry (owned by Safe multisig):

```bash
# Via Gnosis Safe UI, call:
# streamRegistry.setImplementation(newImplementationAddress)
```

## Troubleshooting

### "SAFE_ADDRESS not set" error
```bash
export SAFE_ADDRESS=0x...
```

### "Sender not authorized" on betting functions
- Check you have the required role (ADMIN_ROLE, ODDS_SETTER_ROLE, etc.)
- Grant role: `grantRole(ADMIN_ROLE, yourAddress)`

### "Market not open" when placing bet
- Open the market first: `openMarket(marketId)`

### Transaction reverts with no message
- Check market state transitions are valid
- Verify odds are within bounds (10001 - 1000000)
- Ensure bet amount is > 0

## License

MIT
