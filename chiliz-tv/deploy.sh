#!/bin/bash
#
# ChilizTV Deployment Script (Chiliz-only)
#
# Usage:
#   ./deploy.sh --network chilizTestnet --all
#   ./deploy.sh --network chilizTestnet --match
#   ./deploy.sh --network chilizTestnet --stream
#   ./deploy.sh --network chilizTestnet --swap
#   ./deploy.sh --network chilizTestnet --pool
#   ./deploy.sh --network chilizMainnet --all
#
# IMPORTANT: ASCII-only. Do NOT add box-drawing, arrows, emojis, or any
# non-ASCII character. The file has round-tripped through Windows before
# and been corrupted by CP1252/UTF-8 mojibake. Keep it clean.
#
# FUTURE WORK: Base chain support (postponed, not included here).
#

set -e

# --- Colors ------------------------------------------------------------------
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- Parse arguments ---------------------------------------------------------
NETWORK=""
DEPLOY_TYPE=""

USAGE="Usage: ./deploy.sh --network <chilizTestnet|chilizMainnet> <--all|--match|--stream|--swap|--pool>"

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
        --pool)
            DEPLOY_TYPE="pool"; shift ;;
        *)
            echo -e "${RED}Unknown argument: $1${NC}"
            echo "$USAGE"
            exit 1 ;;
    esac
done

if [ -z "$NETWORK" ] || [ -z "$DEPLOY_TYPE" ]; then
    echo -e "${RED}Missing required arguments.${NC}"
    echo "$USAGE"
    exit 1
fi

# --- Load .env ---------------------------------------------------------------
# Robust loader: strips BOM and CR, skips blank/comment lines, keeps values
# that may contain '=' or spaces intact. Works regardless of whether the file
# was saved on Windows (CRLF + BOM) or Unix (LF).
if [ ! -f .env ]; then
    echo -e "${RED}Error: .env file not found${NC}"
    exit 1
fi

while IFS='=' read -r key value; do
    # Skip blanks and comments
    [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
    # Strip surrounding whitespace and trailing CR from key/value
    key="$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    value="${value%$'\r'}"
    [[ -z "$key" ]] && continue
    export "$key=$value"
done < <(sed '1s/^\xef\xbb\xbf//; s/\r$//' .env)

# --- Validate common env vars ------------------------------------------------
if [ -z "$PRIVATE_KEY" ]; then
    echo -e "${RED}Error: PRIVATE_KEY not set in .env${NC}"
    exit 1
fi
if [ -z "$SAFE_ADDRESS" ]; then
    echo -e "${RED}Error: SAFE_ADDRESS not set in .env${NC}"
    exit 1
fi

# --- Load config from config/<network>.json ----------------------------------
CONFIG_FILE="config/${NETWORK}.json"
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Error: Config file not found: $CONFIG_FILE${NC}"
    echo "Create it first. See config/chilizTestnet.json for reference."
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: 'jq' is required but not installed.${NC}"
    echo "Install: sudo apt install jq"
    exit 1
fi

CHAIN_ID=$(jq -r '.chainId' "$CONFIG_FILE")
RPC_ALIAS=$(jq -r '.rpcAlias // empty' "$CONFIG_FILE")
RPC_URL=$(jq -r '.rpcUrl' "$CONFIG_FILE")
EXPLORER_URL=$(jq -r '.explorerUrl' "$CONFIG_FILE")
VERIFIER_URL=$(jq -r '.verifierUrl' "$CONFIG_FILE")
CFG_KAYEN_ROUTER=$(jq -r '.kayenMasterRouter // empty' "$CONFIG_FILE")
CFG_WCHZ=$(jq -r '.wchz // empty' "$CONFIG_FILE")
CFG_USDC=$(jq -r '.usdc // empty' "$CONFIG_FILE")
FORGE_FLAGS=$(jq -r '.forgeFlags // empty' "$CONFIG_FILE")

if [ -z "$RPC_ALIAS" ]; then
    echo -e "${RED}Error: 'rpcAlias' missing in $CONFIG_FILE${NC}"
    echo "Add it and make sure it matches an entry in foundry.toml [rpc_endpoints] and [etherscan]."
    exit 1
fi

# --- Deploy type -> script mapping -------------------------------------------
REQUIRES_KAYEN=false
REQUIRES_USDC=false
REQUIRES_ADMIN=false
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
    pool)
        SCRIPT="script/DeployLiquidityPool.s.sol"
        REQUIRES_USDC=true
        REQUIRES_ADMIN=true ;;
