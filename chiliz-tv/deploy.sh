#!/bin/bash
#
# ChilizTV Deployment Script (Chiliz-only)
#
# All configuration is loaded from .env (see .env.example).
#
# Usage:
#   ./deploy.sh --network chilizTestnet --all
#   ./deploy.sh --network chilizTestnet --match
#   ./deploy.sh --network chilizTestnet --stream
#   ./deploy.sh --network chilizTestnet --swap
#   ./deploy.sh --network chilizMainnet  --all
#
# The --network flag is a safety label only: it picks the mainnet warning
# and is used for output paths (deployments/<network>.json). The actual
# RPC_URL / CHAIN_ID / FORGE_FLAGS come from .env.
#

set -e

# ── Colors ───────────────────────────────────────────────────────────────────
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
        --payout)
            DEPLOY_TYPE="payout"; shift ;;
        *)
            echo -e "${RED}Unknown argument: $1${NC}"
            echo "Usage: ./deploy.sh --network <chilizTestnet|chilizMainnet> <--all|--match|--stream|--swap|--payout>"
            exit 1 ;;
    esac
done

if [ -z "$NETWORK" ] || [ -z "$DEPLOY_TYPE" ]; then
    echo -e "${RED}Missing required arguments.${NC}"
    echo "Usage: ./deploy.sh --network <chilizTestnet|chilizMainnet> <--all|--match|--stream|--swap|--payout>"
    exit 1
fi

# ── Load .env ────────────────────────────────────────────────────────────────
# Prefer .env.<network> when present, otherwise .env.
ENV_FILE=".env"
if [ -f ".env.${NETWORK}" ]; then
    ENV_FILE=".env.${NETWORK}"
fi

if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}Error: $ENV_FILE not found.${NC}"
    echo "Copy .env.example to .env and fill in values."
    exit 1
fi

# set -a exports every variable assigned until `set +a`.
# sed strips a leading UTF-8 BOM and any trailing CR — Windows editors
# routinely add both, which would otherwise break `source`.
set -a
# shellcheck disable=SC1090
source <(sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r$//' "$ENV_FILE")
set +a

# ── Validate required env vars ───────────────────────────────────────────────
REQUIRED="PRIVATE_KEY SAFE_ADDRESS RPC_URL CHAIN_ID"
MISSING=""
for VAR in $REQUIRED; do
    if [ -z "${!VAR}" ]; then
        MISSING="${MISSING}\n  - $VAR"
    fi
done
if [ -n "$MISSING" ]; then
    echo -e "${RED}Missing required env vars in $ENV_FILE:${MISSING}${NC}"
    exit 1
fi

# ── Sanity check: CHAIN_ID matches --network label ───────────────────────────
case "$NETWORK" in
    chilizTestnet)
        EXPECTED_CHAIN_ID=88882 ;;
    chilizMainnet)
        EXPECTED_CHAIN_ID=88888 ;;
    *)
        echo -e "${YELLOW}Warning: unknown --network '$NETWORK' (skipping chain-id sanity check)${NC}"
        EXPECTED_CHAIN_ID="" ;;
esac
if [ -n "$EXPECTED_CHAIN_ID" ] && [ "$CHAIN_ID" != "$EXPECTED_CHAIN_ID" ]; then
    echo -e "${RED}Chain id mismatch:${NC}"
    echo -e "  --network $NETWORK expects CHAIN_ID=$EXPECTED_CHAIN_ID"
    echo -e "  but $ENV_FILE has CHAIN_ID=$CHAIN_ID"
    echo -e "  Fix $ENV_FILE or pass the correct --network."
    exit 1
fi

# ── Deploy type → script mapping ─────────────────────────────────────────────
REQUIRES_KAYEN=false
REQUIRES_USDC=false
case "$DEPLOY_TYPE" in
    all)
        SCRIPT="script/DeployAll.s.sol"
        REQUIRES_KAYEN=true
        REQUIRES_USDC=true ;;
    match)
        SCRIPT="script/DeployBetting.s.sol" ;;
    stream)
        SCRIPT="script/DeployStreaming.s.sol" ;;
    swap)
        SCRIPT="script/DeploySwap.s.sol"
        REQUIRES_KAYEN=true
        REQUIRES_USDC=true ;;
    payout)
        SCRIPT="script/DeployPayout.s.sol"
        REQUIRES_USDC=true ;;
esac

# ── USDC / Kayen validation ──────────────────────────────────────────────────
if [ "$REQUIRES_USDC" = true ] && [ -z "$USDC_ADDRESS" ]; then
    echo -e "${RED}Missing USDC_ADDRESS in $ENV_FILE${NC}"
    exit 1
fi

if [ "$REQUIRES_KAYEN" = true ]; then
    echo -e "${CYAN}Resolving Kayen DEX addresses...${NC}"
    MISSING=""
    [ -z "$KAYEN_ROUTER" ] && MISSING="${MISSING}\n  - KAYEN_ROUTER"
    [ -z "$WCHZ_ADDRESS" ] && MISSING="${MISSING}\n  - WCHZ_ADDRESS"
    if [ -n "$MISSING" ]; then
        echo -e "${RED}Missing in $ENV_FILE:${MISSING}${NC}"
        exit 1
    fi
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
echo -e "Env File:     ${YELLOW}$ENV_FILE${NC}"
[ -n "$FORGE_FLAGS" ] && echo -e "Forge Flags:  ${YELLOW}$FORGE_FLAGS${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# ── Confirm ──────────────────────────────────────────────────────────────────
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

# ── Run forge script ─────────────────────────────────────────────────────────
# NOTE: --chain-id intentionally omitted. Forge's NamedChain registry rejects
# Chiliz IDs (88882 / 88888) with "Chain not supported". RPC URL is enough
# to detect the chain, and --legacy signing does not require chain id.
FORGE_CMD="forge script $SCRIPT \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast \
    --slow \
    --legacy \
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
    echo -e "${YELLOW}Note: could not extract addresses automatically.${NC}"
    echo "Broadcast file: $LATEST_RUN"
    echo "Check forge output above for deployed addresses."
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
    echo "  2) Grant SWAP_ROUTER_ROLE to ChilizSwapRouter:"
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
