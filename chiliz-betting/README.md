# Chiliz Betting (Foundry)

Une suite de smart-contracts upgradeables pour créer des paris sportifs tokenisés sur le réseau Chiliz (testnet/local), développée et testée avec [Foundry](https://github.com/foundry-rs/foundry).

---

## 📝 Aperçu

- **SportsBet.sol** — logique de pari UUPS-upgradeable
- **SportsBetFactory.sol** — factory ERC-1967 pour déployer des clones de SportsBet
- **MockWrappedChz.sol** — mock ERC-20 “Wrapped CHZ” pour les tests
- **Tests** — harness Foundry pour valider les flows de pari, résolution, et paiement

---

## ⚙️ Prérequis

- **Foundry** (forge, cast) v0.7+  
- **Git**  
- **lib/openzeppelin-contracts** et **lib/openzeppelin-contracts-upgradeable** installés via `forge install`  
- **Rust** toolchain pour forge (si utilisé)  

---

## 📁 Structure du projet

├── foundry.toml
├── src
│ ├── SportsBet.sol
│ ├── SportsBetFactory.sol
│ └── MockWrappedChz.sol
└── test
├── SportsBet.t.sol
└── Factory.t.sol


## 🚀 Installation et build

git clone <repo-url>
cd chiliz-betting
forge install 

## ✅ Tests 

```bash
forge test --match-path test/*.t.sol -vvv
```
Coverage :
```bash
forge coverage --report debug > debug.log
```
## 📦 Déploiement (local / testnet)

Déployer la logique SportsBet :
```bash
forge create src/SportsBet.sol:SportsBet \
  --rpc-url <RPC_URL> \
  --private-key $PK \
  --broadcast

```
Récupérez l’adresse de l’implémentation (IMPL).

Déployer la factory :

```bash
forge create src/SportsBetFactory.sol:SportsBetFactory \
  --rpc-url <RPC_URL> \
  --private-key $PK \
  --broadcast \
  --constructor-args $IMPL
```
Créer un pari via la factory :

```bash
cast send \
  --rpc-url <RPC_URL> \
  --private-key $PK \
  <FACTORY_ADDR> \
  "createSportsBet(uint256,string,uint256,uint256,uint256)" \
  42 "TeamA vs TeamB" 150 200 180
```
 ## 🔧 Utilisation en tests
Dans vos scripts/tests Forge :

```solidity
// déployer le mock WCHZ
MockWrappedChz wChz = new MockWrappedChz("Wrapped CHZ", "WCHZ");
wChz.mint(USER, 1_000 * 1e18);

// deploy SportsBet logic & factory, set le token
SportsBet bet = SportsBet(payable(factory.createSportsBet(...)));
bet.setToken(address(wChz));

// simulate user approve + pari
vm.prank(USER);
wChz.approve(address(bet), 1e21);
bet.placeBet(SportsBet.Outcome.Home, 100 * 1e18);

```