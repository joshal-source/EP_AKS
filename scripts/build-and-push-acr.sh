#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -ge 2 ]]; then
  ACR_NAME="$1"
  IMAGE_TAG="$2"
  ACR_NAME="${ACR_NAME}" IMAGE_TAG="${IMAGE_TAG}" "${SCRIPT_DIR}/build-local.sh" --push
  exit 0
fi

echo "Usage: $0 <acr-name> <image-tag>"
echo ""
echo "Build with local Docker and push to Azure Container Registry."
echo "Prefer .env + ./scripts/build-local.sh --push when ACR_NAME is already set."
echo ""
echo "Example: $0 mycompanyacr latest"
exit 1
