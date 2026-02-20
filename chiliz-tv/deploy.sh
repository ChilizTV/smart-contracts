#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# ChilizTV Deployment Script (Chiliz-only)
# ═══════════════════════════════════════════════════════════════════════════════
#
# Usage:
#   ./deploy.sh --network chilizTestnet --all
#   ./deploy.sh --network chilizTestnet --match
#   ./deploy.sh --network chilizTestnet --stream
#   ./deploy.sh --network chilizTestnet --swap
#   ./deploy.sh --network chilizMainnet --all
#
# FUTURE WORK: Base chain support (postponed — not included here)
# ═══════════════════════════════════════════════════════════════════════════════

set -e

# ── Colors ────────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── Parse arguments ──────────────────────────────────────────────────────────
NETWORK=""
DEPLOY_TYPE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --network)
            NETWORK="$2"; shift 2 ;;
        --all)
            DEPLOY_TYPE="all"; shift ;;
        --match)
            DEPLOY_TYPE="match"; shift ;;
        --stream)
            DEPLOY_TYPE="stream"; shift ;;
        --swap)
            DEPLOY_TYPE="swap"; shift ;;
        *)
            echo -e "${RED}Unknown argument: $1${NC}"
            echo "Usage: ./deploy.sh --network <chilizTestnet|chilizMainnet> <--all|--match|--stream|--swap>"
            exit 1 ;;
    esac
done

if [ -z "$NETWORK" ] || [ -z "$DEPLOY_TYPE" ]; then
    echo -e "${RED}Missing required arguments.${NC}"
    echo "Usage: ./deploy.sh --network <chilizTestnet|chilizMainnet> <--all|--match|--stream|--swap>"
    exit 1
fi

# ── Load .env ─────────────────────────────────────────────────────────────────
if [ -f .env ]; then
    export $(cat .env | grep -v '^#' | xargs)
else
    echo -e "${RED}Error: .env file not found${NC}"
    exit 1
fi

# ── Validate common env vars ─────────────────────────────────────────────────
if [ -z "$PRIVATE_KEY" ]; then
    echo -e "${RED}Error: PRIVATE_KEY not set in .env${NC}"
    exit 1
fi
if [ -z "$SAFE_ADDRESS" ]; then
    echo -e "${RED}Error: SAFE_ADDRESS not set in .env${NC}"
    exit 1
fi

# ── Load config from config/<network>.json ────────────────────────────────────
CONFIG_FILE="config/${NETWORK}.json"
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Error: Config file not found: $CONFIG_FILE${NC}"
    echo "Create it first. See config/chilizTestnet.json for reference."
    exit 1
fi

# Parse config JSON (requires jq)
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: 'jq' is required but not installed.${NC}"
    echo "Install: sudo apt install jq (Linux) / brew install jq (Mac) / choco install jq (Windows)"
    exit 1
fi

CHAIN_ID=$(jq -r '.chainId' "$CONFIG_FILE")
RPC_URL=$(jq -r '.rpcUrl' "$CONFIG_FILE")
EXPLORER_URL=$(jq -r '.explorerUrl' "$CONFIG_FILE")
VERIFIER_URL=$(jq -r '.verifierUrl' "$CONFIG_FILE")
CFG_KAYEN_ROUTER=$(jq -r '.kayenMasterRouter // empty' "$CONFIG_FILE")
CFG_WCHZ=$(jq -r '.wchz // empty' "$CONFIG_FILE")
CFG_USDC=$(jq -r '.usdc // empty' "$CONFIG_FILE")
FORGE_FLAGS=$(jq -r '.forgeFlags // empty' "$CONFIG_FILE")

# ── Deploy type → script mapping ─────────────────────────────────────────────
REQUIRES_KAYEN=false
case "$DEPLOY_TYPE" in
    all)
        SCRIPT="script/DeployAll.s.sol" ;;
    match)
        SCRIPT="script/DeployBetting.s.sol" ;;
    stream)
        SCRIPT="script/DeployStreaming.s.sol" ;;
    swap)
        SCRIPT="script/DeploySwap.s.sol"
        REQUIRES_KAYEN=true ;;
esac

# ── Swap-specific: resolve addresses (env overrides config) ──────────────────
if [ "$REQUIRES_KAYEN" = true ]; then
    echo -e "${CYAN}Swap deployment — resolving Kayen DEX addresses...${NC}"

    # Env vars override config file
    KAYEN_ROUTER="${KAYEN_ROUTER:-$CFG_KAYEN_ROUTER}"
    WCHZ_ADDRESS="${WCHZ_ADDRESS:-$CFG_WCHZ}"
    USDC_ADDRESS="${USDC_ADDRESS:-$CFG_USDC}"

    MISSING=""
    [ -z "$KAYEN_ROUTER" ] && MISSING="${MISSING}\n  - KAYEN_ROUTER (set in .env or config/${NETWORK}.json)"
    [ -z "$WCHZ_ADDRESS" ] && MISSING="${MISSING}\n  - WCHZ_ADDRESS (set in .env or config/${NETWORK}.json)"
    [ -z "$USDC_ADDRESS" ] && MISSING="${MISSING}\n  - USDC_ADDRESS (set in .env or config/${NETWORK}.json)"

    if [ -n "$MISSING" ]; then
        echo -e "${RED}Missing required swap addresses:${MISSING}${NC}"
        exit 1
    fi

    # Export for forge script
    export KAYEN_ROUTER WCHZ_ADDRESS USDC_ADDRESS

    echo -e "  KAYEN_ROUTER: ${YELLOW}$KAYEN_ROUTER${NC}"
    echo -e "  WCHZ_ADDRESS: ${YELLOW}$WCHZ_ADDRESS${NC}"
    echo -e "  USDC_ADDRESS: ${YELLOW}$USDC_ADDRESS${NC}"
    echo ""
