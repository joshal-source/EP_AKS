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

Create an AKS cluster for Edge Processor (image from GHCR or Docker Hub).

With no arguments, reads from .env (copy env.template → .env):
  AZURE_RESOURCE_GROUP=ep-rg
  AKS_CLUSTER_NAME=ep-aks
  AZURE_LOCATION=eastus
  AKS_NODE_COUNT=3
  AKS_NODE_VM_SIZE=Standard_D4s_v5

For AKS + Azure Container Registry instead, use: ./scripts/setup-aks-with-acr.sh

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
echo "  1. ./scripts/create-ghcr-secret.sh <github-user> <ghp-token>"
echo "  2. cp helm/edge-processor/values-local.yaml.example helm/edge-processor/values-local.yaml  # optional"
echo "  3. ./scripts/setup-from-install-script.sh install-script.txt --apply"
