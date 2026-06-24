#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=lib/load-env.sh
source "${SCRIPT_DIR}/lib/load-env.sh"
# shellcheck source=lib/nsg-allowed-sources.sh
source "${SCRIPT_DIR}/lib/nsg-allowed-sources.sh"
load_ep_env "${ROOT_DIR}"

RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:?set AZURE_RESOURCE_GROUP in .env}"
LOCATION="${AZURE_LOCATION:?set AZURE_LOCATION in .env}"
VNET_NAME="${VNET_NAME:-ep-vnet}"
AKS_SUBNET_NAME="${AKS_SUBNET_NAME:-ep-aks-subnet}"
NSG_NAME="${NSG_NAME:-ep-edge-nsg}"
VNET_ADDRESS_PREFIX="${VNET_ADDRESS_PREFIX:-10.50.0.0/16}"
AKS_SUBNET_PREFIX="${AKS_SUBNET_PREFIX:-10.50.1.0/24}"

usage() {
  cat <<EOF
Usage: $0

Create or update VNet, NSG, and AKS subnet for Edge Processor (idempotent).

Reads from .env:
  NSG_NAME                 NSG resource name (default: ep-edge-nsg)
  VNET_NAME                Virtual network name (default: ep-vnet)
  AKS_SUBNET_NAME          Subnet for AKS nodes (default: ep-aks-subnet)
  VNET_ADDRESS_PREFIX      VNet CIDR (default: 10.50.0.0/16)
  AKS_SUBNET_PREFIX        Subnet CIDR (default: 10.50.1.0/24)
  NSG_ALLOWED_SOURCES_FILE Path to allow-list file (see config/nsg-allowed-sources.conf.example)

Also run automatically from ./scripts/setup-aks.sh before cluster create.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if ! command -v az >/dev/null 2>&1; then
  echo "ERROR: az CLI is not installed." >&2
  exit 1
fi

echo "Ensuring virtual network ${VNET_NAME} (${VNET_ADDRESS_PREFIX})"
if ! az network vnet show --resource-group "${RESOURCE_GROUP}" --name "${VNET_NAME}" >/dev/null 2>&1; then
  az network vnet create \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${VNET_NAME}" \
    --location "${LOCATION}" \
    --address-prefixes "${VNET_ADDRESS_PREFIX}" \
    -o none
  echo "  Created VNet ${VNET_NAME}"
else
  echo "  VNet ${VNET_NAME} already exists"
fi

echo "Ensuring NSG ${NSG_NAME}"
if ! az network nsg show --resource-group "${RESOURCE_GROUP}" --name "${NSG_NAME}" >/dev/null 2>&1; then
  az network nsg create \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${NSG_NAME}" \
    --location "${LOCATION}" \
    -o none
  echo "  Created NSG ${NSG_NAME}"
else
  echo "  NSG ${NSG_NAME} already exists"
fi

echo "Applying NSG allow rules from config"
"${SCRIPT_DIR}/apply-nsg-rules.sh"

echo "Ensuring subnet ${AKS_SUBNET_NAME} (${AKS_SUBNET_PREFIX})"
if ! az network vnet subnet show \
  --resource-group "${RESOURCE_GROUP}" \
  --vnet-name "${VNET_NAME}" \
  --name "${AKS_SUBNET_NAME}" >/dev/null 2>&1; then
  az network vnet subnet create \
    --resource-group "${RESOURCE_GROUP}" \
    --vnet-name "${VNET_NAME}" \
    --name "${AKS_SUBNET_NAME}" \
    --address-prefixes "${AKS_SUBNET_PREFIX}" \
    --network-security-group "${NSG_NAME}" \
    --disable-private-endpoint-network-policies true \
    -o none
  echo "  Created subnet ${AKS_SUBNET_NAME}"
else
  az network vnet subnet update \
    --resource-group "${RESOURCE_GROUP}" \
    --vnet-name "${VNET_NAME}" \
    --name "${AKS_SUBNET_NAME}" \
    --network-security-group "${NSG_NAME}" \
    --disable-private-endpoint-network-policies true \
    -o none
  echo "  Subnet ${AKS_SUBNET_NAME} already exists (NSG association refreshed)"
fi

SUBNET_ID="$(az network vnet subnet show \
  --resource-group "${RESOURCE_GROUP}" \
  --vnet-name "${VNET_NAME}" \
  --name "${AKS_SUBNET_NAME}" \
  --query id -o tsv)"

echo ""
echo "Network ready."
echo "  NSG:   ${NSG_NAME}"
echo "  Subnet: ${SUBNET_ID}"
echo "  Allow-list: $(nsg_allowed_sources_file "${ROOT_DIR}")"
