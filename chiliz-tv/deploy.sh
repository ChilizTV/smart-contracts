#!/bin/bash
# ChilizTV Quick Deploy Script
# Usage: ./deploy.sh [testnet|mainnet] [all|betting|streaming]

set -e

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Load environment variables
if [ -f .env ]; then
    export $(cat .env | grep -v '^#' | xargs)
else
    echo -e "${RED}Error: .env file not found${NC}"
    exit 1
fi

# Check required variables
if [ -z "$PRIVATE_KEY" ]; then
    echo -e "${RED}Error: PRIVATE_KEY not set in .env${NC}"
    exit 1
fi

if [ -z "$SAFE_ADDRESS" ]; then
    echo -e "${RED}Error: SAFE_ADDRESS not set in .env${NC}"
    exit 1
fi

# Parse arguments
NETWORK=${1:-testnet}
DEPLOY_TYPE=${2:-all}

# Set network-specific variables
if [ "$NETWORK" = "mainnet" ]; then
    RPC_URL="https://rpc.ankr.com/chiliz"
    VERIFIER_URL="https://api.routescan.io/v2/network/mainnet/evm/88888/etherscan/api"
    CHAIN_ID=88888
elif [ "$NETWORK" = "testnet" ]; then
    RPC_URL="https://spicy-rpc.chiliz.com"
    VERIFIER_URL="https://api.routescan.io/v2/network/testnet/evm/88882/etherscan/api"
    CHAIN_ID=88882
else
    echo -e "${RED}Invalid network: $NETWORK${NC}"
    echo "Usage: ./deploy.sh [testnet|mainnet] [all|betting|streaming]"
    exit 1
fi

# Set script based on deploy type
if [ "$DEPLOY_TYPE" = "all" ]; then
    SCRIPT="script/DeployAll.s.sol"
elif [ "$DEPLOY_TYPE" = "betting" ]; then
    SCRIPT="script/DeployBetting.s.sol"
elif [ "$DEPLOY_TYPE" = "streaming" ]; then
    SCRIPT="script/DeployStreaming.s.sol"
else
    echo -e "${RED}Invalid deploy type: $DEPLOY_TYPE${NC}"
    echo "Usage: ./deploy.sh [testnet|mainnet] [all|betting|streaming]"
    exit 1
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}ChilizTV Deployment${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "Network:      ${YELLOW}$NETWORK${NC} (Chain ID: $CHAIN_ID)"
echo -e "Deploy Type:  ${YELLOW}$DEPLOY_TYPE${NC}"
echo -e "Script:       ${YELLOW}$SCRIPT${NC}"
echo -e "RPC URL:      ${YELLOW}$RPC_URL${NC}"
echo -e "Safe Address: ${YELLOW}$SAFE_ADDRESS${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Confirm before deploying
read -p "Deploy to $NETWORK? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo -e "${RED}Deployment cancelled${NC}"
    exit 0
fi

echo ""
echo -e "${GREEN}Starting deployment...${NC}"
echo ""

# Run forge script (without verification - verify manually later)
forge script $SCRIPT \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast \
    --etherscan-api-key $CHILIZ_EXPLORER_API_KEY \
    --priority-gas-price 1000000000 \
    --with-gas-price 6000000000000 \
    --resume \
    -vvvv

    # Add verification options if needed
    # --verify \
    # --verifier blockscout \
    # --verifier-url https://testnet.chiliscan.com/api/ \

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Deployment Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Save deployed contract addresses from output above"
echo "2. Verify ownership transferred to Safe"
echo "3. Verify contracts manually on block explorer"
echo "4. Test contract interactions"
echo ""
echo -e "${YELLOW}To verify contracts manually:${NC}"
echo "Visit: https://testnet.chiliscan.com/address/<CONTRACT_ADDRESS>#code"
echo "Click 'Verify & Publish' and paste your Solidity code"
echo ""
