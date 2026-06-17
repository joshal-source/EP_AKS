#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <dockerhub-username> <image-tag>"
  echo "Example: $0 johndoe latest"
  echo ""
  echo "Pushes to: docker.io/<username>/edgeprocessor:<tag>"
  echo "Run 'docker login' first."
  exit 1
fi

DOCKERHUB_USER="$1"
IMAGE_TAG="$2"
IMAGE="${DOCKERHUB_USER}/edgeprocessor:${IMAGE_TAG}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "Building image: ${IMAGE}"
docker build -t "${IMAGE}" "${ROOT_DIR}/docker"

echo "Pushing image: ${IMAGE}"
docker push "${IMAGE}"

echo ""
echo "Done. Update k8s/deployment.yaml:"
echo "  image: ${IMAGE}"
echo ""
echo "If the repo is private, also run:"
echo "  ./scripts/create-registry-secret.sh dockerhub ${DOCKERHUB_USER} <access-token>"
echo "  Then uncomment imagePullSecrets in k8s/deployment.yaml"
