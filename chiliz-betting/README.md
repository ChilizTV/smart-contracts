# Chiliz Betting (Foundry)

A suite of upgradeable, UUPS-based sports-betting smart-contracts on Chiliz (Spicy Testnet or local fork), developed and tested with [Foundry](https://book.getfoundry.sh/).

---

## 📋 Overview

- **`SportsBet.sol`**  
  UUPS-upgradeable logic contract for a sports bet (ETH staking, odds, resolution, payout).

- **`SportsBetFactory.sol`**  
  `Ownable` factory that deploys new ERC-1967 proxies pointing at `SportsBet` and calls its `initialize(...)`.

- **`MyChzSwapper.sol`**  
  Router contract to call our token swap from FanX (ex-Kayen please update documentation <3)

- **`Tests`**  
  Forge tests validating betting flow, resolution, and payouts.

---

## ⚙️ Prerequisites

- [Foundry](https://book.getfoundry.sh/) (`forge`, `cast`) v0.7+  
- `lib/openzeppelin-contracts` and `lib/openzeppelin-contracts-upgradeable` via:
  ```bash
  forge install OpenZeppelin/openzeppelin-contracts
  forge install OpenZeppelin/openzeppelin-contracts-upgradeable
  ```
Environment variable PRIVATE_KEY with your deployer key

(Optional) CHILIZSCAN_API_KEY for on-chain verification via ChilizScan

📁 Project Structure

.
├── foundry.toml
├── src
│   ├── SportsBet.sol
│   ├── SportsBetFactory.sol
│   └── MockWrappedChz.sol
├── script
│   └── DeploySportsBet.s.sol
└── test
    ├── SportsBet.t.sol
    └── Factory.t.sol
## 🔨 Installation & Build

 ```bash
git clone <repo-url>
cd chiliz-betting
forge install
forge build
```

## ✅ Tests & Coverage
Run tests
 ```bash
forge test --match-path test/*.t.sol -vvv
```

Generate coverage
```bash
forge coverage --report debug
```

## 🚀 Deployment to Chiliz Spicy Testnet

### Deploy SportsBet implementation
```bash
forge create src/SportsBet.sol:SportsBet \
  --rpc-url https://spicy-rpc.chiliz.com \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --chain chiliz \
  -vvvv
```
Note the returned implementation address IMPL_ADDR. But it's better to do it from SportsBetFactory.sol

### Deploy the factory

```bash
forge create src/SportsBetFactory.sol:SportsBetFactory \
  --rpc-url https://spicy-rpc.chiliz.com \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --chain chiliz \
  --constructor-args $IMPL_ADDR \
  -vvvv
  ```
Note the factory address FACTORY_ADDR.

(Optional) Verify sources on ChilizScan
In foundry.toml:

```toml
[etherscan]
api_key = { chiliz = "${CHILIZSCAN_API_KEY}" }
endpoint = { chiliz = "https://api-testnet.chilizscan.com/api" }
```
Then add --verify --chain chiliz to your forge create commands.

## 📦 Usage
Create a new upgradeable bet
```bash
cast send \
  --rpc-url https://spicy-rpc.chiliz.com \
  --private-key $PRIVATE_KEY \
  $FACTORY_ADDR \
  "createSportsBet(uint256,string,uint256,uint256,uint256)" \
  42 "TeamA vs TeamB" 150 200 180
  ```
  
42 = eventId

"TeamA vs TeamB" = eventName

150, 200, 180 = odds ×100


This deploys and initializes a new proxy, assigns you as owner, and adds it to allBets.

### List all deployed bets

```bash
cast call \
  --rpc-url https://spicy-rpc.chiliz.com \
  $FACTORY_ADDR \
  "getAllBets()"
```

### 🔄 Upgrades with UUPS
Upgrade an existing proxy (in console or script):

```bash
SportsBet(proxyAddress).upgradeTo(newImplAddress);
Update factory implementation for future deployments:


cast send \
  $FACTORY_ADDR \
  "setImplementation(address)" $NEW_IMPL_ADDR \
  --rpc-url https://spicy-rpc.chiliz.com \
  --private-key $PRIVATE_KEY

  ```