fi

# ── Mainnet safety warning ───────────────────────────────────────────────────
if [ "$NETWORK" = "chilizMainnet" ]; then
    echo -e "${RED}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║        ⚠  MAINNET DEPLOYMENT WARNING  ⚠     ║${NC}"
    echo -e "${RED}║  Real funds are at risk. Double-check:       ║${NC}"
    echo -e "${RED}║  - All contract addresses are correct        ║${NC}"
    echo -e "${RED}║  - Ownership will transfer to Safe multisig  ║${NC}"
    echo -e "${RED}║  - Contracts are tested on testnet first     ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════╝${NC}"
    echo ""
fi

# ── Display summary ──────────────────────────────────────────────────────────
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}ChilizTV Deployment${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "Network:      ${YELLOW}$NETWORK${NC} (Chain ID: $CHAIN_ID)"
echo -e "Deploy Type:  ${YELLOW}$DEPLOY_TYPE${NC}"
echo -e "Script:       ${YELLOW}$SCRIPT${NC}"
echo -e "RPC URL:      ${YELLOW}$RPC_URL${NC}"
echo -e "Safe Address: ${YELLOW}$SAFE_ADDRESS${NC}"
echo -e "Config:       ${YELLOW}$CONFIG_FILE${NC}"
[ -n "$FORGE_FLAGS" ] && echo -e "Forge Flags:  ${YELLOW}$FORGE_FLAGS${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# ── Confirm ───────────────────────────────────────────────────────────────────
read -p "Deploy to $NETWORK? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo -e "${RED}Deployment cancelled${NC}"
    exit 0
fi

echo ""
echo -e "${GREEN}Starting deployment...${NC}"
echo ""

# ── Prepare output directory ─────────────────────────────────────────────────
DEPLOY_OUT="deployments/${NETWORK}.json"
mkdir -p deployments

# ── Run forge script ──────────────────────────────────────────────────────────
FORGE_CMD="forge script $SCRIPT \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast \
    --slow \
    --chain-id $CHAIN_ID \
    $FORGE_FLAGS \
    -vvvv"

echo -e "${CYAN}$FORGE_CMD${NC}"
echo ""
eval $FORGE_CMD

# ── Extract deployed addresses from broadcast ────────────────────────────────
BROADCAST_DIR="broadcast/$(basename $SCRIPT)/${CHAIN_ID}"
LATEST_RUN="${BROADCAST_DIR}/run-latest.json"

if [ -f "$LATEST_RUN" ] && command -v jq &> /dev/null; then
    echo ""
    echo -e "${GREEN}Extracting deployed addresses...${NC}"
    jq '{
        network: "'$NETWORK'",
        chainId: '$CHAIN_ID',
        timestamp: (now | todate),
        contracts: [
            .transactions[]
            | select(.transactionType == "CREATE")
            | {
                name: .contractName,
                address: .contractAddress
            }
        ]
    }' "$LATEST_RUN" > "$DEPLOY_OUT"
    echo -e "Saved to: ${YELLOW}$DEPLOY_OUT${NC}"
    echo ""
    jq '.' "$DEPLOY_OUT"
else
    echo -e "${YELLOW}Note: Could not extract addresses automatically.${NC}"
    echo "Check forge broadcast output above for deployed addresses."
fi

# ── Post-deployment output ───────────────────────────────────────────────────
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Deployment Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Check deployed addresses in $DEPLOY_OUT"
echo "2. Verify ownership transferred to Safe"
echo "3. Verify contracts: $EXPLORER_URL"
echo ""

if [ "$DEPLOY_TYPE" = "swap" ]; then
    echo -e "${YELLOW}────────────────────────────────────────${NC}"
    echo -e "${YELLOW}Swap Router Post-Deployment Steps:${NC}"
    echo -e "${YELLOW}────────────────────────────────────────${NC}"
    echo ""
    echo "For EACH BettingMatch proxy that should accept CHZ swap bets:"
    echo ""
    echo "  1) Set USDC token:"
    echo -e "     ${CYAN}cast send <MATCH> 'setUSDCToken(address)' $USDC_ADDRESS --rpc-url $RPC_URL --private-key \$PRIVATE_KEY${NC}"
    echo ""
    echo "  2) Grant SWAP_ROUTER_ROLE to BettingSwapRouter:"
    echo -e "     ${CYAN}cast send <MATCH> 'grantRole(bytes32,address)' \$(cast keccak 'SWAP_ROUTER_ROLE') <SWAP_ROUTER> --rpc-url $RPC_URL --private-key \$PRIVATE_KEY${NC}"
    echo ""
    echo "  3) Fund USDC treasury:"
    echo -e "     ${CYAN}cast send $USDC_ADDRESS 'approve(address,uint256)' <MATCH> <AMOUNT> --rpc-url $RPC_URL --private-key \$PRIVATE_KEY${NC}"
    echo -e "     ${CYAN}cast send <MATCH> 'fundUSDCTreasury(uint256)' <AMOUNT> --rpc-url $RPC_URL --private-key \$PRIVATE_KEY${NC}"
    echo ""
    echo "  4) Test swap bet:"
    echo -e "     ${CYAN}cast send <SWAP_ROUTER> 'placeBetWithCHZ(address,uint256,uint64,uint256,uint256)' <MATCH> 0 0 1 \$(date +%s --date '+1 hour') --value 10ether --rpc-url $RPC_URL --private-key \$PRIVATE_KEY${NC}"
    echo ""
fi
