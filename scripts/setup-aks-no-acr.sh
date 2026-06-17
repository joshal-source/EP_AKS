#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <resource-group> <aks-name> <location>"
  echo "Example: $0 ep-rg ep-aks eastus"
  echo ""
  echo "Creates AKS without Azure Container Registry (ACR)."
  echo "Use Docker Hub or another registry instead — see README."
  exit 1
fi

RESOURCE_GROUP="$1"
AKS_NAME="$2"
LOCATION="$3"

echo "Creating resource group ${RESOURCE_GROUP} in ${LOCATION}"
az group create --name "${RESOURCE_GROUP}" --location "${LOCATION}"

echo "Creating AKS cluster ${AKS_NAME} (no ACR attachment)"
az aks create \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${AKS_NAME}" \
  --node-count 3 \
  --node-vm-size Standard_D4s_v5 \
  --enable-managed-identity \
  --generate-ssh-keys

echo "Fetching kubectl credentials"
az aks get-credentials --resource-group "${RESOURCE_GROUP}" --name "${AKS_NAME}" --overwrite-existing

echo "Verifying cluster access"
kubectl get nodes

echo ""
echo "AKS cluster ready (no ACR)."
echo "Next steps:"
echo "  1. Push image to Docker Hub: ./scripts/build-and-push-dockerhub.sh <dockerhub-user> latest"
echo "  2. If repo is private: ./scripts/create-registry-secret.sh dockerhub <user> <token-or-password>"
echo "  3. Edit k8s/deployment.yaml with your image URL and DMX_HOST"
echo "  4. Create Splunk secret and ConfigMap, then kubectl apply -f k8s/"
