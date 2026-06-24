#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${ROOT_DIR}/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${ROOT_DIR}/.env"
  set +a
fi

# Positional args override .env
RESOURCE_GROUP="${1:-${AZURE_RESOURCE_GROUP:-}}"
AKS_NAME="${2:-${AKS_CLUSTER_NAME:-}}"
LOCATION="${3:-${AZURE_LOCATION:-}}"
NODE_COUNT="${AKS_NODE_COUNT:-3}"
NODE_VM_SIZE="${AKS_NODE_VM_SIZE:-Standard_D4s_v5}"

usage() {
  cat <<EOF
Usage: $0 [resource-group] [aks-name] [location]

Create an AKS cluster for Edge Processor.

With no arguments, reads from .env (copy env.template → .env):
  AZURE_RESOURCE_GROUP=ep-rg
  AKS_CLUSTER_NAME=ep-aks
  AZURE_LOCATION=eastus
  AKS_NODE_COUNT=2
  AKS_NODE_VM_SIZE=Standard_D4s_v5
  ACR_NAME=epacr          # creates ACR; pulls use acr-pull-secret (not attach-acr)

Examples:
  cp env.template .env && $0
  $0 ep-rg ep-aks eastus
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

echo "Creating resource group ${RESOURCE_GROUP} in ${LOCATION}"
az group create --name "${RESOURCE_GROUP}" --location "${LOCATION}"

if [[ -n "${ACR_NAME:-}" ]]; then
  echo "Ensuring ACR ${ACR_NAME} exists"
  if ! az acr show --name "${ACR_NAME}" --resource-group "${RESOURCE_GROUP}" >/dev/null 2>&1; then
    az acr create \
      --resource-group "${RESOURCE_GROUP}" \
      --name "${ACR_NAME}" \
      --sku Standard \
      --admin-enabled false
  else
    echo "  ACR ${ACR_NAME} already exists in ${RESOURCE_GROUP}"
  fi
fi

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
az aks create "${CREATE_ARGS[@]}"

echo "Fetching kubectl credentials"
az aks get-credentials --resource-group "${RESOURCE_GROUP}" --name "${AKS_NAME}" --overwrite-existing

echo "Verifying cluster access"
kubectl get nodes

echo ""
echo "AKS cluster ready."
echo "Next steps:"
if [[ -n "${ACR_NAME:-}" ]]; then
  echo "  1. ./scripts/build-local.sh --push"
  echo "  2. ./scripts/create-acr-secret.sh"
  echo "  3. cp helm/edge-processor/values-local.yaml.example helm/edge-processor/values-local.yaml"
  echo "  4. ./scripts/setup-from-install-script.sh install-script.txt --apply"
else
  echo "  Set ACR_NAME in .env, then build, create-acr-secret, and deploy."
fi
