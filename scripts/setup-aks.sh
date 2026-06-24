#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=lib/load-env.sh
source "${SCRIPT_DIR}/lib/load-env.sh"
load_ep_env "${ROOT_DIR}"

# Positional args override .env
RESOURCE_GROUP="${1:-${AZURE_RESOURCE_GROUP:-}}"
AKS_NAME="${2:-${AKS_CLUSTER_NAME:-}}"
LOCATION="${3:-${AZURE_LOCATION:-}}"
NODE_COUNT="${AKS_NODE_COUNT:-3}"
NODE_VM_SIZE="${AKS_NODE_VM_SIZE:-Standard_D4s_v5}"

usage() {
  cat <<EOF
Usage: $0 [resource-group] [aks-name] [location]

Create (or verify) AKS + ACR for Edge Processor. Safe to re-run if resources already exist.

With no arguments, reads from .env (copy env.template → .env):
  AZURE_RESOURCE_GROUP=ep-rg
  AKS_CLUSTER_NAME=ep-aks
  AZURE_LOCATION=eastus
  AKS_NODE_COUNT=2
  AKS_NODE_VM_SIZE=Standard_D4s_v5
  ACR_NAME=epacr          # creates ACR; pulls use acr-pull-secret

Examples:
  cp env.template .env && $0
  $0 ep-rg ep-aks eastus

After cluster exists, use ./scripts/deploy.sh for image rebuilds and redeploys.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -z "${RESOURCE_GROUP}" || -z "${AKS_NAME}" || -z "${LOCATION}" ]]; then
  echo "ERROR: resource group, AKS name, and location are required." >&2
  echo "" >&2
  echo "Set AZURE_RESOURCE_GROUP, AKS_CLUSTER_NAME, and AZURE_LOCATION in .env," >&2
  echo "or pass them as arguments." >&2
  echo "" >&2
  usage >&2
  exit 1
fi

if [[ -z "${ACR_NAME:-}" ]]; then
  echo "ERROR: set ACR_NAME in .env (globally unique registry name)." >&2
  exit 1
fi

echo "Ensuring resource group ${RESOURCE_GROUP} in ${LOCATION}"
az group create --name "${RESOURCE_GROUP}" --location "${LOCATION}" -o none

echo "Ensuring ACR ${ACR_NAME} exists"
if ! az acr show --name "${ACR_NAME}" --resource-group "${RESOURCE_GROUP}" >/dev/null 2>&1; then
  az acr create \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${ACR_NAME}" \
    --sku Standard \
    --admin-enabled false \
    -o none
  echo "  Created ACR ${ACR_NAME}.azurecr.io"
else
  echo "  ACR ${ACR_NAME} already exists in ${RESOURCE_GROUP}"
fi

if az aks show --resource-group "${RESOURCE_GROUP}" --name "${AKS_NAME}" >/dev/null 2>&1; then
  echo "AKS cluster ${AKS_NAME} already exists — skipping create"
else
  CREATE_ARGS=(
    --resource-group "${RESOURCE_GROUP}"
    --name "${AKS_NAME}"
    --node-count "${NODE_COUNT}"
    --node-vm-size "${NODE_VM_SIZE}"
    --enable-managed-identity
    --generate-ssh-keys
  )

  if [[ -n "${AKS_K8S_VERSION:-}" ]]; then
    CREATE_ARGS+=(--kubernetes-version "${AKS_K8S_VERSION}")
  fi

  echo "Creating AKS cluster ${AKS_NAME}"
  echo "  nodes: ${NODE_COUNT} x ${NODE_VM_SIZE}"
  az aks create "${CREATE_ARGS[@]}" -o none
  echo "  Created AKS cluster ${AKS_NAME}"
fi

echo "Fetching kubectl credentials"
az aks get-credentials --resource-group "${RESOURCE_GROUP}" --name "${AKS_NAME}" --overwrite-existing

echo "Verifying cluster access"
kubectl get nodes

echo ""
echo "Infrastructure ready (safe to re-run this script anytime)."
echo "Next: ./scripts/deploy.sh install-script.txt"
