#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <acr-name> <image-tag>"
  echo "Example: $0 mycompanyacr v1"
  exit 1
fi

ACR_NAME="$1"
IMAGE_TAG="$2"
IMAGE="${ACR_NAME}.azurecr.io/edgeprocessor:${IMAGE_TAG}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "Logging into Azure Container Registry: ${ACR_NAME}"
az acr login --name "${ACR_NAME}"

echo "Building image: ${IMAGE}"
docker build -t "${IMAGE}" "${ROOT_DIR}/docker"

echo "Pushing image: ${IMAGE}"
docker push "${IMAGE}"

echo "Done. Update k8s/deployment.yaml image to: ${IMAGE}"
