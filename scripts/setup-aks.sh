#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 4 ]]; then
  echo "Usage: $0 <resource-group> <aks-name> <acr-name> <location>"
  echo "Example: $0 ep-rg ep-aks mycompanyacr eastus"
  exit 1
fi

RESOURCE_GROUP="$1"
AKS_NAME="$2"
ACR_NAME="$3"
LOCATION="$4"

echo "Creating resource group ${RESOURCE_GROUP} in ${LOCATION}"
az group create --name "${RESOURCE_GROUP}" --location "${LOCATION}"

echo "Creating ACR ${ACR_NAME}"
az acr create \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${ACR_NAME}" \
  --sku Standard \
  --admin-enabled false

echo "Creating AKS cluster ${AKS_NAME}"
az aks create \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${AKS_NAME}" \
  --node-count 3 \
  --node-vm-size Standard_D4s_v5 \
  --enable-managed-identity \
  --attach-acr "${ACR_NAME}" \
  --generate-ssh-keys

echo "Fetching kubectl credentials"
az aks get-credentials --resource-group "${RESOURCE_GROUP}" --name "${AKS_NAME}" --overwrite-existing

echo "Verifying cluster access"
kubectl get nodes

echo "AKS cluster ready. Next steps:"
echo "  1. ./scripts/build-and-push-acr.sh ${ACR_NAME} latest"
echo "  2. Edit k8s/deployment.yaml with your ACR image and DMX_HOST"
echo "  3. Create Splunk secret and ConfigMap"
echo "  4. kubectl apply -f k8s/"