esac

# --- Pool-specific: ADMIN_ADDRESS must exist and differ from SAFE_ADDRESS ----
if [ "$REQUIRES_ADMIN" = true ]; then
    if [ -z "$ADMIN_ADDRESS" ]; then
        echo -e "${RED}Error: ADMIN_ADDRESS not set in .env (required for --pool)${NC}"
        echo "ADMIN_ADDRESS holds DEFAULT_ADMIN_ROLE + PAUSER_ROLE and MUST differ from SAFE_ADDRESS."
        exit 1
    fi
    # Lowercase compare (portable; no bashism ${,,})
    _admin_lc=$(echo "$ADMIN_ADDRESS" | tr '[:upper:]' '[:lower:]')
    _safe_lc=$(echo "$SAFE_ADDRESS" | tr '[:upper:]' '[:lower:]')
    if [ "$_admin_lc" = "$_safe_lc" ]; then
        echo -e "${RED}Error: ADMIN_ADDRESS must be different from SAFE_ADDRESS${NC}"
        exit 1
    fi
    export ADMIN_ADDRESS
fi

# --- Resolve USDC address (env overrides config) -----------------------------
if [ "$REQUIRES_USDC" = true ]; then
    USDC_ADDRESS="${USDC_ADDRESS:-$CFG_USDC}"
    if [ -z "$USDC_ADDRESS" ]; then
        echo -e "${RED}Missing USDC_ADDRESS (set in .env or config/${NETWORK}.json 'usdc' field)${NC}"
        exit 1
    fi
    export USDC_ADDRESS
fi

# --- Swap-specific: resolve Kayen addresses (env overrides config) -----------
if [ "$REQUIRES_KAYEN" = true ]; then
    echo -e "${CYAN}Resolving Kayen DEX addresses...${NC}"

    KAYEN_ROUTER="${KAYEN_ROUTER:-$CFG_KAYEN_ROUTER}"
    WCHZ_ADDRESS="${WCHZ_ADDRESS:-$CFG_WCHZ}"

    MISSING=""
    [ -z "$KAYEN_ROUTER" ] && MISSING="${MISSING}  - KAYEN_ROUTER (set in .env or config/${NETWORK}.json)"$'\n'
    [ -z "$WCHZ_ADDRESS" ] && MISSING="${MISSING}  - WCHZ_ADDRESS (set in .env or config/${NETWORK}.json)"$'\n'

    if [ -n "$MISSING" ]; then
        echo -e "${RED}Missing required swap addresses:${NC}"
        echo -e "$MISSING"
        exit 1
    fi

    export KAYEN_ROUTER WCHZ_ADDRESS

    echo -e "  KAYEN_ROUTER: ${YELLOW}$KAYEN_ROUTER${NC}"
    echo -e "  WCHZ_ADDRESS: ${YELLOW}$WCHZ_ADDRESS${NC}"
    echo -e "  USDC_ADDRESS: ${YELLOW}$USDC_ADDRESS${NC}"
    echo ""
fi

# --- Mainnet safety warning --------------------------------------------------
if [ "$NETWORK" = "chilizMainnet" ]; then
    echo -e "${RED}+-------------------------------------------+${NC}"
    echo -e "${RED}|   !! MAINNET DEPLOYMENT WARNING !!        |${NC}"
    echo -e "${RED}|   Real funds are at risk. Double-check:   |${NC}"
    echo -e "${RED}|   - All contract addresses are correct    |${NC}"
    echo -e "${RED}|   - Ownership will transfer to Safe       |${NC}"
    echo -e "${RED}|   - Testnet deployment succeeded first    |${NC}"
    echo -e "${RED}+-------------------------------------------+${NC}"
    echo ""
