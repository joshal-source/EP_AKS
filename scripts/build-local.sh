#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=lib/load-env.sh
source "${SCRIPT_DIR}/lib/load-env.sh"
load_ep_env "${ROOT_DIR}"

IMAGE_NAME="${IMAGE_NAME:-edgeprocessor}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
LOCAL_TAG="${IMAGE_NAME}:${IMAGE_TAG}"
PUSH=false

usage() {
  cat <<EOF
Usage: $0 [--push]

Build the Edge Processor image with your local Docker engine.

Options:
  --push    Tag and push to Azure Container Registry (requires ACR_NAME in .env)

Environment (.env):
  IMAGE_NAME=edgeprocessor
  IMAGE_TAG=latest
  ACR_NAME=epacr          # required for --push

Examples:
  $0
  $0 --push
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --push)
      PUSH=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is not installed or not running." >&2
  exit 1
fi

echo "Building ${LOCAL_TAG} from ${ROOT_DIR}/docker (linux/amd64 for AKS nodes)"
docker build --platform linux/amd64 -t "${LOCAL_TAG}" "${ROOT_DIR}/docker"

if [[ "${PUSH}" == "true" ]]; then
  if [[ -z "${ACR_NAME:-}" ]]; then
    echo "ERROR: set ACR_NAME in .env before using --push" >&2
    exit 1
  fi
  REMOTE="$(ep_acr_image)"
  LOGIN_SERVER="$(ep_acr_login_server)"
  echo "Logging into ACR ${LOGIN_SERVER} (Azure cloud: $(ep_azure_cloud_name || echo unknown))"
  if ! az acr login --name "${ACR_NAME}"; then
    echo "ERROR: az acr login failed. Run az login and verify ACR_NAME in .env." >&2
    exit 1
  fi
  docker tag "${LOCAL_TAG}" "${REMOTE}"
  echo "Pushing ${REMOTE}"
  docker push "${REMOTE}"
  if ! az acr repository show -n "${ACR_NAME}" --image "${IMAGE_NAME}:${IMAGE_TAG}" >/dev/null 2>&1; then
    echo "ERROR: push finished but image not found in ACR: ${REMOTE}" >&2
    exit 1
  fi
  echo ""
  echo "Image ready for AKS: ${REMOTE}"
fi

echo "Done."