fi

# --- Display summary ---------------------------------------------------------
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}ChilizTV Deployment${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "Network:      ${YELLOW}$NETWORK${NC} (Chain ID: $CHAIN_ID)"
echo -e "Deploy Type:  ${YELLOW}$DEPLOY_TYPE${NC}"
echo -e "Script:       ${YELLOW}$SCRIPT${NC}"
echo -e "RPC Alias:    ${YELLOW}$RPC_ALIAS${NC} -> $RPC_URL"
echo -e "Safe Address: ${YELLOW}$SAFE_ADDRESS${NC}"
echo -e "Config:       ${YELLOW}$CONFIG_FILE${NC}"
[ -n "$FORGE_FLAGS" ] && echo -e "Forge Flags:  ${YELLOW}$FORGE_FLAGS${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# --- Confirm -----------------------------------------------------------------
read -p "Deploy to $NETWORK? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo -e "${RED}Deployment cancelled${NC}"
    exit 0
fi

echo ""
echo -e "${GREEN}Starting deployment...${NC}"
echo ""

# --- Prepare output directory ------------------------------------------------
DEPLOY_OUT="deployments/${NETWORK}.json"
mkdir -p deployments

# --- Run forge script --------------------------------------------------------
# We pass --rpc-url and --chain as the alias defined in foundry.toml
# ([rpc_endpoints] + [etherscan]). This registers the Chiliz chain with
# forge's internal chain manager and avoids the alloy-chains
# "Chain X not supported" error that fires when --chain-id is used with an
# unregistered numeric id.
FORGE_CMD="forge script $SCRIPT \
    --rpc-url $RPC_ALIAS \
    --chain $RPC_ALIAS \
    --private-key $PRIVATE_KEY \
    --broadcast \
    --slow \
    $FORGE_FLAGS \
    -vvvv"

echo -e "${CYAN}$FORGE_CMD${NC}"
echo ""
eval $FORGE_CMD

# --- Extract deployed addresses from broadcast -------------------------------
BROADCAST_DIR="broadcast/$(basename "$SCRIPT")/${CHAIN_ID}"
LATEST_RUN="${BROADCAST_DIR}/run-latest.json"

if [ -f "$LATEST_RUN" ]; then
    echo ""
    echo -e "${GREEN}Extracting deployed addresses...${NC}"
    jq --arg network "$NETWORK" --argjson chainId "$CHAIN_ID" '{
        network: $network,
        chainId: $chainId,
        timestamp: (now | todate),
        contracts: [
            .transactions[]
            | select(.transactionType == "CREATE")
            | { name: .contractName, address: .contractAddress }
        ]
    }' "$LATEST_RUN" > "$DEPLOY_OUT"
    echo -e "Saved to: ${YELLOW}$DEPLOY_OUT${NC}"
    echo ""
    jq '.' "$DEPLOY_OUT"
else
    echo -e "${YELLOW}Note: Could not extract addresses automatically.${NC}"
    echo "Check forge broadcast output above for deployed addresses."
fi

# --- Post-deployment output --------------------------------------------------
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
    echo -e "${YELLOW}----------------------------------------${NC}"
    echo -e "${YELLOW}Swap Router Post-Deployment Steps:${NC}"
    echo -e "${YELLOW}----------------------------------------${NC}"
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
    echo -e "     ${CYAN}cast send <SWAP_ROUTER> 'placeBetWithCHZ(address,uint256,uint64,uint256,uint256)' <MATCH> 0 0 1 \$(date +%s -d '+1 hour') --value 10ether --rpc-url $RPC_URL --private-key \$PRIVATE_KEY${NC}"
    echo ""
fi
